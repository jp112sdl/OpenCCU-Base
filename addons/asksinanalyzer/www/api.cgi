#!/bin/tclsh
# AskSinAnalyzer CCU - API backend
# Datenquelle: <Traffic Log Directory>/multimacd-traffic-YYYY-MM-DD.log (TrafficLogger
# in multimacd; Verzeichnis aus /etc/config/multimacd.conf, Fallback /var/log)
# Kommandos:
#   ?cmd=dates                     -> JSON: verfuegbare Log-Daten
#   ?cmd=data&date=YYYY-MM-DD&offset=N -> text/plain: "OFFSET <n>\n" + neue Logzeilen ab Offset
#   ?cmd=devlist[&refresh=1]       -> JSON: Geraeteliste (RF-Adresse, Serial, Name, Typ)
#                                     + hmip_central (HmIP-Funkadresse der Zentrale)
#   ?cmd=version                   -> JSON: Addon-Version (aus ../VERSION)

set LOGDIR "/var/log"
set LOGPREFIX "multimacd-traffic-"
set CONFFILE "/etc/config/multimacd.conf"
set CACHEFILE "/tmp/asksinanalyzer.devlist.json"
set CACHETTL 600

# "Traffic Log Directory" aus der multimacd.conf uebernehmen (Fallback: /var/log)
catch {
    set fh [open $CONFFILE r]
    set conf [read $fh]
    close $fh
    foreach line [split $conf "\n"] {
        if {[regexp {^\s*Traffic Log Directory\s*=\s*(.*\S)\s*$} $line -> dir]} {
            set LOGDIR $dir
        }
    }
}

# ---------- Helpers ----------

proc getParams {} {
    global env
    set params [dict create]
    if {![info exists env(QUERY_STRING)]} { return $params }
    foreach pair [split $env(QUERY_STRING) "&"] {
        set idx [string first "=" $pair]
        if {$idx < 0} { continue }
        set k [string range $pair 0 [expr {$idx-1}]]
        set v [string range $pair [expr {$idx+1}] end]
        # url-decode (einfach: %XX und +)
        set v [string map {+ { }} $v]
        regsub -all {%([0-9A-Fa-f]{2})} $v {\\u00\1} v
        set v [subst -nocommands -novariables $v]
        dict set params $k $v
    }
    return $params
}

proc jsonEscape {s} {
    set out ""
    foreach ch [split $s ""] {
        scan $ch %c code
        if {$ch eq "\""} { append out "\\\"" } \
        elseif {$ch eq "\\"} { append out "\\\\" } \
        elseif {$code < 0x20} { append out [format "\\u%04x" $code] } \
        elseif {$code > 0x7e} { append out [format "\\u%04x" $code] } \
        else { append out $ch }
    }
    return $out
}

proc httpHeader {contentType} {
    puts "Content-Type: $contentType\r"
    puts "Cache-Control: no-cache\r"
    puts "\r"
}

# ---------- Kommandos ----------

proc cmdDates {} {
    global LOGDIR LOGPREFIX
    set dates {}
    foreach f [lsort [glob -nocomplain -directory $LOGDIR "${LOGPREFIX}*.log"]] {
        set base [file tail $f]
        if {[regexp "^${LOGPREFIX}(\\d{4}-\\d{2}-\\d{2})\\.log$" $base -> d]} {
            lappend dates "\"$d\""
        }
    }
    httpHeader "application/json"
    puts "\[[join $dates ,]\]"
}

proc cmdData {params} {
    global LOGDIR LOGPREFIX
    set date [expr {[dict exists $params date] ? [dict get $params date] : ""}]
    if {![regexp {^\d{4}-\d{2}-\d{2}$} $date]} {
        # default: heute
        set date [clock format [clock seconds] -format "%Y-%m-%d"]
    }
    set offset 0
    if {[dict exists $params offset]} {
        set o [dict get $params offset]
        if {[string is integer -strict $o] && $o >= 0} { set offset $o }
    }
    set path [file join $LOGDIR "${LOGPREFIX}${date}.log"]
    # Datei komplett lesen, bevor der Header geschrieben wird - so landet bei
    # I/O-Fehlern nie ein zweiter Header (JSON-Fehlerhandler) in der Antwort
    set chunk ""
    if {[catch {
        if {![file exists $path]} {
            set offset 0
        } else {
            set size [file size $path]
            if {$offset > $size} { set offset 0 }
            set fh [open $path r]
            fconfigure $fh -translation binary
            seek $fh $offset
            set chunk [read $fh]
            close $fh
        }
    }]} {
        # Lesefehler: leere Antwort, Offset unveraendert (Client versucht es erneut)
        catch {close $fh}
        set chunk ""
    }
    httpHeader "text/plain; charset=utf-8"
    # nur vollstaendige Zeilen ausliefern
    set lastNl [string last "\n" $chunk]
    if {$lastNl < 0} {
        puts "OFFSET $offset"
        return
    }
    set chunk [string range $chunk 0 $lastNl]
    puts "OFFSET [expr {$offset + $lastNl + 1}]"
    puts -nonewline $chunk
}

# HmIP-Funkadresse der Zentrale aus /etc/config/hmip_address.conf
# (Adapter.1.Address=<hex>), als 6-stelliger Hex-String; "" wenn nicht ermittelbar
proc readHmipCentral {} {
    set addr ""
    catch {
        set fh [open "/etc/config/hmip_address.conf" r]
        set conf [read $fh]
        close $fh
        foreach line [split $conf "\n"] {
            if {[regexp {^\s*Adapter\.1\.Address\s*=\s*(?:0[xX])?([0-9A-Fa-f]{1,6})\s*$} $line -> a]} {
                set addr [format %06X 0x$a]
            }
        }
    }
    return $addr
}

proc buildDevList {} {
    load tclrpc.so
    load tclrega.so

    # Namen aus der ReGa: Serial -> Name
    array set names {}
    if {![catch {rega_script {
        string sDevId;
        foreach(sDevId, root.Devices().EnumIDs()) {
          var d = dom.GetObject(sDevId);
          if (d.ReadyConfig() == true) {
            WriteLine(d.Address() # "\t" # d.Name());
          }
        }
    }} regaResult]} {
        array set res $regaResult
        if {[info exists res(STDOUT)]} {
            foreach line [split $res(STDOUT) "\n"] {
                set parts [split $line "\t"]
                if {[llength $parts] >= 2} {
                    set ser [string trim [lindex $parts 0]]
                    set nam [string trim [lindex $parts 1]]
                    if {$ser ne ""} { set names($ser) $nam }
                }
            }
        }
    }

    # RF-Adressen aus dem rfd (BidCos-RF, Port 2001)
    set entries {}
    if {![catch {xmlrpc http://127.0.0.1:2001/ listDevices} devs]} {
        foreach d $devs {
            # Array vor jedem Geraet leeren - auch nach einem Fehler in der
            # vorigen Iteration duerfen keine Felder des alten Geraets uebrigbleiben
            array unset a
            catch {
                array set a $d
                if {[string first ":" $a(ADDRESS)] < 0 && [info exists a(RF_ADDRESS)]} {
                    set serial $a(ADDRESS)
                    set rf $a(RF_ADDRESS)
                    set type [expr {[info exists a(TYPE)] ? $a(TYPE) : ""}]
                    set name [expr {[info exists names($serial)] ? $names($serial) : $serial}]
                    if {$serial eq "BidCoS-RF"} { set name "Zentrale (CCU)" }
                    set name [encoding convertfrom iso8859-1 $name]
                    lappend entries "{\"address\":$rf,\"serial\":\"[jsonEscape $serial]\",\"name\":\"[jsonEscape $name]\",\"type\":\"[jsonEscape $type]\"}"
                }
            }
        }
    }
    return "{\"created_at\":[clock seconds],\"hmip_central\":\"[jsonEscape [readHmipCentral]]\",\"devices\":\[[join $entries ,]\]}"
}

proc cmdDevList {params} {
    global CACHEFILE CACHETTL
    set refresh [expr {[dict exists $params refresh] && [dict get $params refresh] eq "1"}]
    set json ""
    if {!$refresh && [file exists $CACHEFILE] &&
        ([clock seconds] - [file mtime $CACHEFILE]) < $CACHETTL} {
        set fh [open $CACHEFILE r]
        fconfigure $fh -encoding utf-8
        set json [read $fh]
        close $fh
    }
    if {$json eq ""} {
        set json [buildDevList]
        catch {
            set fh [open $CACHEFILE w]
            fconfigure $fh -encoding utf-8
            puts -nonewline $fh $json
            close $fh
        }
    }
    httpHeader "application/json; charset=utf-8"
    puts -nonewline $json
}

proc cmdVersion {} {
    set v ""
    catch {
        set fh [open [file join [file dirname [info script]] ".." "VERSION"] r]
        set v [string trim [read $fh]]
        close $fh
    }
    httpHeader "application/json"
    puts "{\"version\":\"[jsonEscape $v]\"}"
}

# ---------- Main ----------

set params [getParams]
set cmd [expr {[dict exists $params cmd] ? [dict get $params cmd] : ""}]

if {[catch {
    switch -- $cmd {
        dates   { cmdDates }
        data    { cmdData $params }
        devlist { cmdDevList $params }
        version { cmdVersion }
        default {
            httpHeader "application/json"
            puts "{\"error\":\"unknown cmd\"}"
        }
    }
} err]} {
    httpHeader "application/json"
    puts "{\"error\":\"[jsonEscape $err]\"}"
}

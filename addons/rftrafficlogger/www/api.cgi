#!/bin/tclsh
# RFTrafficLogger - API backend
# Datenquellen:
#   <Traffic Log Directory>/multimacd-traffic-YYYY-MM-DD.log (TrafficLogger in
#     multimacd = Sicht des lokalen Funkmoduls; Verzeichnis aus
#     /etc/config/multimacd.conf, Fallback /var/log)
#   <Traffic Log Directory>/rfd-traffic-YYYY-MM-DD.log (TrafficLogger im rfd =
#     Telegramme ueber Funk-LAN-Gateways, mit IFACE=<serial>; Verzeichnis aus
#     /etc/config/rfd.conf, Fallback /var/log)
# Kommandos:
#   ?cmd=dates                     -> JSON: verfuegbare Log-Daten (beide Quellen vereinigt)
#   ?cmd=data&date=YYYY-MM-DD&offset=N[&src=rfd] -> text/plain: "OFFSET <n>\n" + neue Logzeilen ab Offset
#   ?cmd=devlist[&refresh=1]       -> JSON: Geraeteliste (RF-Adresse, Serial, Name, Typ)
#                                     + hmip_central (HmIP-Funkadresse der Zentrale)
#   ?cmd=version                   -> JSON: Addon-Version (aus ../VERSION)
#   ?cmd=alarmcfg[&set=1&<key>=<val>...] -> JSON: Konfiguration der
#                                     Funkaufkommen-Ueberwachung lesen/schreiben
#   ?cmd=alarmstate                -> JSON: Lernfortschritt, Baseline je Sender,
#                                     aktuelle Rate und ausgeloeste Alarme
#   ?cmd=alarmreset                -> Lernphase verwerfen und neu beginnen

set LOGDIR "/var/log"
set RFDLOGDIR "/var/log"
set LOGPREFIX "multimacd-traffic-"
set RFDLOGPREFIX "rfd-traffic-"
set CONFFILE "/etc/config/multimacd.conf"
set RFDCONFFILE "/etc/config/rfd.conf"
set CACHEFILE "/tmp/rftrafficlogger.devlist.json"
set CACHETTL 600
set PIDFILE "/var/run/rftrafficwatch.pid"

# Konfiguration/Zustand der Funkaufkommen-Ueberwachung teilen wir uns mit dem
# Hintergrunddienst. Fehlt die Bibliothek (alte Installation), bleiben nur die
# alarm*-Kommandos ohne Funktion - der Rest der API laeuft normal weiter.
set ALARMLIB [file join [file dirname [info script]] ".." "lib" "rftl_alarm.tcl"]
set haveAlarm [expr {![catch {source $ALARMLIB}]}]

# "Traffic Log Directory" aus einer Konfigurationsdatei lesen (Fallback: /var/log)
proc readTrafficLogDir {conffile} {
    set dir "/var/log"
    catch {
        set fh [open $conffile r]
        set conf [read $fh]
        close $fh
        foreach line [split $conf "\n"] {
            if {[regexp {^\s*Traffic Log Directory\s*=\s*(.*\S)\s*$} $line -> d]} {
                set dir $d
            }
        }
    }
    return $dir
}
set LOGDIR [readTrafficLogDir $CONFFILE]
set RFDLOGDIR [readTrafficLogDir $RFDCONFFILE]

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
        dict set params $k [urlDecode $v]
    }
    return $params
}

# %XX in Bytes zurueckwandeln und das Ergebnis als UTF-8 lesen. Browser
# kodieren Nicht-ASCII als UTF-8-Prozentsequenzen; die fruehere subst-Variante
# hat daraus Latin-1 gemacht (Umlaute wurden zerlegt) und haette ausserdem
# Backslash-Sequenzen aus der Eingabe interpretiert.
proc urlDecode {s} {
    set s [string map {+ { }} $s]
    set out ""
    set i 0
    set n [string length $s]
    while {$i < $n} {
        set ch [string index $s $i]
        if {$ch eq "%" && $i + 2 < $n &&
            [regexp {^[0-9A-Fa-f]{2}$} [string range $s [expr {$i+1}] [expr {$i+2}]] hex]} {
            append out [binary format c [scan $hex %x]]
            incr i 3
        } else {
            append out $ch
            incr i
        }
    }
    return [encoding convertfrom utf-8 $out]
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
    global LOGDIR LOGPREFIX RFDLOGDIR RFDLOGPREFIX
    array set seen {}
    foreach {dir prefix} [list $LOGDIR $LOGPREFIX $RFDLOGDIR $RFDLOGPREFIX] {
        foreach f [glob -nocomplain -directory $dir "${prefix}*.log"] {
            set base [file tail $f]
            if {[regexp "^${prefix}(\\d{4}-\\d{2}-\\d{2})\\.log$" $base -> d]} {
                set seen($d) 1
            }
        }
    }
    set dates {}
    foreach d [lsort [array names seen]] {
        lappend dates "\"$d\""
    }
    httpHeader "application/json"
    puts "\[[join $dates ,]\]"
}

proc cmdData {params} {
    global LOGDIR LOGPREFIX RFDLOGDIR RFDLOGPREFIX
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
    # Quelle: multimacd (default) oder rfd (Funk-LAN-Gateways)
    if {[dict exists $params src] && [dict get $params src] eq "rfd"} {
        set path [file join $RFDLOGDIR "${RFDLOGPREFIX}${date}.log"]
    } else {
        set path [file join $LOGDIR "${LOGPREFIX}${date}.log"]
    }
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
    load tclrega.so

    # Geraete inkl. RF-Adresse direkt aus der ReGa: die DEVDESC-Metadaten
    # enthalten RF_ADDRESS auch fuer HmIP-Geraete (rfd auf Port 2001 kennt
    # nur BidCos; vgl. ccu_create_devlist des AskSinAnalyzer)
    set entries {}
    if {![catch {rega_script {
        string sDevId;
        string data;
        string rf;
        string ty;
        foreach(sDevId, root.Devices().EnumUsedIDs()) {
          var d = dom.GetObject(sDevId);
          if (d.ReadyConfig() == true) {
            rf = "";
            ty = "";
            foreach(data, d.MetaData("DEVDESC").Split(",")) {
              if (data.Substr(0,10) == "RF_ADDRESS") { rf = data.Replace("RF_ADDRESS:",""); }
              if (data.Substr(0,4) == "TYPE")        { ty = data.Replace("TYPE:",""); }
            }
            if ((rf != "") && (rf != "0")) {
              WriteLine(rf # "\t" # d.Address() # "\t" # d.Name() # "\t" # ty);
            }
          }
        }
    }} regaResult]} {
        array set res $regaResult
        if {[info exists res(STDOUT)]} {
            foreach line [split $res(STDOUT) "\n"] {
                set parts [split $line "\t"]
                if {[llength $parts] < 4} { continue }
                lassign $parts rf serial name type
                set rf [string trim $rf]
                set serial [string trim $serial]
                # virtuelle Team-Geraete (*SERIAL) duplizieren die RF-Adresse
                if {![string is integer -strict $rf]} { continue }
                if {$serial eq "" || [string index $serial 0] eq "*"} { continue }
                set name [encoding convertfrom iso8859-1 [string trim $name]]
                # DEVDESC liefert TYPE in Anfuehrungszeichen
                set type [encoding convertfrom iso8859-1 [string map {\" ""} [string trim $type]]]
                lappend entries "{\"address\":$rf,\"serial\":\"[jsonEscape $serial]\",\"name\":\"[jsonEscape $name]\",\"type\":\"[jsonEscape $type]\"}"
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

# ---------- Funkaufkommen-Ueberwachung ----------

proc dictGetOr {d key def} {
    return [expr {[dict exists $d $key] ? [dict get $d $key] : $def}]
}

# Zahl fuer JSON; alles Unbrauchbare wird zu null, damit nie ungueltiges
# JSON entsteht (die Zustandsdatei schreibt ein anderer Prozess)
proc jsonNum {v {fmt %.2f}} {
    if {![string is double -strict $v]} { return "null" }
    return [format $fmt $v]
}

# Laeuft der Hintergrunddienst? Die PID-Datei schreibt start-stop-daemon.
proc watchRunning {} {
    global PIDFILE
    set pid ""
    catch {
        set fh [open $PIDFILE r]
        set pid [string trim [read $fh]]
        close $fh
    }
    if {![string is integer -strict $pid] || $pid <= 0} { return 0 }
    return [expr {[file isdirectory "/proc/$pid"] ? 1 : 0}]
}

proc alarmUnavailable {} {
    httpHeader "application/json"
    puts "{\"error\":\"Alarmmodul nicht installiert\"}"
}

proc alarmCfgJson {c} {
    set parts {}
    dict for {k v} $c {
        if {$k in {alarm_var ignore_addrs}} {
            lappend parts "\"$k\":\"[jsonEscape $v]\""
        } else {
            lappend parts "\"$k\":$v"
        }
    }
    return "{[join $parts ,]}"
}

# cmd=alarmcfg liest die Konfiguration, mit set=1 schreibt es die
# mitgegebenen Schluessel. Nicht uebergebene Schluessel bleiben unveraendert,
# Wertebereiche erzwingt rftl::clampConfig - die Antwort enthaelt deshalb
# immer die tatsaechlich gespeicherten Werte.
proc cmdAlarmCfg {params} {
    global haveAlarm
    if {!$haveAlarm} { alarmUnavailable; return }
    set c [rftl::readConfig]
    if {[dict exists $params set] && [dict get $params set] eq "1"} {
        dict for {k v} $c {
            # reset_at laeuft ausschliesslich ueber cmd=alarmreset
            if {$k eq "reset_at"} { continue }
            if {[dict exists $params $k]} { dict set c $k [dict get $params $k] }
        }
        if {[catch {rftl::writeConfig $c} res]} {
            httpHeader "application/json"
            puts "{\"error\":\"[jsonEscape $res]\"}"
            return
        }
        set c $res
    }
    httpHeader "application/json; charset=utf-8"
    puts [alarmCfgJson $c]
}

# cmd=alarmstate liefert Lernfortschritt, Baseline und aktuelle Rate je
# Sender. Die Namensaufloesung macht die Weboberflaeche selbst (devlist).
proc cmdAlarmState {params} {
    global haveAlarm
    if {!$haveAlarm} { alarmUnavailable; return }
    set c  [rftl::readConfig]
    set st [rftl::readState]
    set now [clock seconds]

    set phase     [dictGetOr $st phase "learning"]
    set learnSec  [dictGetOr $st learn_sec 0]
    set needSec   [expr {[dict get $c learn_hours] * 3600}]
    set winSec    [dictGetOr $st window_sec [expr {[dict get $c window_min] * 60}]]
    set recentSec [dictGetOr $st recent_sec 0]
    set baseline  [dictGetOr $st baseline {}]
    set recent    [dictGetOr $st recent {}]
    set counts    [dictGetOr $st counts {}]
    set alarms    [dictGetOr $st alarms {}]
    if {![string is double -strict $learnSec]} { set learnSec 0 }
    if {$winSec <= 0} { set winSec 1 }

    # waehrend der Lernphase zeigen wir die bisher gelernte Rate als Vorschau
    set learnH [expr {$learnSec / 3600.0}]
    set winH   [expr {$winSec / 3600.0}]

    set addrs {}
    foreach d [list $baseline $recent $counts] {
        dict for {a v} $d { dict set addrs $a 1 }
    }

    set devs {}
    dict for {a dummy} $addrs {
        set base   [expr {[dict exists $baseline $a] ? [dict get $baseline $a] : ""}]
        set rec    [dictGetOr $recent $a 0]
        set cnt    [dictGetOr $counts $a 0]
        set rate   [expr {$rec / $winH}]
        set lrate  [expr {$learnH > 0 ? $cnt / $learnH : ""}]
        set pct    ""
        if {[string is double -strict $base] && $base > 0} {
            set pct [expr {($rate / $base - 1.0) * 100.0}]
        }
        set al "null"
        if {[dict exists $alarms $a]} {
            set al [dictGetOr [dict get $alarms $a] ts 0]
        }
        lappend devs "{\"addr\":\"[jsonEscape $a]\",\"base\":[jsonNum $base],\
\"learn_count\":[jsonNum $cnt %.0f],\"learn_rate\":[jsonNum $lrate],\
\"recent\":[jsonNum $rec %.0f],\"rate\":[jsonNum $rate],\"pct\":[jsonNum $pct %.1f],\
\"alarm_ts\":$al}"
    }

    set alist {}
    dict for {a info} $alarms {
        lappend alist "{\"addr\":\"[jsonEscape $a]\",\"ts\":[jsonNum [dictGetOr $info ts 0] %.0f],\
\"reason\":\"[jsonEscape [dictGetOr $info reason {}]]\",\
\"rate\":[jsonNum [dictGetOr $info rate 0]],\"expected\":[jsonNum [dictGetOr $info expected 0]],\
\"msg\":\"[jsonEscape [dictGetOr $info msg {}]]\"}"
    }

    set knownDevs [dictGetOr $st known_devices ""]
    set lastCheck [dictGetOr $st last_check 0]
    # "frisch" heisst: der Dienst hat innerhalb der letzten drei Zyklen gelaufen
    set fresh [expr {$lastCheck > 0 && ($now - $lastCheck) < [dict get $c interval_sec] * 3}]

    httpHeader "application/json; charset=utf-8"
    puts "{\"now\":$now,\"running\":[watchRunning],\"fresh\":[expr {$fresh ? 1 : 0}],\
\"phase\":\"[jsonEscape $phase]\",\"learn_sec\":[jsonNum $learnSec %.0f],\
\"learn_need\":$needSec,\"learn_started\":[jsonNum [dictGetOr $st learn_started 0] %.0f],\
\"baseline_at\":[jsonNum [dictGetOr $st baseline_at 0] %.0f],\
\"last_check\":[jsonNum $lastCheck %.0f],\"window_sec\":$winSec,\
\"recent_sec\":[jsonNum $recentSec %.0f],\
\"known_only\":[dict get $c known_only],\"known_devices\":[jsonNum $knownDevs %.0f],\
\"devices\":\[[join $devs ,]\],\"alarms\":\[[join $alist ,]\]}"
}

# cmd=alarmreset verwirft die gelernten Werte. Der Dienst erkennt den
# geaenderten Zeitstempel im naechsten Zyklus und beginnt von vorn; ist er
# gerade gestoppt, holt er das beim naechsten Start nach.
proc cmdAlarmReset {} {
    global haveAlarm
    if {!$haveAlarm} { alarmUnavailable; return }
    set c [rftl::readConfig]
    set ts [clock seconds]
    # zweimal in derselben Sekunde waere sonst wirkungslos
    if {$ts <= [dict get $c reset_at]} { set ts [expr {[dict get $c reset_at] + 1}] }
    dict set c reset_at $ts
    if {[catch {rftl::writeConfig $c} res]} {
        httpHeader "application/json"
        puts "{\"error\":\"[jsonEscape $res]\"}"
        return
    }
    httpHeader "application/json"
    puts "{\"ok\":true,\"reset_at\":$ts}"
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
        alarmcfg   { cmdAlarmCfg $params }
        alarmstate { cmdAlarmState $params }
        alarmreset { cmdAlarmReset }
        default {
            httpHeader "application/json"
            puts "{\"error\":\"unknown cmd\"}"
        }
    }
} err]} {
    httpHeader "application/json"
    puts "{\"error\":\"[jsonEscape $err]\"}"
}

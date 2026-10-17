# RFTrafficLogger - gemeinsame Basis fuer die Funkaufkommen-Ueberwachung
#
# Wird sowohl vom Hintergrunddienst (bin/rftrafficwatch.tcl) als auch von der
# API (www/api.cgi) eingebunden, damit beide Seiten dieselben Vorgaben,
# Wertebereiche und Dateiformate verwenden. Die Weboberflaeche schreibt die
# Konfiguration, der Dienst liest sie in jedem Zyklus neu ein.
#
# Dateien (alle unterhalb des Addon-Verzeichnisses, also auf der
# persistenten Partition - Lernfortschritt ueberlebt Reboots und Updates):
#   alarm.conf   key=value, von der Weboberflaeche geschrieben
#   alarm.state  Tcl-Dict, vom Dienst geschrieben

namespace eval rftl {
    variable dir [file normalize [file join [file dirname [info script]] ".."]]
    variable conffile  [file join $dir "alarm.conf"]
    variable statefile [file join $dir "alarm.state"]

    # Voreinstellungen und zugleich die Liste der gueltigen Schluessel:
    # was hier nicht steht, wird beim Lesen und Schreiben verworfen.
    variable defaults {
        enabled        0
        learn_hours    48
        ref_mode       peak
        threshold_pct  100
        window_min     60
        min_packets    20
        cooldown_min   60
        interval_sec   300
        alarm_var      "RFTrafficLogger: Funkaufkommen"
        alarm_internal 0
        alarm_new_dev  0
        known_only     1
        ignore_addrs   ""
        reset_at       0
        debug          0
    }

    # Wertebereiche der Zahlenfelder: {Schluessel Minimum Maximum}
    variable ranges {
        learn_hours    1  720
        threshold_pct  1  100000
        window_min     1  1440
        min_packets    1  1000000
        cooldown_min   0  10080
        interval_sec   30 3600
    }
    variable flags {enabled alarm_internal alarm_new_dev known_only debug}

    # Vergleichswert, gegen den die aktuelle Rate geprueft wird:
    #   peak = hoechste Stundenrate der Lernphase ("mehr als je gesehen")
    #   mean = flacher Mittelwert ueber die Lernphase
    # peak ist die Vorgabe, weil der Mittelwert bei Geraeten mit
    # Tagesrhythmus (z.B. Energiezaehler, deren Senderate am Verbrauch
    # haengt) unter dem normalen Tagesniveau liegt und jeder etwas
    # kraeftigere Nachmittag die Schwelle reisst.
    variable ref_modes {peak mean}
}

# Text entschaerfen, bevor er an triggerAlarm.tcl uebergeben wird.
# Zwei Gruende:
#  - triggerAlarm.tcl setzt Meldung und Variablenname in "..." in ein
#    ReGa-Script ein, also muessen Anfuehrungszeichen, Backslashes und
#    Steuerzeichen raus;
#  - Tcl deutet exec-Argumente, die mit < > | beginnen, als Umleitung bzw.
#    Pipe - ein Geraetename wie ">Bad" wuerde sonst in eine Datei schreiben.
proc rftl::sanitize {s} {
    set out ""
    foreach ch [split $s ""] {
        scan $ch %c code
        if {$code < 0x20 || $ch in {\" \\ < > |}} { append out " " } else { append out $ch }
    }
    return [string trim $out]
}

# Alle Werte auf gueltige Bereiche zwingen. Die Konfiguration kommt aus dem
# Web, darf den Dienst also weder in eine Endlosschleife noch in eine
# Division durch null treiben.
proc rftl::clampConfig {c} {
    variable defaults
    variable ranges
    variable flags
    # unbekannte Schluessel entfernen, fehlende ergaenzen
    set out {}
    dict for {k v} $defaults {
        dict set out $k [expr {[dict exists $c $k] ? [dict get $c $k] : $v}]
    }
    foreach {k min max} $ranges {
        set v [dict get $out $k]
        if {![string is double -strict $v]} { set v $min }
        set v [expr {int($v)}]
        if {$v < $min} { set v $min }
        if {$v > $max} { set v $max }
        dict set out $k $v
    }
    foreach k $flags {
        dict set out $k [expr {[string tolower [dict get $out $k]] in {1 true yes on} ? 1 : 0}]
    }
    if {![string is wideinteger -strict [dict get $out reset_at]]} { dict set out reset_at 0 }

    variable ref_modes
    if {[dict get $out ref_mode] ni $ref_modes} {
        dict set out ref_mode [lindex $ref_modes 0]
    }

    set var [rftl::sanitize [dict get $out alarm_var]]
    if {$var eq ""} { set var [dict get $defaults alarm_var] }
    dict set out alarm_var [string range $var 0 59]

    # Ignorierliste: ausschliesslich 6-stellige Hex-Adressen, normalisiert
    set ign {}
    foreach a [split [string map {, " " ; " " \n " " \t " "} [dict get $out ignore_addrs]] " "] {
        set a [string toupper [string trim $a]]
        if {[regexp {^[0-9A-F]{6}$} $a]} { lappend ign $a }
    }
    dict set out ignore_addrs [join [lsort -unique $ign] ","]

    # ein Auswertefenster groesser als die Lernphase ergibt keinen Sinn
    if {[dict get $out window_min] > [dict get $out learn_hours] * 60} {
        dict set out window_min [expr {[dict get $out learn_hours] * 60}]
    }
    return $out
}

proc rftl::readConfig {} {
    variable conffile
    variable defaults
    set c $defaults
    catch {
        set fh [open $conffile r]
        fconfigure $fh -encoding utf-8
        set data [read $fh]
        close $fh
        foreach line [split $data "\n"] {
            if {[regexp {^\s*([a-z_]+)\s*=\s*(.*?)\s*$} $line -> k v]} {
                if {[dict exists $defaults $k]} { dict set c $k $v }
            }
        }
    }
    return [rftl::clampConfig $c]
}

# Konfiguration atomar schreiben (erst .tmp, dann umbenennen), damit der
# Dienst nie eine halb geschriebene Datei zu sehen bekommt.
proc rftl::writeConfig {c} {
    variable conffile
    set c [rftl::clampConfig $c]
    set tmp "${conffile}.tmp"
    set fh [open $tmp w]
    fconfigure $fh -encoding utf-8
    puts $fh "# RFTrafficLogger - Funkaufkommen-Ueberwachung"
    puts $fh "# wird von der Weboberflaeche geschrieben (Reiter \"Alarm\")"
    dict for {k v} $c { puts $fh "$k=$v" }
    close $fh
    file rename -force $tmp $conffile
    return $c
}

proc rftl::readState {} {
    variable statefile
    set s {}
    catch {
        set fh [open $statefile r]
        fconfigure $fh -encoding utf-8
        set data [read $fh]
        close $fh
        if {[string is list $data] && [llength $data] % 2 == 0} { set s $data }
    }
    return $s
}

proc rftl::writeState {s} {
    variable statefile
    catch {
        set tmp "${statefile}.tmp"
        set fh [open $tmp w]
        fconfigure $fh -encoding utf-8
        puts -nonewline $fh $s
        close $fh
        file rename -force $tmp $statefile
    }
}

#!/bin/tclsh
# RFTrafficLogger - Funkaufkommen-Ueberwachung
#
# Hintergrunddienst, der die TrafficLogger-Logs mitliest, je Sender das
# uebliche Funkaufkommen (Pakete/Stunde) ueber eine Lernphase ermittelt und
# anschliessend Alarm ausloest, wenn ein Geraet deutlich mehr sendet als
# gelernt. Der Alarm geht ueber /bin/triggerAlarm.tcl in eine
# Alarm-Systemvariable der ReGa - dieselbe Mechanik, die auch monit nutzt.
#
# Gestartet/gestoppt wird der Dienst vom rc.d-Script des Addons
# (start/stop), d.h. beim Boot ueber S98StartAddons.
#
# Konfiguriert wird ausschliesslich ueber alarm.conf; die Datei schreibt die
# Weboberflaeche ueber api.cgi (cmd=alarmcfg&set=1). Der Daemon liest sie in
# jedem Zyklus neu, Aenderungen greifen also ohne Neustart.

set ADDONDIR [file normalize [file join [file dirname [info script]] ".."]]
source [file join $ADDONDIR "lib" "rftl_alarm.tcl"]

set MMDCONF "/etc/config/multimacd.conf"
set RFDCONF "/etc/config/rfd.conf"
# Die beiden Konfigurationsdateien liefern das "Traffic Log Directory".
# Sie lassen sich als Aufrufparameter ueberschreiben - gedacht fuer Tests
# und fuer Installationen, die die Logs woanders ablegen.
if {[llength $argv] >= 1} { set MMDCONF [lindex $argv 0] }
if {[llength $argv] >= 2} { set RFDCONF [lindex $argv 1] }
set MMDPREFIX "multimacd-traffic-"
set RFDPREFIX "rfd-traffic-"
set TRIGGER "/bin/triggerAlarm.tcl"

# Zeitraster der Kurzzeit-Statistik. Das Auswertefenster ist immer ein
# Vielfaches davon; feiner als eine Minute brauchen wir nicht aufzuloesen.
set BUCKET_SEC 60

# ---------------------------------------------------------------------------
# Hilfsfunktionen

proc logmsg {prio msg} {
    catch { exec /usr/bin/logger -t rftrafficwatch -p "user.$prio" -- $msg }
}
proc logdbg {msg} {
    global cfg
    if {[dict exists $cfg debug] && [dict get $cfg debug]} { logmsg debug $msg }
}

# Zustandsfeld mit Vorgabewert lesen - der Zustand kann aus einer aelteren
# Version stammen und einzelne Felder noch nicht kennen
proc stGet {st key def} {
    return [expr {[dict exists $st $key] ? [dict get $st $key] : $def}]
}

# dieselbe Warnung hoechstens einmal pro Stunde ins Syslog, damit ein
# Dauerzustand das Log nicht im Pruefintervall vollschreibt
set warnAt {}
proc warnOnce {msg} {
    global warnAt
    set now [clock seconds]
    if {[dict exists $warnAt $msg] && $now - [dict get $warnAt $msg] < 3600} { return }
    dict set warnAt $msg $now
    logmsg warning $msg
}

# "Traffic Log Directory" aus einer multimacd-/rfd-Konfiguration lesen
proc readTrafficLogDir {conffile} {
    set dir "/var/log"
    catch {
        set fh [open $conffile r]
        set conf [read $fh]
        close $fh
        foreach line [split $conf "\n"] {
            if {[regexp {^\s*Traffic Log Directory\s*=\s*(.*\S)\s*$} $line -> d]} { set dir $d }
        }
    }
    return $dir
}

# ---------------------------------------------------------------------------
# Geraeteliste der CCU (Funkadresse -> Name) aus der ReGa. Sie hat zwei
# Aufgaben: der Name landet im Alarmtext, und bei known_only entscheidet
# sie, welche Absender ueberhaupt gezaehlt werden - sonst wuerde auch
# fremder Funkverkehr (Nachbargeraete, andere Installationen) ueberwacht.
# Die Namen bleiben in ihrer ISO-8859-1-Kodierung, weil
# triggerAlarm.tcl/ReGa damit arbeiten.
set devMap {}
set devMapAt 0
set DEVMAP_TTL 3600

proc deviceKnown {addr} {
    global devMap
    return [dict exists $devMap $addr]
}
proc deviceName {addr} {
    global devMap
    if {[dict exists $devMap $addr]} { return [dict get $devMap $addr] }
    return ""
}

# Geraeteliste bei Bedarf erneuern; liefert 1, wenn eine brauchbare Liste
# vorliegt. Nur ein erfolgreicher Durchlauf setzt den Zeitstempel - ist die
# ReGa noch nicht bereit (direkt nach dem Boot), wird es im naechsten
# Zyklus erneut versucht statt eine Stunde lang mit leerer Liste zu laufen.
proc refreshDevMap {} {
    global devMap devMapAt DEVMAP_TTL
    if {[dict size $devMap] && [clock seconds] - $devMapAt < $DEVMAP_TTL} { return 1 }
    if {[catch {load tclrega.so}]} { return 0 }
    set names {}
    if {[catch {rega_script {
        string sDevId;
        string data;
        string rf;
        foreach(sDevId, root.Devices().EnumUsedIDs()) {
          var d = dom.GetObject(sDevId);
          if (d.ReadyConfig() == true) {
            rf = "";
            foreach(data, d.MetaData("DEVDESC").Split(",")) {
              if (data.Substr(0,10) == "RF_ADDRESS") { rf = data.Replace("RF_ADDRESS:",""); }
            }
            if ((rf != "") && (rf != "0")) { WriteLine(rf # "\t" # d.Name()); }
          }
        }
    }} regaResult]} { return 0 }
    array set res $regaResult
    if {![info exists res(STDOUT)]} { return 0 }
    foreach line [split $res(STDOUT) "\n"] {
        set parts [split $line "\t"]
        if {[llength $parts] < 2} { continue }
        lassign $parts rf name
        set rf [string trim $rf]
        if {![string is integer -strict $rf]} { continue }
        set hex [format %06X $rf]
        set name [rftl::sanitize [string trim $name]]
        # mehrere Geraete koennen dieselbe Funkadresse melden (z.B. HmIP-RCV-1
        # und RPI-RF-MOD fuer die Zentrale) - der erste Eintrag gewinnt. Die
        # Adresse wird auch ohne Namen aufgenommen, fuer den Filter zaehlt
        # nur, dass das Geraet auf der CCU existiert.
        if {![dict exists $names $hex]} { dict set names $hex $name }
    }
    if {[dict size $names] == 0} { return 0 }
    set devMap $names
    set devMapAt [clock seconds]
    return 1
}

# "Name (ADRESSE)" bzw. nur die Adresse, wenn das Geraet unbekannt ist
proc deviceLabel {addr} {
    set n [deviceName $addr]
    if {$n eq ""} { return $addr }
    return "$n ($addr)"
}

# ---------------------------------------------------------------------------
# Logdateien einlesen
#
# Je Quelle werden Dateiname und Leseposition im Zustand gemerkt. Beim
# Tageswechsel wird erst der Rest der alten Datei gelesen, dann auf die neue
# umgeschaltet; wird die Datei kleiner (Rotation/Neustart der Daemons),
# beginnen wir wieder bei 0.
proc readNewLines {srcKey dir prefix stateVar} {
    upvar 1 $stateVar st
    set today [clock format [clock seconds] -format "%Y-%m-%d"]
    set path [file join $dir "${prefix}${today}.log"]

    set offs [expr {[dict exists $st offsets] ? [dict get $st offsets] : {}}]
    set cur [expr {[dict exists $offs $srcKey] ? [dict get $offs $srcKey] : {}}]
    set file [expr {[dict exists $cur file] ? [dict get $cur file] : ""}]
    set pos  [expr {[dict exists $cur pos]  ? [dict get $cur pos]  : 0}]

    set text ""
    # Tageswechsel: Rest der Vortagsdatei noch abholen
    if {$file ne "" && $file ne $path} {
        append text [readChunk $file pos]
        set file $path
        set pos 0
    } elseif {$file eq ""} {
        # Erststart oder Reset: ans aktuelle Dateiende springen. Wuerden wir
        # die schon geschriebene Tagesdatei nachtraeglich einlesen, stuenden
        # deren Pakete in den Zaehlern, ohne dass die zugehoerige Zeit in
        # learn_sec steckt - die gelernte Rate waere massiv zu hoch.
        set file $path
        set pos [expr {[file exists $path] ? [file size $path] : 0}]
    }
    append text [readChunk $file pos]

    dict set offs $srcKey [dict create file $file pos $pos]
    dict set st offsets $offs
    return $text
}

# Liest ab $posVar bis zum letzten vollstaendigen Zeilenende und schreibt die
# neue Position zurueck. Eine halb geschriebene letzte Zeile bleibt liegen.
# Lesezeiger einer Quelle ohne Einlesen an das aktuelle Dateiende setzen.
# Beim Start des Dienstes wollen wir nichts nachholen: Telegramme aus der
# Zeit, in der er nicht lief, haetten keine zugehoerige Messdauer und
# wuerden die gelernte Rate verfaelschen. Das gilt auch, wenn der Dienst
# ueber einen Tageswechsel hinweg gestanden hat - dann ist die neue
# Tagesdatei schon gefuellt, obwohl wir sie nie mitgelesen haben.
proc seekToEnd {srcKey dir prefix stateVar} {
    upvar 1 $stateVar st
    set today [clock format [clock seconds] -format "%Y-%m-%d"]
    set path [file join $dir "${prefix}${today}.log"]
    set offs [expr {[dict exists $st offsets] ? [dict get $st offsets] : {}}]
    dict set offs $srcKey [dict create file $path \
        pos [expr {[file exists $path] ? [file size $path] : 0}]]
    dict set st offsets $offs
}

proc readChunk {path posVar} {
    upvar 1 $posVar pos
    if {![file exists $path]} { return "" }
    set chunk ""
    if {[catch {
        set size [file size $path]
        if {$pos > $size} { set pos 0 }
        if {$pos < $size} {
            set fh [open $path r]
            fconfigure $fh -translation binary
            seek $fh $pos
            set chunk [read $fh]
            close $fh
        }
    }]} {
        catch {close $fh}
        return ""
    }
    set lastNl [string last "\n" $chunk]
    if {$lastNl < 0} { return "" }
    incr pos [expr {$lastNl + 1}]
    return [string range $chunk 0 $lastNl]
}

# ---------------------------------------------------------------------------
# Parsen
#
# BidCos: Absender steht im FROM-Feld.
# HmIP:   die Frames werden roh geloggt, der Absender sitzt an fester
#         Position im Rohframe (Byte 4..6, also Hex-Offset 8) - genauso
#         wertet es die Weboberflaeche aus.
set tsMemo {}

# Zeitfach einer Logzeile. $now ist die Lesezeit (Epoche), gegen die der
# gelesene Zeitstempel geprueft wird.
#
# Die Logs tragen lokale Zeitstempel, und die sind in der Nacht der
# Zeitumstellung nicht eindeutig: bei der Rueckstellung laeuft die Stunde
# vor 03:00 zweimal, und clock scan loest beide Durchlaeufe auf dieselbe
# Sekunde auf (auf die zweite Instanz). Ohne Gegenmassnahme landen beide
# Durchlaeufe in denselben Zeitfaechern, das Auswertefenster zaehlt die
# Stunde doppelt, und die Raten aller Geraete steigen bis auf das Doppelte -
# am 25.10.2026 hat das auf c2 17 Fehlalarme ausgeloest.
#
# Deshalb gilt der gelesene Zeitstempel nur, solange er plausibel zur
# Lesezeit passt. Normal liegt er hoechstens einen Lesezyklus zurueck;
# weicht er weiter ab, wird die Lesezeit genommen. Damit faellt der erste
# Durchlauf (vom Parser eine Stunde in die Zukunft gelegt) auf seine echte
# Zeit zurueck, der zweite behaelt seinen Stempel - die beiden ueberlagern
# sich nicht mehr.
proc bucketOf {datestr timestr now tolerance} {
    global tsMemo BUCKET_SEC
    # auf Minuten memoisieren, clock scan ist teuer
    set key "$datestr [string range $timestr 0 4]"
    if {[dict exists $tsMemo $key]} {
        set base [dict get $tsMemo $key]
    } else {
        if {[catch {clock scan $key -format "%Y-%m-%d %H:%M"} base]} { return -1 }
        if {[dict size $tsMemo] > 4000} { set tsMemo {} }
        dict set tsMemo $key $base
    }
    set sec [scan [string range $timestr 6 7] %d]
    if {$sec eq ""} { set sec 0 }
    set ts [expr {$base + $sec}]
    if {abs($ts - $now) > $tolerance} { set ts $now }
    return [expr {$ts / $BUCKET_SEC}]
}

# zaehlt die Telegramme je Absender und Zeitbucket auf.
# knownOnly=1 beschraenkt die Zaehlung auf die Adressen in known (die
# Geraeteliste der CCU) - fremder Funkverkehr wird dann ignoriert.
proc parseInto {text countsVar bucketsVar hcountsVar dedupVar ignore learning knownOnly \
                known now tolerance} {
    upvar 1 $countsVar counts
    upvar 1 $bucketsVar buckets
    upvar 1 $hcountsVar hcounts
    upvar 1 $dedupVar dedup
    if {![info exists dedup]} { set dedup {} }
    # der Aufrufer darf die Stundenzaehler noch nicht angelegt haben
    if {![info exists hcounts]} { set hcounts {} }
    set n 0
    foreach line [split $text "\n"] {
        if {[string length $line] < 30} { continue }
        if {![regexp {^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\.\d{3} (?:RX|TX) (BIDCOS|HMIP) (.*)$} \
                $line -> d t proto rest]} { continue }
        set addr ""
        set cnt ""
        if {$proto eq "BIDCOS"} {
            if {![regexp {(?:^| )FROM=([0-9A-Fa-f]{6})(?: |$)} $rest -> addr]} { continue }
            regexp {(?:^| )CNT=([0-9A-Fa-f]+)(?: |$)} $rest -> cnt
        } else {
            if {![regexp {(?:^| )(?:DATA|PAYLOAD)=([0-9A-Fa-f]+)(?: |$)} $rest -> hex]} { continue }
            if {[string length $hex] < 14} { continue }
            set addr [string range $hex 8 13]
        }
        set addr [string toupper $addr]
        if {$addr eq "" || $addr eq "000000"} { continue }
        if {[lsearch -exact $ignore $addr] >= 0} { continue }
        if {$knownOnly && ![dict exists $known $addr]} { continue }
        set b [bucketOf $d $t $now $tolerance]
        if {$b < 0} { continue }
        # Dieselbe Sendung protokollieren das lokale Funkmodul und ein
        # Funk-LAN-Gateway getrennt - sie darf trotzdem nur einmal zaehlen,
        # das Geraet hat ja nur einmal gesendet. Schluessel sind Absender,
        # Sekunde und Nachrichtenzaehler aus der Logzeile (identisch in
        # beiden Quellen, unabhaengig davon wann wir sie lesen). Eine
        # Wiederholung in derselben Sekunde mit demselben Zaehler faellt
        # damit mit der Erstsendung zusammen - das betrifft rund 0,5 % der
        # Telegramme und liegt unter der Messgenauigkeit. HmIP kommt nur
        # ueber multimacd, dort gibt es nichts zu entdoppeln.
        if {$cnt ne ""} {
            set dkey "$addr|$d $t|$cnt"
            if {[dict exists $dedup $dkey]} { continue }
            dict set dedup $dkey $b
        }
        # die Lernzaehler laufen nur waehrend der Lernphase weiter, das
        # Kurzzeitfenster immer
        if {$learning} {
            dict incr counts $addr
            # zusaetzlich je voller Stunde zaehlen - daraus wird spaeter die
            # hoechste Stundenrate (Vergleichswert "Spitze")
            set hb [expr {$b / 60}]
            dict set hcounts $addr $hb [expr {([dict exists $hcounts $addr $hb]
                                               ? [dict get $hcounts $addr $hb] : 0) + 1}]
        }
        dict set buckets $addr $b [expr {([dict exists $buckets $addr $b]
                                          ? [dict get $buckets $addr $b] : 0) + 1}]
        incr n
    }
    return $n
}

# Abgeschlossene Stunden aus den Stundenzaehlern in die Spitzenwerte
# uebernehmen. Gewertet wird nur eine Stunde, die wir von Anfang bis Ende
# beobachtet haben: die Stunde, in der der Dienst gestartet ist, ist
# angebrochen und wuerde die Spitze zu niedrig ansetzen.
proc commitHours {hcountsVar peaksVar obsHour curHour} {
    upvar 1 $hcountsVar hcounts
    upvar 1 $peaksVar peaks
    set rest {}
    dict for {addr hl} $hcounts {
        set open {}
        dict for {hb c} $hl {
            if {$hb >= $curHour} {
                dict set open $hb $c
            } elseif {$hb > $obsHour} {
                if {![dict exists $peaks $addr] || $c > [dict get $peaks $addr]} {
                    dict set peaks $addr $c
                }
            }
        }
        if {[dict size $open]} { dict set rest $addr $open }
    }
    set hcounts $rest
}

# Buckets aelter als das Auswertefenster verwerfen
proc pruneBuckets {bucketsVar minBucket} {
    upvar 1 $bucketsVar buckets
    set out {}
    dict for {addr bl} $buckets {
        set keep {}
        dict for {b c} $bl {
            if {$b >= $minBucket} { dict set keep $b $c }
        }
        if {[dict size $keep]} { dict set out $addr $keep }
    }
    set buckets $out
}

# Summe je Absender ab minBucket (alles Neuere zaehlt mit)
proc windowCounts {buckets minBucket} {
    set out {}
    dict for {addr bl} $buckets {
        set s 0
        dict for {b c} $bl { if {$b >= $minBucket} { incr s $c } }
        if {$s > 0} { dict set out $addr $s }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Alarm

proc fireAlarm {cfg msg} {
    global TRIGGER
    set var [dict get $cfg alarm_var]
    set int [expr {[dict get $cfg alarm_internal] ? "true" : "false"}]
    set msg [rftl::sanitize $msg]
    if {![file executable $TRIGGER]} {
        logmsg err "triggerAlarm.tcl nicht gefunden - Alarm: $msg"
        return 0
    }
    if {[catch {exec $TRIGGER $msg $var $int} err]} {
        logmsg err "triggerAlarm.tcl fehlgeschlagen ($err) - Alarm: $msg"
        return 0
    }
    logmsg warning "ALARM: $msg"
    return 1
}

# ---------------------------------------------------------------------------
# Hauptschleife

# Quittierte Alarme uebernehmen: der Anwender sagt "dieser hohe Wert ist
# normal", also wird der Vergleichswert des Geraets auf die quittierte Rate
# angehoben. Die Alarmschwelle kommt danach obendrauf - bei +50 % meldet sich
# das Geraet erst wieder, wenn es die quittierte Rate um die Haelfte
# uebersteigt. Rueckgaengig macht das ein Zuruecksetzen der Lernphase.
proc applyAcks {st} {
    set acks [rftl::takeAcks]
    if {![llength $acks]} { return $st }
    set peaks    [stGet $st peaks {}]
    set baseline [stGet $st baseline {}]
    set alarms   [stGet $st alarms {}]
    set log      [stGet $st acks {}]
    foreach e $acks {
        lassign $e addr rate ts
        if {![string is double -strict $rate]} { continue }
        # die Stundenspitze ist der Vergleichswert; fehlt sie, ist es der
        # Mittelwert - dann wird der angehoben
        if {[dict exists $peaks $addr] && [dict get $peaks $addr] > 0} {
            set oldv [dict get $peaks $addr]
            set newv [expr {$rate > $oldv ? int(ceil($rate)) : $oldv}]
            dict set peaks $addr $newv
            set what "Stundenspitze"
        } elseif {[dict exists $baseline $addr]} {
            set oldv [dict get $baseline $addr]
            set newv [expr {$rate > $oldv ? double($rate) : $oldv}]
            dict set baseline $addr $newv
            set what "Mittelwert"
        } else {
            logmsg warning "Quittierung fuer unbekanntes Geraet $addr verworfen"
            continue
        }
        if {[dict exists $alarms $addr]} { dict unset alarms $addr }
        dict set log $addr [dict create ts $ts from [format %.1f $oldv] \
                                        to [format %.1f $newv] what $what]
        logmsg notice "quittiert: [deviceLabel $addr] - $what von\
                       [format %.0f $oldv] auf [format %.0f $newv] Pakete/h angehoben"
    }
    dict set st peaks $peaks
    dict set st baseline $baseline
    dict set st alarms $alarms
    dict set st acks $log
    return $st
}

proc resetState {cfg reason} {
    logmsg notice "Lernphase zurueckgesetzt ($reason)"
    return [dict create \
        phase learning \
        learn_started [clock seconds] \
        learn_sec 0 \
        counts {} \
        baseline {} \
        peaks {} \
        baseline_at 0 \
        offsets {} \
        alarms {} \
        acks {} \
        reset_at [dict get $cfg reset_at] \
        version 1]
}

proc main {} {
    global cfg MMDCONF RFDCONF MMDPREFIX RFDPREFIX BUCKET_SEC

    set cfg [rftl::readConfig]
    set st [rftl::readState]
    if {![dict exists $st phase] || ![dict exists $st version] ||
        [dict get $st version] ne "1"} {
        set st [resetState $cfg "Erststart"]
    }
    # Zustandsdateien aelterer Versionen kennen die Stundenspitzen noch
    # nicht. Sie bleiben dann leer, und der Vergleich faellt geraeteweise
    # auf den Mittelwert zurueck, bis einmal neu gelernt wurde.
    if {![dict exists $st peaks]} { dict set st peaks {} }

    logmsg notice "gestartet (Phase [dict get $st phase], aktiv=[dict get $cfg enabled],\
                   Vergleich [dict get $cfg ref_mode])"

    # Lesezeiger auf das aktuelle Dateiende setzen und die Uhr der erfassten
    # Zeit neu stellen - erst ab jetzt sehen wir den Funkverkehr wieder
    foreach {k conf prefix} [list mmd $MMDCONF $MMDPREFIX rfd $RFDCONF $RFDPREFIX] {
        seekToEnd $k [readTrafficLogDir $conf] $prefix st
    }
    dict set st last_check [clock seconds]

    # Kurzzeitstatistik lebt nur im Speicher; nach einem Neustart muss sich
    # das Auswertefenster erst wieder fuellen, bevor Alarme sinnvoll sind
    set buckets {}
    set hcounts {}
    set dedup {}
    set runStart [clock seconds]
    # die Stunde, in der wir angefangen haben zu beobachten, ist angebrochen
    # und darf nicht als Stundenspitze gewertet werden
    set obsHour [expr {$runStart / 3600}]

    while {1} {
        set cfg [rftl::readConfig]
        set now [clock seconds]

        # Reset-Anforderung aus der Weboberflaeche
        if {[dict get $cfg reset_at] ne [dict get $st reset_at]} {
            set st [resetState $cfg "Anforderung ueber die Weboberflaeche"]
            set buckets {}
            set hcounts {}
            set dedup {}
            set runStart $now
            set obsHour [expr {$now / 3600}]
        }

        set st [applyAcks $st]

        if {[dict get $cfg enabled]} {
            set st [cycle $cfg $st buckets hcounts dedup $runStart $obsHour $now]
        } else {
            # im ausgeschalteten Zustand nur den Dateizeiger nachfuehren,
            # damit nach dem Einschalten keine alten Zeilen nachlaufen
            foreach {k conf prefix} [list mmd $MMDCONF $MMDPREFIX rfd $RFDCONF $RFDPREFIX] {
                readNewLines $k [readTrafficLogDir $conf] $prefix st
            }
            dict set st last_check $now
            dict set st enabled 0
            # keine veralteten Raten in der Oberflaeche stehen lassen
            dict set st recent {}
            dict set st recent_sec 0
            # Geraeteanzahl trotzdem fuehren (die Liste ist eine Stunde
            # gueltig, kostet also kaum ReGa-Aufrufe) - so sieht man schon
            # vor dem Einschalten, wie viele Geraete ueberwacht wuerden
            refreshDevMap
            dict set st known_devices [dict size $::devMap]
            dict set st known_only [dict get $cfg known_only]
        }
        rftl::writeState $st

        after [expr {[dict get $cfg interval_sec] * 1000}]
    }
}

proc cycle {cfg st bucketsVar hcountsVar dedupVar runStart obsHour now} {
    upvar 1 $bucketsVar buckets
    upvar 1 $hcountsVar hcounts
    upvar 1 $dedupVar dedup
    global MMDCONF RFDCONF MMDPREFIX RFDPREFIX BUCKET_SEC

    set ignore [split [dict get $cfg ignore_addrs] ","]
    set counts [dict get $st counts]
    # Toleranz fuer den gelesenen Zeitstempel: normal liegt eine Zeile
    # hoechstens einen Lesezyklus zurueck, mit Reserve fuer Taktabweichungen
    set tsTol [expr {max([dict get $cfg interval_sec] * 2, 600)}]
    # Entdopplungsfenster: so lange koennen sich die beiden Quellen
    # unterscheiden, bis beide dieselbe Sendung geliefert haben
    set dedMin [expr {($now - $tsTol * 2) / $BUCKET_SEC}]
    set kept {}
    dict for {dk db} $dedup { if {$db >= $dedMin} { dict set kept $dk $db } }
    set dedup $kept
    set learning [expr {[dict get $st phase] eq "learning"}]

    # Geraeteliste der CCU - Namen fuer den Alarmtext und, bei known_only,
    # die Positivliste der zu ueberwachenden Absender
    set knownOnly [dict get $cfg known_only]
    set haveMap [refreshDevMap]
    set known $::devMap
    dict set st known_devices [dict size $known]
    dict set st known_only $knownOnly
    if {$knownOnly && !$haveMap} {
        # ohne Geraeteliste wuerde nichts gezaehlt - das muss sichtbar sein
        warnOnce "Geraeteliste der CCU nicht verfuegbar - es wird nichts\
                  gezaehlt, solange \"nur bekannte Geraete\" aktiv ist"
    }

    # neue Logzeilen beider Quellen einlesen und verbuchen
    set lines 0
    foreach {k conf prefix} [list mmd $MMDCONF $MMDPREFIX rfd $RFDCONF $RFDPREFIX] {
        set text [readNewLines $k [readTrafficLogDir $conf] $prefix st]
        if {$text ne ""} {
            incr lines [parseInto $text counts buckets hcounts dedup $ignore $learning \
                                  $knownOnly $known $now $tsTol]
        }
    }
    dict set st counts $counts

    # abgeschlossene Stunden in die Spitzenwerte uebernehmen
    if {$learning} {
        set peaks [stGet $st peaks {}]
        commitHours hcounts peaks $obsHour [expr {$now / 3600}]
        dict set st peaks $peaks
    }

    # erfasste Zeit fortschreiben. Nur die tatsaechlich gelaufene Zeit zaehlt
    # (gedeckelt), sonst wuerde eine Ausfallzeit die Baseline verwaessern.
    set last [expr {[dict exists $st last_check] ? [dict get $st last_check] : 0}]
    set iv [dict get $cfg interval_sec]
    if {$last > 0 && $now > $last} {
        set delta [expr {min($now - $last, $iv * 3)}]
        if {[dict get $st phase] eq "learning"} {
            dict set st learn_sec [expr {[dict get $st learn_sec] + $delta}]
        }
    }
    dict set st last_check $now
    dict set st enabled 1

    # Auswertefenster
    set winSec [expr {[dict get $cfg window_min] * 60}]
    set minBucket [expr {($now - $winSec) / $BUCKET_SEC}]
    pruneBuckets buckets $minBucket
    set recent [windowCounts $buckets $minBucket]
    dict set st recent $recent
    dict set st recent_sec [expr {min($now - $runStart, $winSec)}]
    dict set st window_sec $winSec

    # Lernphase abgeschlossen? -> Baseline einfrieren
    if {[dict get $st phase] eq "learning"} {
        set need [expr {[dict get $cfg learn_hours] * 3600}]
        if {[dict get $st learn_sec] >= $need} {
            set hours [expr {double([dict get $st learn_sec]) / 3600.0}]
            set bl {}
            dict for {addr c} $counts { dict set bl $addr [expr {$c / $hours}] }
            dict set st baseline $bl
            dict set st baseline_at $now
            dict set st phase monitoring
            # auch die angebrochene letzte Stunde noch werten: ihr Zaehler
            # ist immer kleiner als der einer vollen Stunde waere, taugt
            # also als Untergrenze und kann die Spitze nicht ueberhoehen
            set peaks [stGet $st peaks {}]
            commitHours hcounts peaks $obsHour [expr {$now / 3600 + 1}]
            dict set st peaks $peaks
            logmsg notice "Lernphase beendet - Vergleichswerte fuer [dict size $bl]\
                           Sender uebernommen ([dict size $peaks] mit Stundenspitze,\
                           Modus [dict get $cfg ref_mode])"
        }
    }

    if {[dict get $st phase] eq "monitoring"} {
        set st [evaluate $cfg $st $recent $runStart $now $winSec]
    }
    logdbg "Zyklus: $lines neue Zeilen, [dict size $recent] Sender im Fenster"
    return $st
}

# Vergleicht das aktuelle Fenster mit der gelernten Baseline und loest
# Alarme aus. Pro Geraet gilt eine Sperrzeit, damit ein dauerhaft
# auffaelliges Geraet nicht im Minutentakt Alarm schlaegt.
proc evaluate {cfg st recent runStart now winSec} {
    # erst alarmieren, wenn das Fenster seit dem Start wirklich voll ist
    if {$now - $runStart < $winSec} { return $st }

    set baseline [dict get $st baseline]
    set peaks    [stGet $st peaks {}]
    set refMode  [dict get $cfg ref_mode]
    set alarms   [dict get $st alarms]
    set thr      [expr {1.0 + [dict get $cfg threshold_pct] / 100.0}]
    set minPk    [dict get $cfg min_packets]
    set cool     [expr {[dict get $cfg cooldown_min] * 60}]
    set winH     [expr {$winSec / 3600.0}]

    dict for {addr actual} $recent {
        if {$actual < $minPk} { continue }
        set seen [dict exists $baseline $addr]

        # Vergleichswert bestimmen. "peak" nimmt die hoechste Stundenrate der
        # Lernphase - der Mittelwert liegt bei Geraeten mit Tagesrhythmus
        # unter dem normalen Tagesniveau und wuerde staendig ausloesen.
        # Fehlt eine Stundenspitze (das Geraet sendete nur in der
        # angebrochenen Startstunde), faellt es auf den Mittelwert zurueck.
        set refRate 0.0
        set refKind "Mittelwert"
        if {$refMode eq "peak" && [dict exists $peaks $addr] &&
            [dict get $peaks $addr] > 0} {
            # Telegramme in der staerksten Stunde = Pakete/h
            set refRate [expr {double([dict get $peaks $addr])}]
            set refKind "Spitze"
        } elseif {$seen} {
            set refRate [dict get $baseline $addr]
        }
        set expected [expr {$refRate * $winH}]

        if {!$seen || $expected <= 0} {
            if {![dict get $cfg alarm_new_dev]} { continue }
            set reason "neu"
        } elseif {$actual > $expected * $thr} {
            set reason "anstieg"
        } else {
            continue
        }

        # Sperrzeit je Geraet
        if {[dict exists $alarms $addr]} {
            set prev [dict get $alarms $addr ts]
            if {$now - $prev < $cool} { continue }
        }

        set rateNow [expr {$actual / $winH}]
        if {$reason eq "neu"} {
            set msg "[deviceLabel $addr] sendet [format %.0f $rateNow] Pakete/h -\
                     waehrend der Lernphase nicht gesehen"
        } else {
            set pct [expr {($actual / $expected - 1.0) * 100.0}]
            if {$refKind eq "Spitze"} {
                set msg "[deviceLabel $addr] sendet [format %.0f $rateNow] Pakete/h -\
                         mehr als in der staerksten Stunde der Lernphase mit\
                         [format %.0f $refRate] Pakete/h (+[format %.0f $pct] %)"
            } else {
                set msg "[deviceLabel $addr] sendet [format %.0f $rateNow] Pakete/h statt\
                         ueblich [format %.0f $refRate] Pakete/h (+[format %.0f $pct] %)"
            }
        }
        if {[fireAlarm $cfg $msg]} {
            dict set alarms $addr [dict create ts $now actual $actual \
                expected [format %.1f $refRate] rate [format %.1f $rateNow] \
                ref $refKind reason $reason msg $msg]
        }
    }
    # Alarme aelter als eine Woche nicht ewig mitschleppen
    set keep {}
    dict for {addr a} $alarms {
        if {$now - [dict get $a ts] <= 604800} { dict set keep $addr $a }
    }
    dict set st alarms $keep
    return $st
}

# ---------------------------------------------------------------------------
if {[catch {main} err]} {
    logmsg err "abgebrochen: $err"
    exit 1
}

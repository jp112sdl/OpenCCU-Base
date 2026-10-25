#!/bin/tclsh
# Tests der Funkaufkommen-Ueberwachung (bin/rftrafficwatch.tcl).
# Aufruf: tclsh tests/daemon.tcl   -- braucht nur tclsh, kein CCU-Umfeld.
#
# Die Zeitzone wird fest auf die der CCU gesetzt (POSIX-Form aus /etc/TZ),
# damit die Tests rund um die Zeitumstellung ueberall gleich laufen.
set ::env(TZ) "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00"

set here [file normalize [file dirname [info script]]]
source [file join $here .. lib rftl_alarm.tcl]
# den Daemon ohne seinen main-Aufruf laden
set fh [open [file join $here .. bin rftrafficwatch.tcl] r]
set src [read $fh]; close $fh
set src [string range $src 0 [expr {[string first "if {\[catch {main} err\]}" $src] - 1}]]
set src [string map {{source [file join $ADDONDIR "lib" "rftl_alarm.tcl"]} {}} $src]
eval $src

set fails 0
proc ok {name cond} {
    global fails
    if {[catch {uplevel 1 [list expr $cond]} r]} { puts "  ERR  $name: $r"; incr fails; return }
    if {$r} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
# eine BidCos-Logzeile bauen; cnt unterscheidet einzelne Sendungen
proc tele {ts cnt addr} {
    return "[clock format $ts -format {%Y-%m-%d %H:%M:%S}].000 RX BIDCOS LEN=0C\
            CNT=[format %02X $cnt] FLAGS=86 TYPE=5A FROM=$addr TO=000000 RSSI=-63 PAYLOAD=00\n"
}
set TOL 600

puts "--- Zeitzone der Testumgebung ---"
set tsCEST [clock scan "2026-10-25 00:30 UTC" -format "%Y-%m-%d %H:%M %Z"]
set tsCET  [clock scan "2026-10-25 01:30 UTC" -format "%Y-%m-%d %H:%M %Z"]
ok {Umstellung vorhanden} {$tsCET - $tsCEST == 3600}
ok {02:30 ist mehrdeutig} {[clock scan "2026-10-25 02:30" -format "%Y-%m-%d %H:%M"] == $tsCET}

puts "--- bucketOf prueft den Zeitstempel gegen die Lesezeit ---"
set now [clock scan "2026-10-24 14:00:00" -format "%Y-%m-%d %H:%M:%S"]
ok {normaler Stempel gilt}     {[bucketOf 2026-10-24 "13:58:30" [expr {$now + 90}] $TOL] == (($now - 90) / 60)}
ok {Zukunftsstempel verworfen} {[bucketOf 2026-10-24 "15:00:00" $now $TOL] == ($now / 60)}
ok {Altstempel verworfen}      {[bucketOf 2026-10-24 "12:00:00" $now $TOL] == ($now / 60)}

puts "--- Zeitumstellung: die Stunde darf nicht doppelt zaehlen ---"
set bFirst  [bucketOf 2026-10-25 "02:30:00" $tsCEST $TOL]
set bSecond [bucketOf 2026-10-25 "02:30:00" $tsCET  $TOL]
ok {erster Durchlauf auf Echtzeit} {$bFirst == ($tsCEST / 60)}
ok {zweiter Durchlauf auf Stempel} {$bSecond == ($tsCET / 60)}
ok {genau eine Stunde Abstand}     {($bSecond - $bFirst) == 60}

puts "--- Fenstersumme ueber die Umstellung (Ende-zu-Ende) ---"
set buckets {}; set counts {}; set hc {}; set ded {}
for {set i 0} {$i < 60} {incr i} {
    set real [expr {$tsCEST - 1800 + $i * 60}]
    parseInto [tele $real $i A1B2C3] counts buckets hc ded {} 1 0 {} $real $TOL
}
# zweiter Durchlauf: dieselben Wanduhrzeiten, eine Stunde spaeter real.
# Das Entdopplungsfenster hat die alten Schluessel laengst verworfen.
set ded {}
for {set i 0} {$i < 60} {incr i} {
    set real [expr {$tsCET - 1800 + $i * 60}]
    parseInto [tele [expr {$real - 3600}] [expr {$i + 100}] A1B2C3] \
              counts buckets hc ded {} 1 0 {} $real $TOL
}
set win [windowCounts $buckets [expr {(($tsCET + 1800) - 3600) / 60}]]
ok {120 Telegramme gezaehlt} {[dict get $counts A1B2C3] == 120}
ok {Fenster haelt nur 60}    {[dict get $win A1B2C3] == 60}

puts "--- Entdopplung: eine Sendung, zwei Empfaenger ---"
set nowD [clock seconds]
set dc {}; set db {}; set dh {}; set dd {}
parseInto [tele $nowD 42 A1B2C3] dc db dh dd {} 1 0 {} $nowD $TOL
ok {erste Quelle zaehlt}        {[dict get $dc A1B2C3] == 1}
parseInto [tele $nowD 42 A1B2C3] dc db dh dd {} 1 0 {} $nowD $TOL
ok {zweite Quelle zaehlt nicht} {[dict get $dc A1B2C3] == 1}
parseInto [tele $nowD 43 A1B2C3] dc db dh dd {} 1 0 {} $nowD $TOL
ok {anderer CNT zaehlt}         {[dict get $dc A1B2C3] == 2}
parseInto [tele [expr {$nowD + 1}] 42 A1B2C3] dc db dh dd {} 1 0 {} [expr {$nowD + 1}] $TOL
ok {andere Sekunde zaehlt}      {[dict get $dc A1B2C3] == 3}
parseInto [tele $nowD 42 DDEEFF] dc db dh dd {} 1 0 {} $nowD $TOL
ok {anderer Absender zaehlt}    {[dict get $dc DDEEFF] == 1}
set sumB 0
dict for {bk bv} [dict get $db A1B2C3] { incr sumB $bv }
ok {Fenster ebenfalls entdoppelt} {$sumB == [dict get $dc A1B2C3]}
set dd {}
parseInto [tele $nowD 42 A1B2C3] dc db dh dd {} 1 0 {} $nowD $TOL
ok {nach Pruning wieder zaehlbar} {[dict get $dc A1B2C3] == 4}

puts "--- nur angelernte Geraete ---"
set nw [clock seconds]
set c {}; set b {}; set h {}; set dz {}
parseInto "[tele $nw 1 4E9505][tele $nw 2 ABCDEF]" c b h dz {} 1 1 [dict create 4E9505 {Bad}] $nw $TOL
ok {fremde Adresse raus} {[dict exists $c 4E9505] && ![dict exists $c ABCDEF]}
set c2 {}; set b2 {}; set h2 {}; set dz2 {}
parseInto "[tele $nw 1 4E9505][tele $nw 2 ABCDEF]" c2 b2 h2 dz2 {} 1 0 {} $nw $TOL
ok {ohne Filter beide}   {[dict size $c2] == 2}
set c3 {}; set b3 {}; set h3 {}; set dz3 {}
parseInto "[tele $nw 1 4E9505]" c3 b3 h3 dz3 {} 1 1 {} $nw $TOL
ok {leere Liste -> nichts} {[dict size $c3] == 0}

puts "--- Vergleichswert Spitze vs. Mittelwert ---"
set ::TRIGGER [file join $here trig.sh]
set fh [open $::TRIGGER w]; puts $fh "#!/bin/sh\nexit 0"; close $fh
file attributes $::TRIGGER -permissions 0755
proc deviceLabel {a} { return "Test ($a)" }
set cfgP [rftl::clampConfig [dict merge $rftl::defaults \
    {ref_mode peak threshold_pct 50 window_min 60 min_packets 20 cooldown_min 60}]]
set stM [dict create phase monitoring baseline {A 60.0} peaks {A 113} alarms {} version 1]
set old [expr {$nw - 7200}]
ok {Spitze: 148 ruhig}        {![dict exists [evaluate $cfgP $stM {A 148} $old $nw 3600] alarms A]}
ok {Spitze: 200 loest aus}    {[dict exists [evaluate $cfgP $stM {A 200} $old $nw 3600] alarms A]}
ok {Meldung nennt die Spitze} {[string match "*staerksten Stunde*113 Pakete/h*" \
    [dict get [evaluate $cfgP $stM {A 200} $old $nw 3600] alarms A msg]]}
ok {Mittelwert als Rueckfall} {[dict get [evaluate $cfgP \
    [dict create phase monitoring baseline {A 60.0} peaks {} alarms {} version 1] \
    {A 148} $old $nw 3600] alarms A ref] eq "Mittelwert"}
ok {unter Mindestmenge still}  {![dict exists [evaluate $cfgP $stM {A 19} $old $nw 3600] alarms A]}
ok {Aufwaermsperre}            {![dict exists [evaluate $cfgP $stM {A 999} [expr {$nw - 60}] $nw 3600] alarms A]}
file delete -force $::TRIGGER

puts "--- Stundenspitzen (commitHours) ---"
set hcx [dict create A [dict create 100 999 101 30 102 55 103 40 104 7]]
set pk {}
commitHours hcx pk 100 104
ok {Startstunde verworfen}  {[dict get $pk A] == 55}
ok {laufende Stunde bleibt} {[dict get $hcx A 104] == 7}
set hcy [dict create A [dict create 105 3]]
commitHours hcy pk 100 106
ok {Spitze sinkt nicht}     {[dict get $pk A] == 55}

puts "--- Konfiguration ---"
ok {ref_mode Vorgabe peak}  {[dict get $rftl::defaults ref_mode] eq "peak"}
ok {known_only Vorgabe an}  {[dict get $rftl::defaults known_only] == 1}
ok {ungueltiger ref_mode}   {[dict get [rftl::clampConfig [dict merge $rftl::defaults {ref_mode x}]] ref_mode] eq "peak"}
ok {Intervall-Untergrenze}  {[dict get [rftl::clampConfig [dict merge $rftl::defaults {interval_sec 1}]] interval_sec] == 30}
ok {exec-Zeichen entfernt}  {![string match {*[<>|]*} [rftl::sanitize "a<b>c|d"]]}
ok {Quotes entfernt}        {![string match {*"*} [rftl::sanitize {a"b}]]}

puts ""
if {$fails} { puts "=== $fails FEHLER ==="; exit 1 }
puts "=== alle Tests bestanden ==="

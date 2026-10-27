#!/bin/tclsh
# Tests der API (www/api.cgi). Aufruf: tclsh tests/api.tcl
#
# api.cgi loest Bibliothek, VERSION und die Zustandsdateien relativ zu sich
# selbst auf. Der Test baut deshalb einen Wegwerf-Addonordner und laesst das
# Script dort laufen - das Addon-Verzeichnis im Repo bleibt unberuehrt.
# Geprueft wird vor allem, dass jede Antwort gueltiges JSON ohne "error" ist;
# genau daran scheitern Tippfehler und Variablen in falscher Reihenfolge.

set here [file normalize [file dirname [info script]]]
set src  [file join $here ..]
set tmp  [file join $here apitest.tmp]

file delete -force $tmp
file mkdir [file join $tmp www] [file join $tmp lib]
file copy -force [file join $src www api.cgi]        [file join $tmp www]
file copy -force [file join $src lib rftl_alarm.tcl] [file join $tmp lib]
set fh [open [file join $tmp VERSION] w]; puts -nonewline $fh "9.99"; close $fh

set fails 0
proc ok {name cond} {
    global fails
    if {[catch {uplevel 1 [list expr $cond]} r]} { puts "  ERR  $name: $r"; incr fails; return }
    if {$r} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
# api.cgi aufrufen und nur den Rumpf zurueckgeben
proc call {qs} {
    global tmp
    set ::env(QUERY_STRING) $qs
    set out ""
    catch {exec tclsh [file join $tmp www api.cgi]} out
    set i [string first "\n\n" [string map {\r\n \n} $out]]
    if {$i < 0} { return $out }
    return [string trim [string range [string map {\r\n \n} $out] [expr {$i + 2}] end]]
}
proc field {json key} {
    if {[regexp "\"$key\":\(\[^,\}\]+\)" $json -> v]} { return [string trim $v \"] }
    return ""
}
proc setState {d} {
    global tmp
    set fh [open [file join $tmp alarm.state] w]; puts -nonewline $fh $d; close $fh
}

puts "--- Grundkommandos liefern gueltiges JSON ---"
foreach cmd {version alarmcfg alarmstate} {
    set r [call "cmd=$cmd"]
    ok "cmd=$cmd ohne Fehler" {![string match {*"error"*} $r]}
    ok "cmd=$cmd ist JSON"    {[string index $r 0] eq "\{" && [string index $r end] eq "\}"}
}
ok {version kommt aus der Datei} {[field [call "cmd=version"] version] eq "9.99"}
ok {alarmstate hat devices}      {[string match {*"devices":*} [call "cmd=alarmstate"]]}
ok {alarmstate hat alarms}       {[string match {*"alarms":*} [call "cmd=alarmstate"]]}
ok {unbekanntes cmd meldet sich} {[string match {*unknown cmd*} [call "cmd=quatsch"]]}

puts "--- Konfiguration schreiben und begrenzen ---"
ok {Vorgabe peak}        {[field [call "cmd=alarmcfg"] ref_mode] eq "peak"}
ok {Schwelle setzbar}    {[field [call "cmd=alarmcfg&set=1&threshold_pct=50"] threshold_pct] == 50}
ok {Untergrenze greift}  {[field [call "cmd=alarmcfg&set=1&interval_sec=1"] interval_sec] == 30}
ok {ref_mode geprueft}   {[field [call "cmd=alarmcfg&set=1&ref_mode=quatsch"] ref_mode] eq "peak"}
# der Decoder liest %C3%BC als UTF-8, jsonEscape gibt es als Escape-Sequenz
# aus - in der Antwort steht also \u00fc, nicht das Zeichen selbst
ok {Umlaut korrekt dekodiert} {[field [call "cmd=alarmcfg&set=1&alarm_var=Funk%C3%BCberwachung"] alarm_var] eq {Funk\u00fcberwachung}}
ok {exec-Zeichen weg}    {![string match {*[<>|]*} [field [call "cmd=alarmcfg&set=1&alarm_var=a%3Eb%7Cc"] alarm_var]]}

puts "--- Quittieren ---"
setState "phase monitoring baseline {4E6AE9 12.0} peaks {4E6AE9 66}\
          alarms {4E6AE9 {ts 1000 actual 118 expected 66.0 rate 118.0 ref Spitze reason anstieg msg x}}\
          recent {4E6AE9 135} window_sec 3600 acks {} version 1"
ok {ohne Adresse abgewiesen}   {[string match {*error*} [call "cmd=alarmack"]]}
ok {krumme Adresse abgewiesen} {[string match {*error*} [call "cmd=alarmack&addr=XYZ"]]}
ok {unbekanntes Geraet abgewiesen} {[string match {*kein Messwert*} [call "cmd=alarmack&addr=ABCDEF"]]}
set r [call "cmd=alarmack&addr=4e6ae9"]
ok {Quittierung angenommen}    {[string match {*"ok":true*} $r]}
ok {Adresse normalisiert}      {[field $r addr] eq "4E6AE9"}
# gemeldet waren 118, gemessen 135 -> der hoehere Wert zaehlt
ok {hoehere Rate gewinnt}      {[field $r rate] == 135.0}
ok {Warteschlange angelegt}    {[file exists [file join $tmp alarm.ack]]}
ok {offene Quittierung sichtbar} {[string match {*"ack_pending":1*} [call "cmd=alarmstate"]]}
ok {Zustand noch unveraendert} {[string match {*"peak":66*} [call "cmd=alarmstate"]]}

puts "--- Lernphase zuruecksetzen ---"
set r1 [call "cmd=alarmreset"]
ok {reset bestaetigt}   {[string match {*"ok":true*} $r1]}
set t1 [field $r1 reset_at]
set t2 [field [call "cmd=alarmreset"] reset_at]
ok {reset_at steigt}    {$t2 > $t1}
ok {reset_at in der Conf} {[field [call "cmd=alarmcfg"] reset_at] == $t2}

file delete -force $tmp
puts ""
if {$fails} { puts "=== $fails FEHLER ==="; exit 1 }
puts "=== alle Tests bestanden ==="

# Tests

Zwei eigenständige Testläufe ohne Testframework — beide finden ihre Dateien
relativ zu sich selbst und brauchen keine laufende CCU.

```sh
tclsh tests/daemon.tcl     # Funkaufkommen-Ueberwachung (bin/rftrafficwatch.tcl)
tclsh tests/api.tcl        # API (www/api.cgi)
node  tests/ui.js          # Weboberflaeche (www/index.html)
```

`api.tcl` baut einen Wegwerf-Addonordner und lässt `api.cgi` dort laufen, damit
die echten Konfigurations- und Zustandsdateien unberührt bleiben; geprüft wird
vor allem, dass jede Antwort gültiges JSON ohne `error` ist — genau daran
scheitern Tippfehler und Variablen in falscher Reihenfolge.

`daemon.tcl` setzt die Zeitzone fest auf die der CCU
(`CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00`), damit die Tests rund um die
Zeitumstellung überall gleich laufen. `ui.js` schneidet den `<script>`-Block
aus `www/index.html` und führt ihn gegen einen minimalen DOM-Stub aus; geprüft
wird nur, was rechnet (Statusspalte, DutyCycle), nicht das Aussehen.

Auf dem Build-Host ist in der Regel kein `node` installiert — `ui.js` läuft
dann auf einer CCU:

```sh
scp -r tests www root@<ccu>:/tmp/rftl-test/ && ssh root@<ccu> 'cd /tmp/rftl-test && node tests/ui.js'
```

Beide Läufe enden mit `=== alle Tests bestanden ===` und Exitcode 0, sonst mit
der Zahl der Fehlschläge und Exitcode 1.

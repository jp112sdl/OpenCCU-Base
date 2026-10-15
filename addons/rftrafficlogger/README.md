# RFTrafficLogger

Port des [AskSinAnalyzerXS](https://github.com/psi-4ward/AskSinAnalyzerXS) direkt auf die CCU:
Logging und grafische Auswertung aller Homematic-Funktelegramme (BidCos RX/TX dekodiert
inkl. RSSI, HmIP als Rohdaten) — ohne zusätzlichen Arduino-Sniffer.

## Architektur

```
Funkmodul ⇄ multimacd (TrafficLogger)          Funk-LAN-Gateway ⇄ rfd (TrafficLogger)
                │  multimacd-traffic-YYYY-MM-DD.log        │  rfd-traffic-YYYY-MM-DD.log
                │  (Sicht des lokalen Funkmoduls)          │  (nur nicht-lokale Interfaces,
                │                                          │   mit IFACE=<Gateway-Serial>)
                └────────────────┬─────────────────────────┘
                   ┌─────────────┴──────────────┐
                   ▼                            ▼
      www/api.cgi (tclsh, lighttpd)   bin/rftrafficwatch.tcl (Daemon)
                   │  Offset-Tailing,           │  Lernphase → Baseline →
                   │  Geräteliste (ReGa)        │  Überwachung
                   │                            ▼
                   │                  /bin/triggerAlarm.tcl → Alarm-Systemvariable
                   ▼
      www/index.html (Single-Page-UI, kein externes CDN)
```

- **Datenquellen** sind die `TrafficLogger` in `src/multimacd` (lokales
  Funkmodul, BidCos + HmIP) und `src/rfd` (Telegramme über Funk-LAN-Gateways,
  nur BidCos, mit `IFACE=<Gateway-Serial>`). Beide werden gleich konfiguriert
  (Konfig-Schalter `Traffic Log = 1`, optional `Traffic Log Directory = /var/log`
  in der multimacd.conf bzw. rfd.conf) und schreiben bewusst in **getrennte**
  Tagesdateien, damit sich keine zwei Prozesse eine Logdatei teilen. `api.cgi`
  liest das jeweilige `Traffic Log Directory` aus `/etc/config/multimacd.conf`
  bzw. `/etc/config/rfd.conf` (Fallback `/var/log`).
- Die UI zeigt je Telegramm in der Spalte **„Via"**, ob es über das lokale
  Funkmodul lief („direkt") oder über ein Funk-LAN-Gateway („via <Serial>"),
  und bietet einen **Weg-Filter** (direkt / via LAN-Gateway / einzelnes
  Gateway, sobald mehrere gesehen wurden). Achtung: Ein Telegramm, das sowohl
  das lokale Modul als auch ein Gateway empfängt, erscheint als zwei Zeilen —
  je Empfänger eine, mit dessen RSSI.
- **`www/api.cgi`** — Endpunkte:
  - `?cmd=dates` — verfügbare Log-Tage (JSON)
  - `?cmd=data&date=YYYY-MM-DD&offset=N` — neue Logzeilen ab Datei-Offset (Live-Polling)
  - `?cmd=devlist[&refresh=1]` — Geräteliste (BidCos **und** HmIP): RF-Adresse,
    Name und Typ via ReGa aus den `DEVDESC`-Metadaten (enthalten `RF_ADDRESS`
    auch für HmIP-Geräte; rfd auf Port 2001 kennt nur BidCos), dazu
    `hmip_central`; Cache `/tmp/rftrafficlogger.devlist.json` (600 s)
  - `?cmd=alarmcfg[&set=1&<key>=<wert>…]` — Konfiguration der
    Funkaufkommen-Überwachung lesen bzw. schreiben; die Antwort enthält immer
    die tatsächlich gespeicherten (ggf. auf gültige Bereiche begrenzten) Werte
  - `?cmd=alarmstate` — Lernfortschritt, Baseline und aktuelle Rate je Sender,
    ausgelöste Alarme
  - `?cmd=alarmreset` — gelernte Werte verwerfen, Lernphase neu beginnen
- **`www/index.html`** — Telegramm-Tabelle (live), Filter (Suche, Richtung,
  Protokoll, Typ, Gerät), Analyse-Tab (RSSI-Verlauf, Telegramm-Rate,
  Geräte-Statistik mit DutyCycle-Schätzung), Alarm-Tab
  (Funkaufkommen-Überwachung), CSV-Export.
- **`bin/rftrafficwatch.tcl`** — Hintergrunddienst der
  Funkaufkommen-Überwachung (siehe unten).
- **`lib/rftl_alarm.tcl`** — gemeinsame Basis von `api.cgi` und Dienst:
  Vorgaben, Wertebereiche und Dateiformate stehen nur an einer Stelle.

## Funkaufkommen-Überwachung (Reiter „Alarm")

Erkennt Geräte, die deutlich mehr senden als üblich, und löst dann einen Alarm
in einer Systemvariablen der ReGa aus — über `/bin/triggerAlarm.tcl`, also
dieselbe Mechanik, die auch `monit` für seine Watchdog-Meldungen nutzt. Die
Variable wird beim ersten Alarm automatisch als Alarmvariable angelegt.

Die Erkennung läuft als **Hintergrunddienst** (`bin/rftrafficwatch.tcl`), nicht
im Browser: sie arbeitet also auch bei geschlossener Weboberfläche. Gestartet
und gestoppt wird er vom rc.d-Script (`start`/`stop`), beim Boot über
`S98StartAddons` — und damit **nach** multimacd/rfd, sodass die Logs schon
geschrieben werden.

### Ablauf

1. **Lernphase** (Vorgabe 48 h): Der Dienst liest die Traffic-Logs mit und
   zählt je Absender die Telegramme. Angerechnet wird nur Zeit, in der er
   tatsächlich gelaufen ist (gedeckelt auf das Dreifache des Prüfintervalls) —
   eine Ausfallzeit verwässert die gelernten Werte also nicht. Beim Start und
   nach einem Reset wird an das aktuelle Ende der Logdateien gesprungen: schon
   geschriebene Telegramme nachträglich einzulesen würde Pakete zählen, für die
   keine Messdauer läuft, und die gelernte Rate massiv zu hoch ansetzen.
2. **Baseline**: Nach Ablauf der Lernphase wird je Absender die übliche Rate in
   **Paketen/Stunde** berechnet (flacher Mittelwert über die gesamte Lernphase)
   und eingefroren — bis zum nächsten Reset. Danach laufen die Lernzähler nicht
   weiter, „gelernt aus N Paketen" bleibt also eine ehrliche Angabe.
3. **Überwachung**: In jedem Prüfintervall wird das Aufkommen im
   Auswertefenster (Vorgabe 60 min) mit der Baseline verglichen. Liegt es um
   mehr als die Alarmschwelle darüber (Vorgabe 100 %, also mehr als das
   Doppelte), gibt es Alarm. Nach einem Neustart des Dienstes wird erst
   alarmiert, wenn das Auswertefenster einmal vollständig gefüllt ist.

Erfasst werden **BidCos und HmIP**: bei BidCos ist der Absender das `FROM`-Feld,
bei HmIP steht er an fester Position im Rohframe (Byte 4–6) — genau wie die
Telegrammtabelle ihn auflöst. Gezählt werden RX **und** TX, der Absender einer
TX-Zeile ist also die Zentrale selbst.

### Einstellungen

| Einstellung | Vorgabe | Bedeutung |
|---|---|---|
| Überwachung aktiv | aus | Schaltet die Datensammlung und die Alarme ein |
| Alarmschwelle | 100 % | Anstieg gegenüber der Baseline, ab dem alarmiert wird |
| Auswertefenster | 60 min | Zeitraum, dessen Aufkommen verglichen wird |
| Mindestmenge | 20 Pakete | Darunter kein Alarm — schützt vor Fehlalarmen bei Geräten, die normalerweise kaum senden |
| Lernphase | 48 h | Dauer der Datensammlung vor der ersten Überwachung |
| Sperrzeit | 60 min | Mindestabstand zwischen zwei Alarmen desselben Geräts |
| Prüfintervall | 300 s | Abstand zweier Prüfungen |
| Systemvariable | `RFTrafficLogger: Funkaufkommen` | Name der Alarmvariablen; das betroffene Gerät steht im Meldungstext |
| intern | aus | Legt die Variable als interne Systemvariable an |
| Neue Sender | aus | Alarmiert auch bei Geräten, die in der Lernphase nicht vorkamen |
| Ignorieren | — | Funkadressen, die gar nicht betrachtet werden (kommagetrennt) |
| Debug | aus | Zusätzliche Meldungen ins Syslog (`logger -t rftrafficwatch`) |

Der Dienst liest die Konfiguration in **jedem Zyklus neu** — Änderungen greifen
ohne Neustart. Alle Werte werden serverseitig auf gültige Bereiche begrenzt
(`lib/rftl_alarm.tcl`); der Variablenname wird zusätzlich von
Anführungszeichen, Backslashes und Steuerzeichen befreit, weil
`triggerAlarm.tcl` ihn in ein ReGa-Script einsetzt.

Mit **„Lernphase zurücksetzen"** werden Baseline, Zähler und Alarmhistorie
verworfen und die Sammlung beginnt von vorn.

### Dateien

Beide liegen unter `/usr/local/addons/rftrafficlogger/`, also auf der
persistenten Partition — der Lernfortschritt übersteht Reboots, Firmware- und
Addon-Updates (das `update_script` lässt sie unangetastet):

- `alarm.conf` — Konfiguration als `key=value`, von der Weboberfläche
  geschrieben
- `alarm.state` — Phase, erfasste Zeit, Zähler, Baseline, Datei-Lesezeiger und
  Alarmhistorie (Tcl-Dict, vom Dienst geschrieben)

## Installation auf der CCU

Voraussetzung: multimacd mit TrafficLogger (dieses Repo) und aktiviertem
`Traffic Log = 1` im Konfig-Template.

### Variante 1: Addon-Paket (WebUI)

```sh
./build-addon.sh        # erzeugt rftrafficlogger-<version>.tar.gz
```

Das Paket über die WebUI installieren: *Einstellungen → Systemsteuerung →
Zusatzsoftware → Datei auswählen → Installieren*. Das Addon erscheint danach
in der Zusatzsoftware-Liste (mit Uninstall und Link zur UI).
Paketinhalt: `update_script` (Installer), `rc.d/rftrafficlogger`
(WebUI-Integration: info/uninstall, Boot-Hook: init, Dienst: start/stop),
`rftrafficlogger/` (Payload inkl. Binaries/Libraries für x86_64 sowie
`bin/`+`lib/` der Funkaufkommen-Überwachung).

Der Installer bringt **multimacd und rfd mit TrafficLogger samt der
benötigten Libraries mit** (derzeit nur x86_64, z. B. OVA-CCU) und
installiert sie nach `/bin` bzw. `/lib`; die Originale werden einmalig als
`*.pre-rftrafficlogger` gesichert und beim Uninstall wiederhergestellt.
Außerdem werden die Parameter `Traffic Log = 1` und
`Traffic Log Directory = /var/log` automatisch ergänzt, sofern noch nicht
vorhanden: in `/etc/config_templates/multimacd.conf` (daraus wird
`/var/etc/multimacd.conf` bei jedem Start generiert),
`/etc/config_templates/rfd.conf` (greift bei Ersteinrichtung) und der
persistenten `/etc/config/rfd.conf` — jeweils in der globalen Sektion vor
der ersten `[Interface]`-Sektion. Der Uninstall entfernt nur Einträge, die
das Addon selbst gesetzt hat (erkennbar an einer Marker-Kommentarzeile).
Nach der Installation startet die CCU neu (Standardverhalten des
Addon-Installers); erst danach sind Binaries und Logging aktiv. Auf
anderen Architekturen wird nur das Web-Addon installiert und ein Hinweis
ausgegeben.

Zusätzlich ergänzt der Installer den **Menüeintrag „RFTrafficLogger" im
WebUI-Hauptmenü** (`/www/webui/js/mainmenu/admin.js`, nur Administrator-Menü):
Die Zeile wird vor dem letzten Element `menuNewDevicesPage` eingefügt und
erscheint dadurch — die rechten Einträge sind `float: right` — zwischen
„Geräte anlernen" und „Hilfe"; ein Klick öffnet die Addon-UI in einem neuen
Tab. Der Menütext ist die Menü-ID selbst, weil `translateKey()` für unbekannte
Keys auf den Key zurückfällt. Die Zeile trägt den Marker-Kommentar
`// added by rftrafficlogger addon`, über den sie beim Uninstall wieder
entfernt wird (der Rest der Datei bleibt byteweise unverändert) — und über den
eine Zeile aus einer älteren Addon-Version vor dem Patchen ersetzt wird, damit
der Eintrag nicht doppelt erscheint. Der Patch ist idempotent (er greift nur,
wenn die Menü-ID noch nicht vorhanden ist) und wird übersprungen, falls die
Ankerzeile in einer anderen Firmware fehlt — dann gibt es nur einen Hinweis
im Log. Da die Menüdefinition im read-only Rootfs liegt, wird `/` für den
Patch kurz `rw` gemountet; die Menüzeile ist unabhängig von der Architektur
und wird auch dort gesetzt, wo das Addon keine Binaries mitbringt.

**Selbstheilung nach Firmware-Updates:** Der `init`-Hook des rc.d-Scripts
läuft bei jedem Boot (via `S55InitAddons`, also **vor** dem Start von
multimacd/rfd) und vergleicht die System-Binaries/-Libraries mit den im
Addon hinterlegten Kopien. Weicht etwas ab — z. B. weil ein
Firmware-Update `/bin`, `/lib` und die Templates überschrieben hat —
werden die Dateien erneut installiert und die Traffic-Log-Parameter
wieder ergänzt; noch im selben Bootvorgang starten multimacd/rfd dann
mit den richtigen Binaries. Genauso wird der WebUI-Menüeintrag erneut
gesetzt, wenn ein Firmware-Update `/www` überschrieben hat. Stimmt alles
überein, fasst der Hook nichts an (kein Remount, keine Schreibzugriffe).

### Variante 2: manuell per SSH

```sh
CCU=root@ccu
ssh $CCU 'mkdir -p /usr/local/addons/rftrafficlogger/www'
scp www/index.html www/api.cgi $CCU:/usr/local/addons/rftrafficlogger/www/
ssh $CCU 'chmod 755 /usr/local/addons/rftrafficlogger /usr/local/addons/rftrafficlogger/www /usr/local/addons/rftrafficlogger/www/api.cgi
          ln -sfn /usr/local/addons/rftrafficlogger/www /usr/local/etc/config/addons/www/rftrafficlogger'
```

Für die Funkaufkommen-Überwachung zusätzlich:

```sh
ssh $CCU 'mkdir -p /usr/local/addons/rftrafficlogger/bin /usr/local/addons/rftrafficlogger/lib'
scp bin/rftrafficwatch.tcl $CCU:/usr/local/addons/rftrafficlogger/bin/
scp lib/rftl_alarm.tcl     $CCU:/usr/local/addons/rftrafficlogger/lib/
scp pkg/rc.d/rftrafficlogger $CCU:/usr/local/etc/config/rc.d/
ssh $CCU 'chmod 755 /usr/local/addons/rftrafficlogger/bin/rftrafficwatch.tcl \
                    /usr/local/etc/config/rc.d/rftrafficlogger
          /usr/local/etc/config/rc.d/rftrafficlogger start'
```

Aufruf: `http://<ccu>/addons/rftrafficlogger/`

## Hinweise

- Die Funkaufkommen-Überwachung braucht die Logdateien nur im laufenden
  Betrieb: ihre Zähler und die Baseline liegen in `alarm.state` auf der
  persistenten Partition und überleben einen Reboot, auch wenn `/var/log`
  dabei geleert wird. Nach einem Reboot muss sich lediglich das
  Auswertefenster neu füllen.
- `/var/log` ist tmpfs: Logs sind nach einem Reboot weg (~5–10 MB/Tag).
  Optionale Bereinigung alter Tageslogs per Cron:
  `10 0 * * * find /var/log -name "multimacd-traffic-*.log" -mtime +7 -delete`
- HmIP-Payloads sind AES-verschlüsselt und werden nur als Rohdaten angezeigt.
  Bekannte HmIP-Broadcast-/Multicastadressen (`F00001`–`F00005`, `F00081`–`F00083`,
  vgl. `ccu_create_devlist` des AskSinAnalyzer) werden aber byte-aligned im
  Payload erkannt, dort hervorgehoben und in der Spalte „An" namentlich
  aufgelöst (z. B. `F00001` → „HmIP Multicast All Devices"). Sie sind auch
  über Suche, Geräte-Filter und „Broadcasts ausblenden" nutzbar.
  Zusätzlich wird die HmIP-Funkadresse der Zentrale aus
  `/etc/config/hmip_address.conf` (`Adapter.1.Address`) ermittelt und wie die
  Multicastadressen aufgelöst; steht eine bekannte Adresse (Multicast,
  Zentrale oder ein Gerät aus der Geräteliste) an der festen Absender-
  (Byte 4–6) bzw. Empfängerposition (Byte 7–9) des HmIP-Frames, wird sie in
  der Spalte „Von" bzw. „An" namentlich angezeigt.

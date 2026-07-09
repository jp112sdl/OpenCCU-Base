# AskSinAnalyzer CCU

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
                                 ▼
                    www/api.cgi (tclsh, lighttpd)
                                 │  Offset-Tailing je Quelle, Geräteliste (ReGa)
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
    `hmip_central`; Cache `/tmp/asksinanalyzer.devlist.json` (600 s)
- **`www/index.html`** — Telegramm-Tabelle (live), Filter (Suche, Richtung,
  Protokoll, Typ, Gerät), Analyse-Tab (RSSI-Verlauf, Telegramm-Rate,
  Geräte-Statistik mit DutyCycle-Schätzung), CSV-Export.

## Installation auf der CCU

Voraussetzung: multimacd mit TrafficLogger (dieses Repo) und aktiviertem
`Traffic Log = 1` im Konfig-Template.

### Variante 1: Addon-Paket (WebUI)

```sh
./build-addon.sh        # erzeugt asksinanalyzer-<version>.tar.gz
```

Das Paket über die WebUI installieren: *Einstellungen → Systemsteuerung →
Zusatzsoftware → Datei auswählen → Installieren*. Das Addon erscheint danach
in der Zusatzsoftware-Liste (mit Uninstall und Link zur UI).
Paketinhalt: `update_script` (Installer), `rc.d/asksinanalyzer`
(WebUI-Integration: info/uninstall), `asksinanalyzer/` (Payload inkl.
Binaries/Libraries für x86_64).

Der Installer bringt **multimacd und rfd mit TrafficLogger samt der
benötigten Libraries mit** (derzeit nur x86_64, z. B. OVA-CCU) und
installiert sie nach `/bin` bzw. `/lib`; die Originale werden einmalig als
`*.pre-asksinanalyzer` gesichert und beim Uninstall wiederhergestellt.
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
ausgegeben. **Achtung:** Firmware-Updates überschreiben `/bin`, `/lib` und
die Templates — danach das Addon einfach erneut installieren.

### Variante 2: manuell per SSH

```sh
CCU=root@ccu
ssh $CCU 'mkdir -p /usr/local/addons/asksinanalyzer/www'
scp www/index.html www/api.cgi $CCU:/usr/local/addons/asksinanalyzer/www/
ssh $CCU 'chmod 755 /usr/local/addons/asksinanalyzer /usr/local/addons/asksinanalyzer/www /usr/local/addons/asksinanalyzer/www/api.cgi
          ln -sfn /usr/local/addons/asksinanalyzer/www /usr/local/etc/config/addons/www/asksinanalyzer'
```

Aufruf: `http://<ccu>/addons/asksinanalyzer/`

## Hinweise

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

// Tests der Weboberflaeche (www/index.html) gegen einen minimalen DOM-Stub.
// Aufruf: node tests/ui.js   -- braucht nur node, keine CCU.
// Geprueft werden die Teile, die rechnen: Statusspalte im Alarm-Tab und die
// DutyCycle-Spalte im Analyse-Tab.
const fs = require("fs"), vm = require("vm"), path = require("path");

const html = fs.readFileSync(path.join(__dirname, "..", "www", "index.html"), "utf8");
// Die Seite hat mehrere <script>-Bloecke (u.a. den kurzen Thema-Init im Kopf);
// geprueft wird der groesste, also die Anwendung selbst.
const script = html.split("<script>").slice(1)
  .map(x => x.split("</script>")[0])
  .reduce((a, b) => (b.length > a.length ? b : a), "");

const els = {};
function mkEl(id) {
  const el = { id, value: "", checked: false, type: "", textContent: "", innerHTML: "",
    placeholder: "", length: 0, selectedIndex: 0, dataset: {},
    style: new Proxy({}, { get: (t, k) => t[k] ?? "", set: (t, k, v) => (t[k] = v, true) }),
    classList: { _s: new Set(), toggle(c, on) { on ? this._s.add(c) : this._s.delete(c); },
                 contains(c) { return this._s.has(c); }, add(c) { this._s.add(c); } },
    addEventListener() {}, add() { el.length++; }, click() {},
    querySelectorAll: () => [], getBoundingClientRect: () => ({ left: 0, top: 0 }),
    getContext: () => new Proxy({}, { get: () => () => {} }), clientWidth: 800, height: 0, width: 0 };
  return el;
}
const $$ = id => (els[id] ||= mkEl(id));
["aEnabled", "aInternal", "aNewDev", "aKnownOnly", "aDebug"].forEach(i => ($$(i).type = "checkbox"));
const docEl = { dataset: {} };
// nur die Variablen, die themeColors liest
const cssVars = { "--fg-dim": "#5c6675", "--grid": "#e4e9ef", "--rx": "#1f8a44",
                  "--tx": "#b06a00", "--chart-muted": "#9aa4b2" };
const sandbox = {
  console, document: { getElementById: $$, createElement: () => mkEl("tmp"),
                       documentElement: docEl },
  getComputedStyle: () => ({ getPropertyValue: n => cssVars[n] || "" }),
  window: { addEventListener() {}, devicePixelRatio: 1 },
  setInterval() {}, setTimeout() {}, clearTimeout() {}, confirm: () => true,
  Blob: function () {}, URL: { createObjectURL: () => "", revokeObjectURL() {} },
  Date, Math, JSON, Number, String, Object, Array, Set, Map, isNaN, parseInt, parseFloat,
  encodeURIComponent,
  fetch: async () => ({ json: async () => ({}), text: async () => "OFFSET 0\n" })
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(script, sandbox);
const alarmUi = vm.runInContext("alarmUi", sandbox);

let fails = [];
const ok = (n, c, x) => { console.log((c ? "  ok   " : "  FAIL ") + n + (c ? "" : "  " + JSON.stringify(x))); if (!c) fails.push(n); };
const out = id => $$(id).innerHTML;
const rowFor = (id, a) => out(id).split("<tr").slice(1).map(x => "<tr" + x)
  .find(x => x.includes(">" + a + "<")) || "";

/* ---------------------------------------------- Statusspalte im Alarm-Tab */
console.log("--- Statusspalte zeigt den jetzigen Zustand ---");
const now = Math.floor(Date.now() / 1000), drei = now - 3 * 3600;
alarmUi.cfg = { enabled: 1, learn_hours: 168, ref_mode: "peak", threshold_pct: 50, window_min: 60,
  min_packets: 20, cooldown_min: 60, interval_sec: 300, alarm_var: "X", alarm_internal: 0,
  alarm_new_dev: 0, known_only: 1, ignore_addrs: "", reset_at: 0, debug: 0 };
alarmUi.st = {
  now, running: 1, fresh: 1, phase: "monitoring", learn_sec: 604800, learn_need: 604800,
  learn_started: now - 700000, baseline_at: now - 30000, last_check: now - 60,
  window_sec: 3600, recent_sec: 3600, known_only: 1, known_devices: 105, ref_mode: "peak",
  devices: [
    { addr: "F34001", base: 50, mean: 40, peak: 50, learn_count: 5000, learn_rate: 40,
      recent: 40, rate: 40, pct: -20, alarm_ts: drei },
    { addr: "AAAA01", base: 100, mean: 80, peak: 100, learn_count: 9000, learn_rate: 80,
      recent: 180, rate: 180, pct: 80, alarm_ts: null },
    { addr: "BBBB02", base: 50, mean: 40, peak: 50, learn_count: 4000, learn_rate: 40,
      recent: 90, rate: 90, pct: 80, alarm_ts: drei },
    { addr: "CCCC03", base: 60, mean: 55, peak: 60, learn_count: 6000, learn_rate: 55,
      recent: 50, rate: 50, pct: -17, alarm_ts: null }
  ],
  alarms: [{ addr: "F34001", ts: drei, reason: "anstieg", ref: "Spitze", rate: 79, expected: 50, msg: "x" }]
};
sandbox.renderAlarm();
ok("alter Alarm, jetzt -20 % = ok", /badge ok/.test(rowFor("alarmDevs", "F34001")));
ok("kein Alarm-Abzeichen mehr", !/badge warn/.test(rowFor("alarmDevs", "F34001")));
ok("Zeile nicht rot", !rowFor("alarmDevs", "F34001").includes("alarmrow"));
ok("Alarmzeitpunkt bleibt sichtbar", /class="past"[^>]*>Alarm /.test(rowFor("alarmDevs", "F34001")));
ok("ohne Historie kein Vermerk", !/class="past"/.test(rowFor("alarmDevs", "CCCC03")));
ok("jetzt ueber Schwelle = markiert", /badge warn/.test(rowFor("alarmDevs", "AAAA01")) &&
  rowFor("alarmDevs", "AAAA01").includes("alarmrow"));
ok("Hinweiszeile zaehlt aktuelle", out("alarmHint").includes("<b>2</b>"), out("alarmHint"));

/* ------------------------------------------------ DutyCycle im Analyse-Tab */
console.log("--- DutyCycle: Anteil am Budget von 36 s pro Stunde ---");
const base = 1700000000000;
const tg = (addr, i, iface, len = 12) => ({ from: addr, dir: "RX", len, rssi: -60,
  ts: base + i * 1000, cnt: i, proto: "BIDCOS", iface, payload: "", time: "00:00:00.000" });
const dcOf = a => { const m = rowFor("devStats", a).match(/>([\d.]+) %</); return m ? parseFloat(m[1]) : null; };
const sendsOf = a => { const m = rowFor("devStats", a).match(/(\d+) eigene Sendung/); return m ? parseInt(m[1]) : null; };
const totalOf = a => { const m = rowFor("devStats", a).match(/<td>(\d+)<\/td>\s*<td><div class="bar-bg"/); return m ? parseInt(m[1]) : null; };

// A: 10 Sendungen, jede von zwei Empfaengern protokolliert (20 Zeilen)
// B: dieselben 10 Sendungen, nur ein Empfaenger (10 Zeilen)
const list = [];
for (let i = 0; i < 10; i++) { list.push(tg("AAAA01", i, null)); list.push(tg("AAAA01", i, "GW01")); }
for (let i = 0; i < 10; i++) list.push(tg("BBBB02", i, null));
sandbox.renderDevStats(list, 100);
ok("A: 20 Logzeilen", totalOf("AAAA01") === 20, totalOf("AAAA01"));
ok("B: 10 Logzeilen", totalOf("BBBB02") === 10, totalOf("BBBB02"));
ok("beide 10 eigene Sendungen", sendsOf("AAAA01") === 10 && sendsOf("BBBB02") === 10);
ok("gleicher Wert trotz doppelter Zeilen", dcOf("AAAA01") === dcOf("BBBB02"),
  [dcOf("AAAA01"), dcOf("BBBB02")]);
// 10 * (12+13)*0,8 ms = 200 ms; 200/36000 = 0,56 % -> 0,6
ok("Bezug ist das 36-s-Budget", dcOf("AAAA01") === 0.6, dcOf("AAAA01"));
ok("Tooltip nennt Sekunden und Budget",
  rowFor("devStats", "AAAA01").includes("0.2 s Airtime in der letzten Stunde") &&
  rowFor("devStats", "AAAA01").includes("erlaubt sind 36 s"), rowFor("devStats", "AAAA01"));
ok("Tooltip nennt die staerkste Stunde",
  /staerkste Stunde im Zeitraum: 0\.2 s/.test(rowFor("devStats", "AAAA01")));
ok("Kopfzeile nennt Grenzwert und Entdopplung",
  out("devStats").includes("36 s") && out("devStats").includes("Grenzwert") &&
  out("devStats").includes("zaehlen nur einmal"));

// genau am Grenzwert: 100 Sendungen a 360 ms = 36 s
const atLimit = [];
for (let i = 0; i < 100; i++) atLimit.push(tg("CCCC03", i, null, 437));
sandbox.renderDevStats(atLimit, 100);
ok("36 s ergeben 100 %", dcOf("CCCC03") === 100, dcOf("CCCC03"));
ok("Grenzwert wird rot markiert", /class="pct-up"/.test(rowFor("devStats", "CCCC03")));

// die Haelfte: 50 Sendungen a 360 ms = 18 s
const half = [];
for (let i = 0; i < 50; i++) half.push(tg("DDDD04", i, null, 437));
sandbox.renderDevStats(half, 100);
ok("18 s ergeben 50 %", dcOf("DDDD04") === 50, dcOf("DDDD04"));

// nur die letzte Stunde zaehlt: 50 Sendungen jetzt, 50 vor drei Stunden
const spread = [];
for (let i = 0; i < 50; i++) spread.push(tg("EEEE05", i, null, 437));
for (let i = 0; i < 50; i++) spread.push({ ...tg("EEEE05", i, null, 437),
  ts: base - 3 * 3600000 + i * 1000, cnt: 200 + i });
spread.sort((a, b) => a.ts - b.ts);
sandbox.renderDevStats(spread, 4 * 3600);
ok("aeltere Stunde zaehlt nicht mit", dcOf("EEEE05") === 50, dcOf("EEEE05"));
ok("staerkste Stunde trotzdem ausgewiesen",
  /staerkste Stunde im Zeitraum: 18\.0 s = 50 %/.test(rowFor("devStats", "EEEE05")),
  rowFor("devStats", "EEEE05"));

/* ------------------------------------------------ Erscheinungsbild */
console.log("--- Light/Dark-Umschaltung ---");
delete docEl.dataset.theme;
ok("ohne Wahl und ohne System = dunkel", sandbox.themeIsLight() === false);
ok("dunkle Palette", sandbox.palette()[0] === "#4da3ff", sandbox.palette()[0]);
docEl.dataset.theme = "light";
ok("data-theme light erkannt", sandbox.themeIsLight() === true);
ok("helle Palette", sandbox.palette()[0] === "#1a73c7", sandbox.palette()[0]);
ok("beide Paletten gleich lang", sandbox.palette().length === 10);
docEl.dataset.theme = "dark";
ok("data-theme dark erkannt", sandbox.themeIsLight() === false);
// Canvas-Farben kommen aus dem Stylesheet, nicht aus festen Werten
const tcol = sandbox.themeColors();
ok("Canvas liest --fg-dim", tcol.dim === "#5c6675", tcol);
ok("Canvas liest --grid", tcol.grid === "#e4e9ef", tcol);
ok("Canvas liest RX/TX", tcol.rx === "#1f8a44" && tcol.tx === "#b06a00", tcol);
// Knopf zeigt, wohin der Klick fuehrt
docEl.dataset.theme = "light";
sandbox.updateThemeButton();
ok("heller Zustand -> Mondsymbol", $$("themeBtn").innerHTML === "&#9790;", $$("themeBtn").innerHTML);
ok("Titel nennt das Ziel", $$("themeBtn").title.includes("dunkles"), $$("themeBtn").title);
docEl.dataset.theme = "dark";
sandbox.updateThemeButton();
ok("dunkler Zustand -> Sonnensymbol", $$("themeBtn").innerHTML === "&#9728;");
ok("Titel nennt das Ziel", $$("themeBtn").title.includes("helles"));

console.log("");
if (fails.length) { console.log(`=== ${fails.length} FEHLER ===`); process.exitCode = 1; }
else console.log("=== alle Tests bestanden ===");

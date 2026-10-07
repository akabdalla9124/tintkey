/* ------------------------------------------------------------
   TWO THINGS TO CHANGE AFTER PUBLISHING
   1. DOWNLOAD_URL: replace akabdalla9124 with the GitHub account that
      hosts the release. index.html holds the same URL as the
      no-JS fallback href; keep both in sync.
   2. BRAND: the product name (placeholder).
------------------------------------------------------------ */
const DOWNLOAD_URL = "https://github.com/akabdalla9124/tintkey/releases/latest/download/Tintkey.dmg";
const BRAND = "Tintkey";

document.querySelectorAll("[data-brand]").forEach(el => { el.textContent = BRAND; });
document.title = `${BRAND} | Per-app keyboard lighting for macOS`;
document.querySelectorAll("[data-dmg]").forEach(a => { a.setAttribute("href", DOWNLOAD_URL); });
if (DOWNLOAD_URL.includes("akabdalla9124")) console.warn("Tintkey site: DOWNLOAD_URL still contains the akabdalla9124 placeholder.");

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

/* ---------- keyboard layout: 75% ANSI, 15 units wide ---------- */
const L = (label, u = 1, role = "alpha", id = label.toLowerCase()) => ({ label, u, role, id });
const letters = s => [...s].map(c => L(c));
const ROWS = [
  [L("Esc", 1, "mod", "esc"), ...[1,2,3,4,5,6,7,8,9,10,11,12].map(n => L("F" + n, 1, "fn", "f" + n)), L("Del", 1, "mod", "del")],
  [L("`"), ...[..."1234567890"].map(c => L(c, 1, "num")), L("-", 1, "num"), L("=", 1, "num"), L("Bksp", 2, "mod", "bksp")],
  [L("Tab", 1.5, "mod", "tab"), ...letters("qwertyuiop"), L("["), L("]"), L("\\", 1.5)],
  [L("Caps", 1.75, "mod", "caps"), ...letters("asdfghjkl"), L(";"), L("'"), L("Enter", 2.25, "mod", "enter")],
  [L("Shift", 2.25, "mod", "lshift"), ...letters("zxcvbnm"), L(","), L("."), L("/"), L("Shift", 1.75, "mod", "rshift"), L("↑", 1, "arrow", "up")],
  [L("Ctrl", 1.25, "mod", "ctrl"), L("Opt", 1.25, "mod", "opt"), L("Cmd", 1.25, "mod", "lcmd"), L("", 6.25, "space", "space"),
   L("Cmd", 1, "mod", "rcmd"), L("Fn", 1, "mod", "fn"), L("←", 1, "arrow", "left"), L("↓", 1, "arrow", "down"), L("→", 1, "arrow", "right")]
];

/* ---------- app profiles ----------
   Stock VIA sets ONE color for the whole board, so each app has a single color.
   hue is on the keyboard's 0-255 scale, matching the app's defaults (Zoom 0, Xcode 170, OBS 85, Figma 190, Terminal 25).
   alert: color used while an alert plays. */
const APPS = [
  { id: "finder",   name: "Finder",     rule: "No rule",         base: null,      hex: "#e8e6df", alert: "#ff2b3a", alertName: "Red" },
  { id: "zoom",     name: "Zoom",       rule: "Meeting red",     base: "#ff2b3a", alert: "#ffffff", alertName: "White" },
  { id: "xcode",    name: "Xcode",      rule: "Build blue",      base: "#2f7bff", alert: "#ffc247", alertName: "Amber" },
  { id: "obs",      name: "OBS Studio", rule: "Stream green",    base: "#18d66b", alert: "#ff2b3a", alertName: "Red" },
  { id: "figma",    name: "Figma",      rule: "Canvas violet",   base: "#a35cff", alert: "#18d6a5", alertName: "Teal" },
  { id: "terminal", name: "Terminal",   rule: "Phosphor amber",  base: "#ffb000", alert: "#ff5a2b", alertName: "Orange" }
];
const colorOf = app => app.base || app.hex;

const $ = s => document.querySelector(s);
const board = $("#board");
const keyEls = [];
const live = $("#live");
const say = msg => { live.textContent = ""; setTimeout(() => { live.textContent = msg; }, 30); };

/* readable legend color on a lit key */
function inkOn(hex) {
  const n = parseInt(hex.slice(1), 16), c = [n >> 16, (n >> 8) & 255, n & 255]
    .map(v => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; });
  const l = .2126 * c[0] + .7152 * c[1] + .0722 * c[2];
  return l > .179 ? "#000000" : "#ffffff";
}

/* ---------- build keyboard (decorative, so plain elements, not buttons) ---------- */
(function build() {
  const frag = document.createDocumentFragment();
  ROWS.forEach((row, r) => {
    const rowEl = document.createElement("div");
    rowEl.className = "row";
    let x = 0;
    row.forEach(k => {
      const el = document.createElement("span");
      el.className = "key";
      el.style.gridColumn = `span ${Math.round(k.u * 4)}`;
      el.textContent = k.label;
      el._k = { ...k, x: (x + k.u / 2) / 15, r };
      x += k.u;
      rowEl.appendChild(el);
      keyEls.push(el);
    });
    frag.appendChild(rowEl);
  });
  board.appendChild(frag);
})();

/* key height = one unit wide; set from board width */
function sizeKeys() {
  const cs = getComputedStyle(board);
  const gap = parseFloat(cs.columnGap) || 4;
  const inner = board.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
  const colw = (inner - 59 * gap) / 60;
  const kh = colw * 4 + 3 * gap;
  board.style.setProperty("--kh", kh.toFixed(2) + "px");
  board.classList.toggle("tiny", kh < 30);
}
new ResizeObserver(sizeKeys).observe(board);
sizeKeys();

/* ---------- state ---------- */
let current = APPS[0];
let alertStyle = "flash";
let alertTimers = [];
let breatheAnim = null;

function paint(hex, { sweep = true } = {}) {
  const animate = sweep && !reduceMotion.matches;
  keyEls.forEach(el => {
    const k = el._k;
    el.style.setProperty("--d", animate ? Math.round(k.x * 420 + k.r * 28) + "ms" : "0ms");
    el.style.setProperty("--k", hex);
    el.style.setProperty("--kink", inkOn(hex));
  });
  board.style.setProperty("--glow", hex);
}

function apply(app, { sweep = true } = {}) {
  current = app;
  const hex = colorOf(app);
  paint(hex, { sweep });
  $(".console").style.setProperty("--app", hex);
  $("#mb-app").textContent = app.name;
  $("#r-app").textContent = app.name;
  $("#r-profile").textContent = app.rule;
  $("#r-hex").textContent = app.base ? app.base.toUpperCase() : "Keyboard's own";
  document.querySelectorAll("#picker [role=radio]").forEach(b => {
    const on = b.dataset.id === app.id;
    b.setAttribute("aria-checked", on);
    b.tabIndex = on ? 0 : -1;
  });
}

/* ---------- radiogroup helper: roving tabindex + arrow keys ---------- */
function radioGroup(group, onSelect) {
  const items = () => [...group.querySelectorAll("[role=radio]")];
  group.addEventListener("click", e => {
    const b = e.target.closest("[role=radio]");
    if (b) onSelect(b);
  });
  group.addEventListener("keydown", e => {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
    const list = items();
    let i = list.findIndex(b => b.getAttribute("aria-checked") === "true");
    if (step) i = (i + step + list.length) % list.length;
    else if (e.key === "Home") i = 0;
    else if (e.key === "End") i = list.length - 1;
    else return;
    e.preventDefault();
    onSelect(list[i]);
    list[i].focus();
  });
}
function setChecked(group, btn) {
  group.querySelectorAll("[role=radio]").forEach(b => {
    b.setAttribute("aria-checked", b === btn);
    b.tabIndex = b === btn ? 0 : -1;
  });
}

/* ---------- picker ---------- */
const picker = $("#picker");
APPS.forEach(app => {
  const b = document.createElement("button");
  b.type = "button";
  b.setAttribute("role", "radio");
  b.dataset.id = app.id;
  b.style.setProperty("--c", colorOf(app));
  b.innerHTML = `<i aria-hidden="true"></i><span></span>`;
  b.lastChild.textContent = app.name;
  picker.appendChild(b);
});
radioGroup(picker, b => {
  const app = APPS.find(a => a.id === b.dataset.id);
  clearAlert();
  apply(app);
  say(`${app.name} is in front. ${app.base ? "Keyboard color " + app.base.toUpperCase() : "No rule, so the keyboard keeps its own color"}.`);
});

/* ---------- connection + style toggles ---------- */
const conn = $("#conn"), styleGroup = $("#style");
conn.querySelectorAll("[role=radio]").forEach((b, i) => { b.tabIndex = i ? -1 : 0; });
styleGroup.querySelectorAll("[role=radio]").forEach((b, i) => { b.tabIndex = i ? -1 : 0; });
radioGroup(conn, b => {
  setChecked(conn, b);
  $("#mb-conn").textContent = b.dataset.conn === "USB" ? "USB" : "2.4G";
  say(`Connection: ${b.textContent}.`);
});
radioGroup(styleGroup, b => {
  setChecked(styleGroup, b);
  alertStyle = b.dataset.style;
  $("#r-alert").textContent = alertStyle === "flash" ? "Flashing" : "Breathing";
  say(`Alert style: ${b.textContent}.`);
});

/* ---------- notification alert (whole board, like the real app) ---------- */
function setState(text, on) {
  $("#mb-state").textContent = text;
  $("#mb-status").classList.toggle("alerting", on);
}
function clearAlert() {
  alertTimers.forEach(clearTimeout);
  alertTimers = [];
  if (breatheAnim) { breatheAnim.cancel(); breatheAnim = null; }
  keyEls.forEach(el => el.classList.remove("alert"));
  board.classList.remove("alerting");
  setState("Ready", false);
  paint(colorOf(current), { sweep: false });
}
function ping() {
  clearAlert();
  const col = current.alert;
  const normal = colorOf(current);
  const name = alertStyle === "flash" ? "Flashing" : "Breathing";
  setState(`Alert: ${name.toLowerCase()}`, true);
  say(`Test alert. Keyboard ${name.toLowerCase()} in ${current.alertName.toLowerCase()}.`);
  const after = ms => alertTimers.push(setTimeout(clearAlert, ms));
  const at = (ms, fn) => alertTimers.push(setTimeout(fn, ms));
  paint(col, { sweep: false });
  board.classList.add("alerting");
  if (reduceMotion.matches) {          // one static hold, no motion
    keyEls.forEach(el => el.classList.add("alert"));
    after(1600);
    return;
  }
  if (alertStyle === "flash") {
    keyEls.forEach(el => el.classList.add("alert"));
    for (let p = 0; p < 3; p++) {
      at(p * 560 + 280, () => { keyEls.forEach(el => el.classList.remove("alert")); paint(normal, { sweep: false }); });
      if (p < 2) at(p * 560 + 560, () => { keyEls.forEach(el => el.classList.add("alert")); paint(col, { sweep: false }); });
    }
    after(3 * 560);
  } else {
    keyEls.forEach(el => el.classList.add("alert"));
    breatheAnim = board.animate([{ filter: "brightness(1)" }, { filter: "brightness(.25)" }, { filter: "brightness(1)" }],
      { duration: 1100, iterations: 3, easing: "ease-in-out" });
    after(3300);
  }
}
$("#ping").addEventListener("click", ping);

/* ---------- press keys with the real keyboard / pointer ---------- */
const byId = new Map();
keyEls.forEach(el => { const id = el._k.id; if (!byId.has(id)) byId.set(id, el); });
const CODES = {
  Space: "space", Escape: "esc", Backspace: "bksp", Delete: "del", Tab: "tab", CapsLock: "caps", Enter: "enter",
  ShiftLeft: "lshift", ShiftRight: "rshift", ControlLeft: "ctrl", ControlRight: "ctrl", AltLeft: "opt", AltRight: "opt",
  MetaLeft: "lcmd", MetaRight: "rcmd", ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right",
  Backquote: "`", Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Backslash: "\\", Semicolon: ";",
  Quote: "'", Comma: ",", Period: ".", Slash: "/"
};
function idFor(e) {
  if (CODES[e.code]) return CODES[e.code];
  if (/^Key[A-Z]$/.test(e.code)) return e.code.slice(3).toLowerCase();
  if (/^Digit\d$/.test(e.code)) return e.code.slice(5);
  if (/^F\d{1,2}$/.test(e.code)) return e.code.toLowerCase();
  return null;
}
function pressEl(el, on) { if (el) el.classList.toggle("down", on); }
const releaseAll = () => keyEls.forEach(el => el.classList.remove("down"));
window.addEventListener("keydown", e => {
  if (e.key === "Meta") releaseAll();
  pressEl(byId.get(idFor(e)), true);
});
window.addEventListener("keyup", e => pressEl(byId.get(idFor(e)), false));
window.addEventListener("blur", releaseAll);
keyEls.forEach(el => {
  el.addEventListener("pointerdown", () => el.classList.add("down"));
  ["pointerup", "pointerleave", "pointercancel"].forEach(ev => el.addEventListener(ev, () => el.classList.remove("down")));
});

/* ---------- boot: one sweep from dark to the first app ---------- */
keyEls.forEach(el => { el.style.setProperty("--k", "#2a2a2a"); el.style.setProperty("--kink", "#ffffff"); });
requestAnimationFrame(() => requestAnimationFrame(() => apply(APPS[0])));

/* auto-demo: cycle apps once when the board first scrolls into view; stops on any interaction */
let touched = false;
const stop = () => { touched = true; };
$(".console").addEventListener("pointerdown", stop);
$(".console").addEventListener("keydown", stop);
if (!reduceMotion.matches && "IntersectionObserver" in window) {
  const io = new IntersectionObserver(entries => {
    if (!entries[0].isIntersecting) return;
    io.disconnect();
    let i = 0;
    const seq = [APPS[1], APPS[2], APPS[3]];
    const step = () => {
      if (touched || i >= seq.length) return;
      apply(seq[i++]);
      setTimeout(step, 1500);
    };
    setTimeout(step, 900);
  }, { threshold: .6 });
  io.observe(board);
}

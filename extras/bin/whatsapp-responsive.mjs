#!/usr/bin/env node
// WhatsApp Desktop — responsive layout patch.
//
// WHY THIS EXISTS
// WhatsApp Web lays its UI out in CSS pixels and hard-codes `min-width: 748px`
// on the div.two layout root. The desktop app is an Electron wrapper around
// that page, and this machine runs it at --force-device-scale-factor=1.5 (see
// ~/.local/bin/whatsapp-desktop), so a window tiled to ~560 physical px is only
// ~375 CSS px wide. WhatsApp then keeps the contact list at its 45% share and
// lets the conversation pane overflow off the right edge: the chat and its
// message box are literally outside the window, while the list stays visible.
// There is no window-manager rule that can fix that -- the page decides.
//
// So this helper talks to the app's own DevTools endpoint (the wrapper passes
// --remote-debugging-port=9339, loopback only) and injects two small pieces
// into the page:
//
//   1. a <style> that, below 720 CSS px, lets div.two shrink and hides every
//      pane except the one holding #main -- so the conversation (and its
//      composer) keep the whole window instead of being cropped;
//   2. a 13x58 px tab on the left edge that switches to WhatsApp's own
//      two-pane layout for picking a chat (class `wa-pick` on <html>), and
//      returns to the conversation as soon as a chat row is clicked, the tab is
//      pressed again, Escape is hit, or anything outside the list is clicked.
//
// Above the breakpoint nothing is overridden: the app behaves exactly as it
// does without this helper, rail and both panes included.
//
// WhatsApp re-renders and reloads on its own, which drops injected nodes, so
// the helper re-asserts them whenever they go missing and after every page
// load. It exits when the app is gone.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const APP_URL = "https://web.whatsapp.com";
const IDLE_EXIT_MS = Number(process.env.WHATSAPP_RESPONSIVE_IDLE_MS || 90000);
const USER_DATA = process.env.WHATSAPP_USER_DATA || path.join(os.homedir(), ".config/WhatsApp Desktop");
const LOCK = path.join(os.tmpdir(), "whatsapp-responsive.lock");

// The wrapper starts Chromium with --remote-debugging-port=0 (an ephemeral
// port) and Chromium records it in DevToolsActivePort inside the profile
// directory. Reading the file is what makes a restart safe: a fixed port can
// still be held by the previous instance's socket for a few seconds, which
// makes the new process give up with "bind() failed: Address already in use"
// and leaves nothing to attach to.
function debugPort() {
  if (process.env.WHATSAPP_DEBUG_PORT) return Number(process.env.WHATSAPP_DEBUG_PORT);
  try {
    const first = fs.readFileSync(path.join(USER_DATA, "DevToolsActivePort"), "utf8").split("\n")[0].trim();
    const port = Number(first);
    return Number.isInteger(port) && port > 0 ? port : null;
  } catch {
    return null;
  }
}

function alreadyRunning() {
  try {
    const pid = Number(fs.readFileSync(LOCK, "utf8").trim());
    if (pid && pid !== process.pid) {
      process.kill(pid, 0);
      return true;
    }
  } catch {}
  return false;
}

if (alreadyRunning()) {
  console.error("[whatsapp-responsive] another instance is already attached, exiting");
  process.exit(0);
}
fs.writeFileSync(LOCK, String(process.pid));
const dropLock = () => {
  try {
    if (Number(fs.readFileSync(LOCK, "utf8").trim()) === process.pid) fs.unlinkSync(LOCK);
  } catch {}
};
process.on("exit", dropLock);
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, () => { dropLock(); process.exit(0); });

const CSS = `
@media (max-width: 720px) {
  html:not(.wa-pick) div.two { min-width: 0 !important; }
  html:not(.wa-pick) div.two > [data-testid="chatlist-header"],
  html:not(.wa-pick) div.two > [data-testid="drawer-fullscreen"] { display: none !important; }
  html:not(.wa-pick) div.two > div:has(#side),
  html:not(.wa-pick) div.two > div:has(#pane-side) { display: none !important; }
  html:not(.wa-pick) div.two:has(#main) > div { display: none !important; }
  html:not(.wa-pick) div.two:has(#main) > div:has(#main) {
    display: block !important; flex: 1 1 auto !important; width: 100% !important;
    min-width: 0 !important; max-width: none !important; }
  html:not(.wa-pick) #main { flex: 1 1 auto !important; width: 100% !important;
    min-width: 0 !important; max-width: none !important; }
}
#wa-pane-toggle { display: none; }
@media (max-width: 720px) {
  #wa-pane-toggle { display: flex; position: fixed; left: 0; top: 50%; transform: translateY(-50%);
    width: 13px; height: 58px; align-items: center; justify-content: center; z-index: 9500;
    cursor: pointer; border: none; border-radius: 0 7px 7px 0; padding: 0;
    background: rgba(32,44,51,.9); color: #e9edef; font-size: 11px; line-height: 1;
    box-shadow: 1px 0 4px rgba(0,0,0,.35); opacity: .5; transition: opacity .15s; }
  #wa-pane-toggle:hover { opacity: 1; background: rgba(55,75,86,.95); }
}
`;

// Runs inside the page. Idempotent: safe to call on every tick.
const INSTALL = `(() => {
  const root = document.documentElement;
  if (!root) return 'no-root';
  let style = document.getElementById('wa-responsive');
  if (!style) {
    style = document.createElement('style');
    style.id = 'wa-responsive';
  }
  style.textContent = ${JSON.stringify(CSS)};
  if (!style.isConnected) (document.head || root).appendChild(style);

  let tab = document.getElementById('wa-pane-toggle');
  if (!tab) {
    tab = document.createElement('button');
    tab.id = 'wa-pane-toggle';
    tab.title = 'Chats';
    tab.textContent = '\\u276F';
    document.body.appendChild(tab);
  }
  if (!window.__waResponsive) {
    window.__waResponsive = true;
    const close = () => root.classList.remove('wa-pick');
    tab.addEventListener('click', (ev) => {
      ev.preventDefault(); ev.stopPropagation();
      root.classList.toggle('wa-pick');
    });
    document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') close(); }, true);
    document.addEventListener('click', (ev) => {
      if (!root.classList.contains('wa-pick')) return;
      const t = ev.target;
      if (t.closest('#pane-side') || t.closest('[role="listitem"]')) setTimeout(close, 150);
      else if (!t.closest('#wa-pane-toggle') && !t.closest('[data-testid="chatlist-header"]')) close();
    }, true);
  }
  return 'ok';
})()`;

const log = (...a) => console.error(`[whatsapp-responsive]`, ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function findTarget(port) {
  if (!port) return null;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(1500) });
    const list = await res.json();
    return list.find((t) => t.type === "page" && String(t.url || "").startsWith(APP_URL)) || null;
  } catch {
    return null;
  }
}

class Session {
  constructor(url) {
    this.url = url;
    this.ws = null;
    this.id = 0;
    this.pending = new Map();
    this.open = false;
    this.lastInject = 0;
  }

  connect() {
    return new Promise((resolve) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;
      const timer = setTimeout(() => resolve(false), 4000);
      ws.onopen = () => {
        clearTimeout(timer);
        this.open = true;
        resolve(true);
      };
      ws.onerror = () => {
        clearTimeout(timer);
        this.open = false;
        resolve(false);
      };
      ws.onclose = () => {
        this.open = false;
      };
      ws.onmessage = (ev) => {
        let msg;
        try {
          msg = JSON.parse(ev.data);
        } catch {
          return;
        }
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve: done } = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          done(msg.result);
        } else if (msg.method === "Page.loadEventFired") {
          this.inject().catch(() => {});
        }
      };
    });
  }

  send(method, params = {}) {
    if (!this.open) return Promise.resolve(null);
    const id = ++this.id;
    return new Promise((resolve) => {
      this.pending.set(id, { resolve });
      try {
        this.ws.send(JSON.stringify({ id, method, params }));
      } catch {
        this.pending.delete(id);
        resolve(null);
      }
      setTimeout(() => {
        if (this.pending.delete(id)) resolve(null);
      }, 4000);
    });
  }

  async inject() {
    this.lastInject = Date.now();
    return this.send("Runtime.evaluate", { expression: INSTALL, returnByValue: true });
  }

  close() {
    try {
      this.ws?.close();
    } catch {}
    this.open = false;
  }
}

let session = null;
let lastSeen = Date.now();
let wasMissing = false;

while (true) {
  const target = await findTarget(debugPort());
  if (!target) {
    if (session) {
      session.close();
      session = null;
      log("app gone, waiting");
    }
    if (Date.now() - lastSeen > IDLE_EXIT_MS) {
      log("no app for too long, exiting");
      process.exit(0);
    }
    if (!wasMissing) {
      wasMissing = true;
      lastSeen = Date.now();
    }
    await sleep(2000);
    continue;
  }

  wasMissing = false;
  lastSeen = Date.now();

  if (!session || session.url !== target.webSocketDebuggerUrl) {
    session?.close();
    session = new Session(target.webSocketDebuggerUrl);
    if (await session.connect()) {
      log("attached to", target.title || target.url);
      await session.send("Page.enable");
    } else {
      log("attach failed, retrying");
      session = null;
      await sleep(2000);
      continue;
    }
  }

  // Re-assert continuously: a reload or a React re-render can drop both nodes.
  if (Date.now() - session.lastInject > 3000) {
    await session.inject();
  }
  await sleep(1000);
}

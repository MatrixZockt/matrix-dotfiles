pragma Singleton

import QtQuick
import Quickshell
// IpcHandler lives in Quickshell.Io -- without this import the type does not
// resolve and the whole type graph fails to load (TrayApps -> every service).
import Quickshell.Io
import Quickshell.Hyprland
// IpcHandler (the tray card's status/toggle hook below) lives here. Without
// this import the type does not resolve, and this build reports that as a
// cascade of unrelated "Type unavailable" errors that starts at shell.qml
// and takes the WHOLE configuration down -- the shell then never starts.
import Quickshell.Io
import qs.modules.common
import qs.services

// ── Shell-provided tray icons for apps with no StatusNotifier of their own ──
// Registry entries draw a tray icon the app cannot make itself, and the shell
// owns the whole lifecycle: the icon exists while the app has a window (see
// `liveRegistry`), clicking it shows/parks/starts the app, and the compositor's
// close gesture parks the window instead of killing it when the class is
// enabled in config.json's tray.closeToTray (custom/general.lua's smartClose
// reads that same file, so the switch in settings and the keybind agree).
//
// Entry fields:
//   cls       – Hyprland window class (matches StartupWMClass / WM_CLASS).
//   name      – Human label shown in the tray tooltip and settings.
//   iconName  – Themed icon name (resolved via Quickshell.iconPath). Use the
//               Icon= value from the app's .desktop file when available.
//   launch    – Command to start the app when the icon is clicked while it is
//               not running. Optional: omit for apps that are always running.
Singleton {
    id: root

    readonly property var registry: [
        // `bins` is what allowLaunch() matches a launch command against: every
        // name this app can legitimately be started by. It is NOT redundant
        // with `launch` -- the desktop entry the Super menu uses runs the GPU
        // wrapper (~/.local/bin/whatsapp-desktop), not the binary in `launch`,
        // and basename equality on `launch` alone therefore matched nothing:
        // the launcher's permission was never granted, so the watcher parked
        // the freshly opened window the instant it appeared ("WhatsApp opens
        // and disappears into the tray").
        { cls: "WhatsApp Desktop", name: "WhatsApp", iconName: "whatsapp-linux-desktop",
          launch: "/opt/whatsapp-linux-desktop/bin/whatsapp-linux-desktop",
          bins: ["whatsapp-linux-desktop", "whatsapp-desktop"] },
        // Thunderbird. The class is the Wayland one hyprctl clients reports
        // (org.mozilla.Thunderbird) -- NOT the desktop file's X11 StartupWMClass
        // (thunderbird): windowsOf() matches w.class EXACTLY, and the live
        // window is the authority. The same spelling is the closeToTray key in
        // config.json; the launcher's already-open redirect matches this class
        // through apps.singleInstance's "thunderbird" by segment (isSingleInstance).
        { cls: "org.mozilla.Thunderbird", name: "Thunderbird", iconName: "org.mozilla.Thunderbird",
          launch: "/usr/bin/thunderbird",
          bins: ["thunderbird"] }
    ]

    // ── Window state ────────────────────────────────────────────────────────
    // Everything answers from HyprlandData.windowList, the `hyprctl clients -j`
    // re-read: recomputed, never stored, so the icon is right after the close
    // gesture parks the window, after the shell restarts, and after a restore
    // -- none of which go through this file. Parked windows ARE in that list
    // (hyprctl reports them with workspace.name "special:tray"), which is what
    // makes a parked app count as running and keep its icon.

    function windowsOf(cls) {
        if (!cls)
            return [];
        return (HyprlandData.windowList ?? []).filter(w => w.class === cls);
    }

    // Any window of the class exists, parked or visible.
    // For the shell's registry-backed tray apps (WhatsApp, Thunderbird) this
    // is the only visibility check: the tray icon exists while the app has a
    // window, and disappears when the window is gone.
    function isRunning(cls) {
        return root.windowsOf(cls).length > 0;
    }

    // Whether the process for a registry app is alive at all, even with no
    // window mapped. Used by the single-instance guard in launch(): if the
    // process is alive but has no window (Electron apps can outlive their
    // window), a second launch is still wrong -- bring the existing process
    // back instead.
    function processAlive(cls) {
        if (!cls)
            return false;
        const entry = root.registry.find(e => e.cls === cls);
        if (!entry || !entry.launch)
            return false;
        // The launch command's head is the binary; check whether any process
        // matching that binary is alive. pgrep is cheap and avoids reading
        // /proc ourselves (which can 404 under the compositor).
        try {
            const head = entry.launch.split(/\s+/)[0];
            const base = head.split("/").pop();
            if (!base || base.length === 0)
                return false;
            const p = Quickshell.exec("pgrep", "-f", base);
            return String(p).trim().length > 0;
        } catch (e) {
            return false;
        }
    }

    // Every window of the class is in the tray vault. Deliberately ALL, not
    // ANY: an app with one window parked and one on screen is on screen, and
    // Notifications relies on that ("Deliberately not done for a VISIBLE tray
    // app"). No windows -> false: there is nothing to restore.
    function isHidden(cls) {
        const wins = root.windowsOf(cls);
        if (wins.length === 0)
            return false;
        return wins.every(w => w.workspace && w.workspace.name === "special:tray");
    }

    // Registry entries whose app currently has a window -- the tray's
    // shell-owned model. NOT `registry`: an app that is not running has no
    // tray icon, exactly as it would be if it registered one itself; a
    // permanently-present icon would be a launcher wearing a tray icon's
    // clothes. SysTray filters this MODEL (rather than hiding delegates)
    // because its grid is placed by hand from the cells that exist, and a
    // hidden-but-present delegate would leave a gap shaped like the icon.
    // Reacts to windowList, so park/restore/close all show up without a call.
    readonly property list<var> liveRegistry: registry.filter(e => root.isRunning(e.cls) && root.isHidden(e.cls))

    // ── In-flight operations ────────────────────────────────────────────────
    // Cold start or a restore in flight FOR THIS APP: the icon dims and a ring
    // turns over it (SysTrayAppItem.busy). A map, not a bool: two apps can be
    // launching at once, and quitting one must not stop the other's ring.
    // Values: { kind: "launch"|"show", until: epoch ms }.
    property var busyMap: ({})
    // Bumped by the Timer below so a binding that read busyFor() re-evaluates
    // when an operation TIMES OUT with no window event to wake it (a launch
    // that failed has no window-list change to clear the ring otherwise).
    property int busyTick: 0

    function markBusy(cls, kind, ms) {
        const m = Object.assign({}, root.busyMap);
        m[cls] = { kind: kind, until: Date.now() + ms };
        root.busyMap = m;
    }

    function busyFor(cls) {
        if (!cls)
            return false;
        const entry = root.busyMap[cls];
        if (!entry)
            return false;
        const tick = root.busyTick; // dependency: Timer keeps the check live
        if (Date.now() > entry.until)
            return false;
        if (entry.kind === "launch")
            return !(root.isRunning(cls) && !root.isHidden(cls));
        // "show": busy until the window actually leaves the vault.
        return root.isHidden(cls);
    }

    // Ticks while any operation is pending: bumps busyTick (timeout re-check)
    // and prunes expired entries so the map cannot grow without bound and the
    // timer stops when nothing is in flight.
    Timer {
        interval: 400
        repeat: true
        running: Object.keys(root.busyMap).length > 0
        onTriggered: {
            const now = Date.now();
            const m = {};
            let pruned = false;
            for (const k in root.busyMap) {
                if (root.busyMap[k].until > now)
                    m[k] = root.busyMap[k];
                else
                    pruned = true;
            }
            if (pruned)
                root.busyMap = m;
            root.busyTick++;
        }
    }

    // ── The actions ─────────────────────────────────────────────────────────
    // Park every visible window of the class into the tray vault. follow=false:
    // parking must not drag focus along to the vault. The move form (string
    // workspace + explicit window selector) is verified working on this
    // compositor build; it is the same dispatch the close gesture uses.

    function park(cls, reason) {
        // One move per class at a time. This compositor EATS a window that
        // is moved again before its previous move lands (its own comment in
        // HyprlandData: "window.move, which this fork's compositor drops --
        // and onto a nonexistent workspace it even eats the window"), and a
        // single event burst used to produce SEVEN park dispatches in 25ms,
        // after which the window was briefly gone from the client list
        // entirely. The move that was already sent will either land (and
        // this call has nothing to do) or fail (and the 1s net retries).
        if (reason === "watcher:stray" && Date.now() - (root.lastParkAt[cls] || 0) < 500)
            return;
        if (reason)
            console.log(`[TrayApps] ${new Date().toISOString().slice(11, 23)} park(${cls}) reason=${reason} intent=${root.trayIntent[cls] === true}`);
        const wins = root.windowsOf(cls)
            .filter(w => !w.workspace || w.workspace.name !== "special:tray");
        for (const w of wins) {
            // A window must not enter the vault FULLSCREEN. The close gesture
            // parks a fullscreen tray app as it is (it keeps it fullscreen on
            // purpose, so the drag does not flash), and a fullscreen window
            // inside `special:tray` is a fullscreen window the moment the
            // vault is shown -- a borderless app covering everything that
            // closing cannot get rid of, because closing only parks it again.
            // One toggle, then the move: this shell's dispatches are applied
            // in order, and `show()` un-fullscreens on the way out as well.
            if (w.fullscreen && w.fullscreen !== 0) {
                Hyprland.dispatch(`hl.dsp.focus({ window = hl.get_window("address:${w.address}") })`);
                Hyprland.dispatch(`hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })`);
            }
            Hyprland.dispatch(`hl.dsp.window.move({ workspace = "special:tray", follow = false, window = "address:${w.address}" })`);
        }
        // Parking is what WITHWRITES the permission to be on screen, so it
        // clears it here rather than at each caller -- including the watcher
        // below, which parks apps that raised themselves.
        root.setIntent(cls, false, "park");
        const stamps = Object.assign({}, root.lastParkAt);
        stamps[cls] = Date.now();
        root.lastParkAt = stamps;
    }

    // Restore: move parked windows of the class to the active workspace and
    // focus them (follow=true does both -- verified). If the user is looking
    // AT the vault (active id < 0) restore to the first regular workspace
    // instead: moving onto a negative id would just put it back.
    function show(cls) {
        const parked = root.windowsOf(cls)
            .filter(w => w.workspace && w.workspace.name === "special:tray");
        if (parked.length === 0)
            return; // nothing in the vault; do not light up the ring
        // Opening it IS the user's click: this is one of the two ways an app
        // is allowed out of the tray (the other is a launch, below).
        root.setIntent(cls, true, "show");
        root.markBusy(cls, "show", 6000);
        const act = HyprlandData.activeWorkspace;
        const target = (act && act.id > 0) ? act.id : 1;
        for (const w of parked) {
            Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${target}, follow = true, window = "address:${w.address}" })`);
            // ── Attach on the way out ──────────────────────────────────────
            // The vault must never ship a floating window back to the desktop:
            // one did (the swipe-down close parked WhatsApp while the drag's
            // own float was still set), and every later tray-icon open then
            // restored that popup instead of an attached tile. This is the
            // same attach the SUPER menu's focusRunningApp performs for an
            // already-open floating window, and it leans on the same measured
            // facts: the float dispatcher here is FOCUS-SCOPED (an address
            // form moved the wrong window -- see focusRunningApp), the move
            // above just focused this window via follow=true, so the unset
            // that follows in the same dispatch queue lands on THIS window.
            // Tiny windows are left alone: at that size it is a dialog or a
            // notification, and those float because they are supposed to
            // (same rule and same numbers as focusRunningApp).
            const sw = w.size?.width ?? 0;
            const sh = w.size?.height ?? 0;
            const tiny = sw > 0 && sh > 0 && (sw < 300 || sh < 200);
            if (w.floating === true && !tiny)
                Hyprland.dispatch(`hl.dsp.window.float({ action = "unset" })`);
            // ── And attach the FULLSCREEN the same way ─────────────────────
            // A park that happened while the app was fullscreen left a
            // fullscreen window in the vault, and this loop used to move it
            // back onto the desktop exactly as it was: an app covering the
            // whole screen, no titlebar, and closing it just parks it again --
            // the "opens as a front view I cannot remove at all" report. A
            // window coming out of the tray comes out AS A WINDOW, so the
            // fullscreen state does not survive the round trip. (The move
            // above focused it via follow=true, and the fullscreen dispatcher
            // is focus-scoped like the float one, so this lands on it.)
            if (w.fullscreen && w.fullscreen !== 0)
                Hyprland.dispatch(`hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })`);
        }
    }

    // The icon's left click: show it if parked, park it if visible, start it
    // if not running. The shell decides -- there is no app behind this icon
    // to ask (SysTrayAppItem's note: not item.activate()).
    //
    // NEW-INSTANCE GUARD (single-instance): must NOT re-launch a fresh binary
    // when WhatsApp is already alive. A second whatsapp-linux-desktop binary
    // is a new browser context and loses the login session. This is the path
    // SysTrayAppItem takes for a shell-owned (non-SNI) tray icon click, so it
    // is the one that has to refuse re-launch -- even for the parked-but-not-
    // hidden state, which the earlier isRunning/isHidden pair missed.
    function toggle(cls) {
        if (!cls)
            return;
        if (!root.isRunning(cls)) {
            root.launch(cls);
            return;
        }
        if (root.isHidden(cls)) {
            root.show(cls);
            return;
        }
        // Running AND visible. Do exactly what the SUPER menu does for an
        // already-open single-instance app (GlobalStates.focusRunningApp):
        // switch to its workspace if needed, focus it, and ATTACH it if it is
        // floating -- the launcher deliberately untiles an already-open
        // floating window because "picked from the launcher = belongs in the
        // layout", and the tray icon is the launcher's equal, not a toggle:
        // the old park-on-second-click hid the app the user was reaching for.
        // Never launch here either: a fresh binary loses the login session.
        const wins = root.windowsOf(cls)
            .filter(w => !w.workspace || w.workspace.name !== "special:tray");
        if (wins.length === 0) {
            root.show(cls); // raced back into the vault between the checks
            return;
        }
        // A tiled window of the class wins over a floating one, same rule as
        // findRunningApp: a dialog shares the app's class, and the app is
        // what this click means.
        const pick = wins.find(w => w.floating !== true) ?? wins[0];
        root.setIntent(cls, true, "toggle (focus running)");
        // Same dispatch forms focusRunningApp verified against this build:
        // switch view first (focusing a window on another workspace is a
        // silent no-op), then focus by window object, then the focus-scoped
        // float unset -- never an address form on the float.
        if (pick.workspace?.id >= 0)
            Hyprland.dispatch(`hl.dsp.focus({ workspace = ${pick.workspace.id} })`);
        Hyprland.dispatch(`hl.dsp.focus({ window = hl.get_window("address:${pick.address}") })`);
        const sw = pick.size?.width ?? 0;
        const sh = pick.size?.height ?? 0;
        const tiny = sw > 0 && sh > 0 && (sw < 300 || sh < 200);
        if (pick.floating === true && !tiny)
            Hyprland.dispatch(`hl.dsp.window.float({ action = "unset" })`);
    }

    function launch(cls) {
        const entry = root.registry.find(e => e.cls === cls);
        if (!entry || !entry.launch)
            return;
    // Single-instance guard: if the app already has a window (parked in
    // the tray or on a workspace), do not start a second copy -- a fresh
    // whatsapp-linux-desktop binary is a new browser context and loses the
    // login session. Bring the existing window out of the tray instead.
    // This is belt-and-suspenders on top of toggle()'s isRunning/isHidden
    // check: the tray icon normally takes the show() path, but a stale
    // windowList snapshot or a race can leave launch() as the path taken,
    // and the only visible result of that mistake is a lost login.
    if (root.isRunning(cls)) {
        root.show(cls);
        return;
    }
    // Electron apps (whatsapp-linux-desktop) can outlive their window: the
    // process stays alive but hyprctl reports no window. In that case too a
    // second binary is wrong -- the user will re-login. Fall back to the
    // process table: if the binary is still running, restore focus to it
    // rather than launching again. This only fires when there is genuinely no
    // window to show() (rare -- it is the windowless-but-alive tail case),
    // and show() has nothing to restore there, so the process-level check is
    // the right gate.
    if (root.processAlive(cls)) {
        root.show(cls);
        return;
    }
        root.setIntent(cls, true, "launch");
        root.markBusy(cls, "launch", 15000);
        // Route through open.sh (the shell's normal launch pipeline) instead of
        // a bare `bash -c`. open.sh does three things a bare exec does not:
        //   1. calls `trayapps allow` BEFORE the window exists, so
        //      enforceTray reads this as the user letting the app out and does
        //      not re-park the first window that appears;
        //   2. registers the started pid in ii-super-launched, which is the
        //      compositor's attachment signal -- without it the window has no
        //      launch-origin and the classifier may treat it as a popup;
        //   3. stamps II_OPENED_BY_II so inner re-execs cannot misreport a
        //      succeeded launch as a failure.
        // open.sh wants a label + command as two separate args; use the entry's
        // human name as the label (the same string the tray tooltip shows).
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/launch/open.sh"), entry.name, entry.launch]);
    }

    // ── The launcher's half of the tray permission, as a ROOT function ─────
    //
    // It lives here and not in the IPC handler below because the SHELL calls
    // it directly now: open.sh used to reach this same code by starting a
    // whole Qt client (`qs -c ii ipc call trayapps allow <cmd>`), measured at
    // 34-43ms on every launch and serialized before the app was exec'd. The
    // handler below is the thin forward, the same shape as toggle/show/park.
    //
    // Called BEFORE the window exists (that is what the tray guard reads),
    // from GlobalStates.allowTrayLaunch -- one place, for every launch the
    // shell makes: the search bar, the start menu, the dock, the taskbar.
    function allowLaunch(cmd) {
        // The launcher quotes each argv word before joining it into the
        // shell line it hands open.sh (GlobalStates.entryCommand ->
        // shellQuote), so a desktop entry whose Exec is `thunderbird %u`
        // arrives here as LITERAL `'thunderbird'` -- quotes and all. The
        // strip below turns that back into the bare word; measured: the
        // unstripped form matched NOTHING, which is how a cold menu
        // launch of Thunderbird never got its permission and the watcher
        // parked the window the moment it appeared. The basename pass
        // additionally lets `thunderbird` match `/usr/bin/thunderbird`.
        const raw = String(cmd).trim();
        const clean = raw
            .replace(/^'+\s*/, "")
            .replace(/\s*'+$/, "")
            .replace(/\\'/g, "'")
            .trim();
        // Words = split on whitespace and QUOTES only (not `/`): a path
        // token stays whole, so its basename is its part after the last
        // slash. `cd '/home/user' && 'thunderbird' '-compose'` then
        // yields cd, /home/user, &&, thunderbird, -compose -- and the
        // bare-word test below fires on `thunderbird`.
        const words = (s) => String(s).split(/[\s'"]+/).filter(Boolean);
        const baseOf = (w) => { const parts = w.split("/"); return parts[parts.length - 1]; };
        const hit = root.registry.find(e => {
            if (!e.launch)
                return false;
            const ln = String(e.launch);
            if (clean.indexOf(ln) !== -1 || ln.indexOf(clean) !== -1)
                return true;
            // WHOLE-WORD basename match, equality only -- never substring:
            // equality is what kept "bird" and "mail" from answering to
            // "thunderbird", and keeps one app whose path merely contains
            // another app's name from matching it. The check runs over
            // EVERY word of the command (head, and any quoted argument),
            // against every word of the launch path.
            const cw = words(clean);
            const lw = words(ln);
            // The declared names first: an app can be started by more than
            // one command (WhatsApp: the wrapper AND the binary), and only
            // the app knows the full list. Case-insensitive, basename only,
            // equality -- never a substring, which is what kept `bird` from
            // answering to `thunderbird`.
            const bins = Array.isArray(e.bins)
                ? e.bins.map(b => String(b).toLowerCase()) : [];
            for (const c of cw) {
                const cb = baseOf(c).toLowerCase();
                if (cb.length > 0 && bins.indexOf(cb) >= 0)
                    return true;
                if (cb.length <= 2)
                    continue;
                for (const l of lw) {
                    if (baseOf(l).toLowerCase() === cb)
                        return true;
                }
            }
            return false;
        });
        if (!hit)
            return `allow: no tray app matches`;
        root.setIntent(hit.cls, true, "allow (launcher)");
        // "Open it from the menu" has to OPEN it when the app is already
        // sitting in the vault: starting the binary again is a no-op for
        // a single-instance app, so the second copy forwards to the first
        // and the window that is already parked stays parked. Bring it
        // out here, where the request came from the user.
        const out = root.isHidden(hit.cls) ? " shown" : "";
        if (out)
            root.show(hit.cls);
        return `allow(${hit.cls})${out}`;
    }

    // Really quits: TERM every window's pid (unique -- one process can own
    // several windows; hyprctl reports the main pid). Works from the vault
    // too, since parked windows are still in the window list.
    function quit(cls) {
        const pids = Array.from(new Set(
            root.windowsOf(cls).map(w => w.pid).filter(p => p > 0)));
        for (const pid of pids)
            Quickshell.execDetached(["kill", "-TERM", String(pid)]);
        root.setIntent(cls, false, "quit");
    }

    // ── Stays in the tray ───────────────────────────────────────────────────
    // WhatsApp asks for focus when a message arrives, and a window that is
    // focused inside `special:tray` takes the vault with it: the app used to
    // pop itself back onto the desktop at random. The user's rule is a one-
    // way door -- it stays in the tray unless THEY let it out, through the
    // tray icon or by launching it again -- so "may this class be on screen"
    // is state, and only two things write it:
    //
    //   set true  by show() (tray icon, notification click), by launch() and
    //             by a launch from the shell's own launcher (open.sh calls
    //             `trayapps allow` with the command line it is about to run,
    //             BEFORE the window exists -- that is the start menu, not the
    //             app dragging itself out), and by adopt() on a reload;
    //   set false by park() and by quit(), and by the window going away.
    //
    // A window appearing on its own is deliberately NOT a launch: that is
    // the app putting one there (it restarts its own window), and the
    // watcher parks it below instead of asking whether the user meant it.
    property var trayIntent: ({})
    // Per-class timestamp of the LAST time the permission was granted. The
    // launch gap guard below (enforceTray's !has branch) reads it: a grant
    // through allow() from the launcher arrives BEFORE the app's first window
    // exists (Thunderbird maps its first window 5-8s after process start),
    // and revoking after the fixed 1s "window gone" grace is what parked the
    // app the instant its window finally appeared. Held 20s, which covers the
    // slowest cold start this machine has produced (Thunderbird 15s, cold:
    // measured) with margin; a REVOCATION clears it so a later unsanctioned
    // stray is still parked on the normal schedule.
    property var grantedAt: ({})
    property var hadWindows: ({})
    property var lastParkAt: ({})
    property bool adopted: false
    property real vaultCloseAt: 0
    // Per-class timestamp of "the window list just went empty". Held for a
    // second before the permission is revoked -- see enforceTray.
    property var goneAt: ({})
    // Per-class timestamp of "every window is in the vault" while the
    // permission still says it may be out. Held for 1.5s for the mirror
    // reason -- see enforceTray.
    property var allParkedAt: ({})

    function setIntent(cls, on, why) {
        const was = root.trayIntent[cls] === true;
        if (was !== on)
            console.log(`[TrayApps] ${new Date().toISOString().slice(11, 23)} intent(${cls}) ${was} -> ${on} by ${why ?? "?"}`);
        const m = Object.assign({}, root.trayIntent);
        // The grant timestamp rides the same object: stamping it is what lets
        // the launch-gap guard below hold the permission while the app is
        // still between `allow` and its first window. A revocation clears the
        // stamp, so a grant can never outlive the permission it belongs to.
        if (on)
            m[cls] = true;
        else
            delete m[cls];
        root.trayIntent = m;
        const gs = Object.assign({}, root.grantedAt);
        if (on)
            gs[cls] = Date.now();
        else
            delete gs[cls];
        root.grantedAt = gs;
    }

    function enforceTray() {
        // First tick that has real window data: adopt what is already on
        // screen. A config reload (every QML save) or a shell restart wipes
        // this map, and without this the app the user had open would be
        // parked again the moment the shell came back -- which reads as the
        // tray eating a window for no reason. Anything the APP dragged out
        // of the vault has already been put back by this watcher before the
        // first data-bearing tick, so a window sitting on a normal workspace
        // here is a window the user put there.
        if (!root.adopted && (HyprlandData.windowList ?? []).length > 0) {
            root.adopted = true;
            for (const e of root.registry) {
                if (!root.closeToTrayEnabled(e.cls))
                    continue;
                if (root.windowsOf(e.cls).length > 0 && !root.isHidden(e.cls))
                    root.setIntent(e.cls, true, "adopt after reload");
            }
        }
        // ── The vault itself must not sit on screen ───────────────────────
        // (Triggered by the app's own reveal; see the monitor read below.)
        // Nothing the user can press opens `special:tray`: SUPER+S and the
        // bar's workspace chip toggle the scratchpad `special`,
        // window-controls.sh toggles `minimized`. The only thing that can
        // reveal the vault is the app asking for focus -- which is exactly
        // what a message makes WhatsApp do, and is why it used to pop up at
        // random. So: the vault is showing, nobody asked for it, close it.
        //
        // Read off the MONITOR, not off activeWindow: opening a special
        // workspace does not move focus into it on this build (measured:
        // vault open, activeWindow still the window on workspace 6), so a
        // focus-based test could never see the reveal. And toggled with the
        // bare-name form -- `toggle_special("tray")` is the one that opens
        // and closes THIS vault (measured: monitor reads `special:tray` and
        // activeWindow becomes the parked app); the `{ name = "special:tray" }
        // form targets a different special workspace entirely and left the
        // vault on screen, which is the bug this replaces.
        const monitors = HyprlandData.monitors ?? [];
        const vaultOpen = monitors.some(m => m && m.specialWorkspace
            && m.specialWorkspace.name === "special:tray");
        if (vaultOpen) {
            const inside = root.registry.some(e => root.trayIntent[e.cls] !== true
                && root.windowsOf(e.cls).some(w => w.workspace && w.workspace.name === "special:tray"));
            // One attempt per 750ms: a reveal arrives as a burst (monitors,
            // workspaces, active window all change together), every handler
            // in that burst re-reads the SAME still-open monitor record and
            // would dispatch again -- toggles then alternate open/close and
            // the app flashes. Measured: five dispatches from one reveal.
            // The cooldown lets the fresh read land; if the vault is STILL
            // showing after it, that is a real failure and it retries.
            if (inside && Date.now() - root.vaultCloseAt > 750) {
                root.vaultCloseAt = Date.now();
                console.log(`[TrayApps] ${new Date().toISOString().slice(11, 23)} vault revealed with no app allowed out -> closing it`);
                Hyprland.dispatch('hl.dsp.workspace.toggle_special("tray")');
            }
        }
        const seen = Object.assign({}, root.hadWindows);
        for (const e of root.registry) {
            const cls = e.cls;
            const wins = root.windowsOf(cls);
            const has = wins.length > 0;
            if (!root.closeToTrayEnabled(cls)) {
                // Not a tray app: the setting decides, never this watcher.
                seen[cls] = has;
                continue;
            }
            if (!has) {
                // The client list DROPS a window while it is being moved
                // (measured: `hyprctl clients` loses WhatsApp during a
                // park/show dispatch and it is back about a second later).
                // Revoking the permission on that blip is how an app the
                // user had just opened got re-parked a few seconds
                // afterwards: permission gone, window reappears, and the
                // watcher below sees a stray it is entitled to park. So the
                // window has to stay gone for a full second first; if it
                // comes back inside that, nothing was revoked.
                const gone = root.goneAt[cls] || 0;
                // A LAUNCH IN FLIGHT keeps its permission: Thunderbird takes
                // 5-8s between process start and its first window mapping,
                // and revoking the intent inside that gap is exactly the bug
                // this fixes -- permission gone, the window then maps, and
                // the watcher below reads it as a stray and parks it on
                // arrival, which is the app "opening and instantly
                // disappearing into the tray". markBusy("launch") holds the
                // gate: busyFor() is true from launch() until the window
                // maps (or its own timeout prunes it), and only THEN can the
                // permission lapse. Also covers the earlier crash WHERE THE
                // ALLOW RAN BEFORE THE WINDOW EXISTED but the compositor's
                // window list had not yet dropped the old window (or
                // processAlive's pgrep is still returning matches), which
                // used to clear the intent within a second of granting it.
                // A RECENTLY GRANTED permission holds through the launch gap
                // too: the launcher's allow() runs before the window exists,
                // and busyMap does not cover calls from outside this service
                // (the launcher path never calls markBusy). 20s from the
                // grant covers the slowest measured cold start; a real closing
                // of the app is only revoked after that. A quit (park+quit
                // paths) clears the permission and its stamp together, so a
                // later stray still parks on the normal schedule.
                const granted = root.grantedAt[cls] || 0;
                const inFlight = (root.busyMap[cls]
                    && root.busyMap[cls].kind === "launch"
                    && Date.now() <= root.busyMap[cls].until)
                    || (Date.now() - granted < 20000 && root.trayIntent[cls] === true);
                if (inFlight) {
                    seen[cls] = false;
                    continue;
                }
                if (!gone) {
                    const g = Object.assign({}, root.goneAt);
                    g[cls] = Date.now();
                    root.goneAt = g;
                } else if (Date.now() - gone > 1000) {
                    if (root.trayIntent[cls] === true)
                        console.log(`[TrayApps] ${new Date().toISOString().slice(11, 23)} intent dropped for ${cls}: window gone for ${Date.now() - gone}ms`);
                    root.setIntent(cls, false, "window closed");
                    const g = Object.assign({}, root.goneAt);
                    delete g[cls];
                    root.goneAt = g;
                }
                seen[cls] = false;
                continue;
            }
            // Still here, or back inside the grace period: cancel the
            // pending revocation.
            if (root.goneAt[cls]) {
                const g = Object.assign({}, root.goneAt);
                delete g[cls];
                root.goneAt = g;
            }
            seen[cls] = true;
            const stray = wins.filter(w => !w.workspace || w.workspace.name !== "special:tray");
            // DURING THE LAUNCH WINDOW the permission cannot expire, however
            // the list reads: a launch in flight (granted recently, still
            // allowed out) is inside Thunderbird's heavy startup, and that
            // burst produced a STALE windowList mid-map (measured, run 2 of
            // three identical cold launches: the all-parked branch read
            // "all windows parked for 1876ms" for a window the compositor
            // itself reported tiled on ws 2 -- the 60ms-debounced re-read
            // served the pre-launch record). Revoking on that phantom
            // parked every 3rd cold launch. The 25s bound matches the
            // slowest measured cold start below and the !has guard above.
            const granted = root.grantedAt[cls] || 0;
            const launchShield = Date.now() - granted < 25000 && root.trayIntent[cls] === true;
            if (root.trayIntent[cls] === true) {
                // Open on purpose -- leave the windows alone. But a
                // permission with NOTHING on screen has expired, and it can
                // get that way without park() ever running: the close
                // gesture in Hyprland (4-finger swipe down, SUPER+Q)
                // dispatches its own move and never tells this service
                // (measured: a synthetic swipe from another session parked
                // the app while `trayIntent` still said "allowed out",
                // which is a permission the app could then use to raise
                // itself and be allowed to stay). The 1.5s grace exists
                // because show() sets the permission FIRST and moves the
                // window out SECOND: for a moment the two disagree while
                // the move is still in flight.
                if (stray.length > 0) {
                    if (root.allParkedAt[cls]) {
                        const a = Object.assign({}, root.allParkedAt);
                        delete a[cls];
                        root.allParkedAt = a;
                    }
                } else {
                    const since = root.allParkedAt[cls] || 0;
                    if (!since) {
                        if (!launchShield) {
                            const a = Object.assign({}, root.allParkedAt);
                            a[cls] = Date.now();
                            root.allParkedAt = a;
                        }
                    } else if (launchShield) {
                        // Shield active: the timer never accumulates, so a
                        // phantom "all parked" reading during a launch cannot
                        // reach the 1.5s verdict.
                        const a = Object.assign({}, root.allParkedAt);
                        delete a[cls];
                        root.allParkedAt = a;
                    } else if (Date.now() - since > 1500) {
                        console.log(`[TrayApps] ${new Date().toISOString().slice(11, 23)} permission expired for ${cls}: all windows parked for ${Date.now() - since}ms`);
                        root.setIntent(cls, false, "parked while allowed out");
                        const a = Object.assign({}, root.allParkedAt);
                        delete a[cls];
                        root.allParkedAt = a;
                    }
                }
                continue;
            }
            // No permission, so any window that is not IN the vault is the
            // app having put one there -- including a window it restarted
            // for itself, which is why a window appearing is NOT counted as
            // a launch below. Move it back rather than kill it.
            if (stray.length > 0) {
                if (root.allParkedAt[cls]) {
                    const a = Object.assign({}, root.allParkedAt);
                    delete a[cls];
                    root.allParkedAt = a;
                }
                root.park(cls, "watcher:stray");
                continue;
            }
            // All of them are parked with no permission to be out. A vault
            // that is nonetheless showing on screen was already closed by
            // the monitor check at the top of this function.
        }
        root.hadWindows = seen;
    }

    // Event-driven first (the raise changes focus, and a stray window
    // changes the list), with a slow tick behind it as the net for anything
    // that slips between two events. Cheap either way: one registry entry,
    // a filter over a ten-line window list.
    Connections {
        target: HyprlandData
        function onWindowListChanged() { root.requestEnforce(); }
        function onActiveWindowChanged() { root.requestEnforce(); }
        function onActiveWorkspaceChanged() { root.requestEnforce(); }
        // The vault showing up is a MONITOR fact (see enforceTray): this is
        // what turns the reveal into a close without waiting for the 1s tick.
        function onMonitorsChanged() { root.requestEnforce(); }
    }

    // One run per BURST, not one per event: a reveal, a raise or a move
    // arrives as several compositor events in the same few milliseconds, and
    // each of them used to schedule its own enforceTray -- which meant the
    // same park dispatched again before the first one had landed (see the
    // note in park()). 150ms is longer than that burst and shorter than any
    // flicker a user could notice.
    function requestEnforce() { enforceTick.restart(); }
    Timer {
        id: enforceTick
        interval: 150
        repeat: false
        onTriggered: root.enforceTray()
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: root.enforceTray()
    }

    // ── Identity resolution ─────────────────────────────────────────────────
    // Two matchers with deliberately different scopes, because the trap is
    // matching with the wrong one (see Notifications.senderClass's note):
    //
    //   classForNotification -> REGISTRY ONLY. The registry knows the app
    //       whose class is spelled nothing like its name.
    //   classForTrayItem     -> registry first, then classes ON SCREEN.
    //       A notification/tray item from an app that is not running matches
    //       nothing, which is correct: there is no window to jump to.

    // Candidate spellings of any string we are asked to match: the value
    // itself, its basename (icons and desktop files arrive as paths), with
    // .desktop / image extensions stripped, lowercased. Length filters out
    // empties; matching below refuses pairs shorter than 3 chars so "ok"
    // cannot hit "kodi".
    function normStrings(vals) {
        const out = [];
        for (const v of vals) {
            if (typeof v !== "string" || v.length === 0)
                continue;
            const base = v.split("/").pop();
            for (const s of [v, base]) {
                const n = s.replace(/\.desktop$/i, "")
                           .replace(/\.(png|svg|xpm|ico|jpe?g|gif)$/i, "")
                           .trim().toLowerCase();
                if (n.length > 0 && out.indexOf(n) < 0)
                    out.push(n);
            }
        }
        return out;
    }

    // Exact spellings first, then containment either way (min 3 chars each
    // side). Order matters: "WhatsApp" must not containment-match some longer
    // unrelated class when an exact hit exists.
    function matchesAny(cands, keys) {
        for (const c of cands)
            if (keys.indexOf(c) >= 0)
                return true;
        for (const c of cands) {
            if (c.length < 3)
                continue;
            for (const k of keys) {
                if (k.length < 3)
                    continue;
                if (k.indexOf(c) >= 0 || c.indexOf(k) >= 0)
                    return true;
            }
        }
        return false;
    }

    function registryKeys(e) {
        return [String(e.cls ?? ""), String(e.name ?? ""), String(e.iconName ?? "")]
            .map(s => s.trim().toLowerCase()).filter(s => s.length > 0);
    }

    function classForNotification(notif) {
        if (!notif)
            return "";
        const cands = root.normStrings([notif.appName, notif.desktopEntry, notif.appIcon]);
        if (cands.length === 0)
            return "";
        for (const e of root.registry) {
            if (root.matchesAny(cands, root.registryKeys(e)))
                return e.cls;
        }
        return "";
    }

    // A SystemTrayItem (id / title / tooltip) or a synthetic {id, title} from
    // Notifications.senderClass's fallback. Parked windows are on screen for
    // hyprctl's purposes, so a parked app still resolves -- that is what lets
    // SysTrayItem.parkedClass find and restore an SNI app from the vault.
    function classForTrayItem(item) {
        if (!item)
            return "";
        const cands = root.normStrings([item.id, item.title, item.tooltip, item.tooltipText]);
        if (cands.length === 0)
            return "";
        for (const e of root.registry) {
            if (root.matchesAny(cands, root.registryKeys(e)))
                return e.cls;
        }
        const wins = HyprlandData.windowList ?? [];
        for (const w of wins) { // pass 1: exact
            const k = String(w.class ?? "").trim().toLowerCase();
            if (k.length > 0 && cands.indexOf(k) >= 0)
                return w.class;
        }
        for (const w of wins) { // pass 2: containment
            const k = String(w.class ?? "").trim().toLowerCase();
            if (k.length < 3)
                continue;
            for (const c of cands) {
                if (c.length < 3)
                    continue;
                if (k.indexOf(c) >= 0 || c.indexOf(k) >= 0)
                    return w.class;
            }
        }
        return "";
    }

    // Filter for the tray card's SNI items (SysTray.allItems): remove the
    // icon of an app that has been reaped. Only the REGISTRY side is provable
    // here -- registry entries are window-backed by definition, so one whose
    // window is gone is a ghost. Real SNI items are never declared dead: a
    // daemon (NetworkManager, avahi -- never any window) and an app that
    // closed its window ITSELF while keeping its own tray icon (Steam,
    // Discord do this) look identical from the window list, and hiding a
    // live icon is far worse than keeping a stale one. TrayNoise.isService is
    // not asked either, for the same reason: the Advanced grid is exactly the
    // never-a-window case.
    //
    // THE ONE EXCEPTION is the user's explicit rule: an app enabled for
    // close-to-tray (tray.closeToTray in config.json) shows its tray icon
    // ONLY while it is CLOSED -- parked in the tray vault -- never while its
    // window is open or still opening. The intent is known for exactly these
    // apps (the map is opt-in), so the old objection does not apply: while
    // the window is on screen the icon is noise on top of the window the user
    // is already looking at, and when it is parked the icon is the way back
    // in. Covers the shell-owned registry icons through the same door: their
    // liveRegistry model already implements this same rule.
    function isDeadItem(item) {
        if (!item)
            return true;
        const cands = root.normStrings([item.id, item.title, item.tooltip, item.tooltipText]);
        for (const e of root.registry) {
            if (root.matchesAny(cands, root.registryKeys(e)))
                return !root.isRunning(e.cls);
        }
        // Close-to-tray suppression. Resolved through classForTrayItem, which
        // matches PARKED windows too (hyprctl keeps vaulted windows in its
        // client list), so the parked state resolves and the icon shows.
        const cls = root.classForTrayItem(item);
        if (cls === "" || !root.closeToTrayEnabled(cls))
            return false;
        const wins = root.windowsOf(cls);
        if (wins.length > 0 && !root.isHidden(cls))
            return true; // window on a real workspace: the app is OPEN
        // A launch granted from the shell's launcher with no window mapped
        // yet is still OPENING (Thunderbird maps 5-8s in): no icon until the
        // window arrives. The 20s grant window matches enforceTray's.
        if (wins.length === 0 && root.trayIntent[cls] === true
            && Date.now() - (root.grantedAt[cls] || 0) < 20000)
            return true;
        // Parked (every window in special:tray), or windowless with no launch
        // in flight: CLOSED. This is the one state the icon exists for.
        return false;
    }

    // ── Settings (BarConfig: "Minimize to tray", per app) ───────────────────
    // The list fills itself from what can ACTUALLY be minimized right now:
    // registry apps with a window open, plus SNI apps (Discord, Steam --
    // "start one that registers a tray icon and it will appear here") whose
    // item resolves to a running window. It grows and shrinks with what is
    // open rather than asking anyone to keep a .desktop scan in step.
    // Returned shape: { cls, name, icon } -- icon may be "" (BarConfig falls
    // back to its generic glyph).

    function capableApps() {
        const out = [];
        const seen = ({});
        for (const e of root.registry) {
            if (!root.isRunning(e.cls))
                continue;
            seen[e.cls] = true;
            out.push({
                cls: e.cls,
                name: e.name,
                icon: Quickshell.iconPath(String(e.iconName ?? ""), "")
            });
        }
        const items = (TrayService.pinnedItems ?? [])
            .concat(TrayService.unpinnedItems ?? []);
        for (const item of items) {
            const cls = root.classForTrayItem(item);
            if (cls === "" || seen[cls] || !root.isRunning(cls))
                continue;
            seen[cls] = true;
            const icon = (typeof item.iconName === "string" && item.iconName.length > 0)
                ? Quickshell.iconPath(item.iconName, "") : "";
            const title = (typeof item.title === "string" && item.title.length > 0)
                ? item.title : cls;
            out.push({ cls: cls, name: title, icon: icon });
        }
        return out;
    }

    // Enabled only on an explicit true, matching the Lua side: smartClose
    // pattern-matches `"cls": true` in config.json's tray.closeToTray, so a
    // default of on here would show the switch enabled while the keybind
    // closed for real. Absent -> off (the map ships empty).
    function closeToTrayEnabled(cls) {
        if (!cls)
            return false;
        const m = Config.options.tray.closeToTray ?? {};
        return m[cls] === true;
    }

    // Reassign the whole map: mutating keys of a var property in place does
    // not notify, and persistence to config.json (the file smartClose reads)
    // rides on that change.
    function setCloseToTray(cls, on) {
        if (!cls)
            return;
        const m = Object.assign({}, Config.options.tray.closeToTray ?? {});
        if (on)
            m[cls] = true;
        else
            delete m[cls];
        Config.options.tray.closeToTray = m;
    }

    // ── Icons ───────────────────────────────────────────────────────────────
    // Themed name -> URL, with the shell's generic app glyph as fallback so
    // the icon cell is never empty (same fallback NotificationAppIcon uses).
    function iconFor(entry) {
        if (!entry)
            return "";
        return Quickshell.iconPath(String(entry.iconName ?? ""),
            Quickshell.shellPath("assets/icons/fluent/app-generic.svg"));
    }

    // ── IPC: read/drive the state without a physical click ──────────────────
    // The tray card is a hover-only popup behind a 24px chevron; "ask someone
    // to hover it and report" is not a verification step. `status` answers the
    // question the card cannot: what is in the model right now, and why.
    IpcHandler {
        target: "trayapps"

        function status(): string {
            const lines = [];
            const wl = HyprlandData.windowList ?? [];
            lines.push(`windowList=${wl.length} activeWs=${HyprlandData.activeWorkspace?.name}`);
            lines.push(`registry=${root.registry.length} live=${root.liveRegistry.length}`);
            for (const e of root.registry) {
                const wins = root.windowsOf(e.cls);
                lines.push(`${e.cls}: running=${root.isRunning(e.cls)} hidden=${root.isHidden(e.cls)} busy=${root.busyFor(e.cls)} wins=${wins.length} ws=[${wins.map(w => w.workspace?.name).join(",")}] intent=${root.trayIntent[e.cls] === true} had=${root.hadWindows[e.cls] === true} icon=${root.iconFor(e)}`);
            }
            lines.push(`capable=${JSON.stringify(root.capableApps().map(a => a.cls))}`);
            // Per-SNI-item decisions, so the close-to-tray suppression is
            // verifiable from a script: what the card keeps and what it
            // drops, with the inputs that decided it.
            const sni = (TrayService.pinnedItems ?? [])
                .concat(TrayService.unpinnedItems ?? []);
            lines.push(`sni=${sni.length}`);
            for (const item of sni) {
                const cls = root.classForTrayItem(item);
                const wins = cls ? root.windowsOf(cls) : [];
                lines.push(`  "${item.title ?? item.id}" id=${item.id} -> cls=${cls || "-"}`
                    + ` c2t=${root.closeToTrayEnabled(cls)}`
                    + ` wins=${wins.length}`
                    + ` allParked=${cls ? root.isHidden(cls) : "-"}`
                    + ` intent=${cls ? root.trayIntent[cls] === true : "-"}`
                    + ` dead=${root.isDeadItem(item)}`);
            }
            return lines.join("\n");
        }

        function toggle(cls: string): string {
            root.toggle(cls);
            return `toggle(${cls}) -> running=${root.isRunning(cls)} hidden=${root.isHidden(cls)}`;
        }

        function show(cls: string): string {
            root.show(cls);
            return `show(${cls}) -> hidden=${root.isHidden(cls)}`;
        }

        function park(cls: string): string {
            root.park(cls, "ipc");
            return `park(${cls}) -> hidden=${root.isHidden(cls)}`;
        }

        // The launcher's half of the permission above. open.sh calls this
        // with the command line it is about to run BEFORE the window exists,
        // so a launch from the start menu reads as a launch and not as the
        // app raising itself out of the tray. Matched against the registry's
        // own launch string, so only a real match counts.
        // Thin IPC forward, like toggle/show/park above: the body is a ROOT
        // function (allowLaunch) so the shell can take this permission
        // in-process instead of starting a Qt client to reach this handler.
        // open.sh still calls this for every caller outside the shell.
        function allow(cmd: string): string {
            return root.allowLaunch(cmd);
        }
    }
}

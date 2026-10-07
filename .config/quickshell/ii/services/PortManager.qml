pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs

/**
 * The port manager: every TCP/UDP port bound on this machine, with
 * start / stop / delete.
 *
 * The engine is scripts/system/ports.py -- scan via `ss`, lifecycle via
 * signals and (for managed units) systemctl --user. QML holds none of the
 * parsing; it runs the script and reshapes its JSON.
 *
 * Two kinds of rows come back from a scan:
 *
 *   live ....... a port something on this machine is bound to RIGHT NOW
 *                (its process name and pid ride along when the kernel
 *                knows them)
 *   saved ...... a port remembered in ports.json but not currently bound --
 *                a listener with its Start button, not a ghost
 *
 * A port with a systemd user unit named ii-port-<port>.service behind it
 * is "managed": stop goes through the unit, and DELETE is genuinely
 * destructive -- the unit file itself is removed from disk and the daemon
 * reloaded, so the port cannot come back at the next login. That is the
 * whole difference between delete and forget.
 */
Singleton {
    id: root

    readonly property string scriptPath: `${Directories.scriptPath}/system/ports.py`
    property var ports: []
    property bool scanning: false
    property string lastError: ""
    // The most recent action's human summary ("stop: stopped", "delete
    // failed: ..."), consumed as a toast by the tab; cleared by the tab
    // after showing, never here (this side has no clock for it).
    property string lastAction: ""

    // A scan runs on every completion of any action, so the list is honest
    // right after a stop or delete rather than one user-refresh behind.
    function refresh() {
        if (root.scanning)
            return;
        root.scanning = true;
        scanProc.command = ["python3", root.scriptPath, "scan"];
        scanProc.running = true;
    }

    function startPort(port) {
        root.run(["start", String(port)]);
    }

    function stopPort(port) {
        root.run(["stop", String(port)]);
    }

    function deletePort(port) {
        root.run(["delete", String(port)]);
    }

    function savePort(port, proto, name, command) {
        root.run(["save", String(port), String(proto), String(name), String(command)]);
    }

    function forgetPort(port) {
        root.run(["forget", String(port)]);
    }

    // Every verb but scan funnels here. The verb is remembered for the
    // toast; the action's own stdout confirms it, and a fresh scan
    // refills the list so no action leaves the tab one step behind.
    function run(argv) {
        actionProc.verb = argv[0] ?? "";
        actionProc.command = ["python3", root.scriptPath, ...argv];
        actionProc.running = true;
    }

    Process {
        id: scanProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.scanning = false;
                try {
                    root.ports = JSON.parse(text);
                    root.lastError = "";
                } catch (e) {
                    root.lastError = String(e);
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim().length > 0)
                root.lastError = text.trim()
        }
    }

    Process {
        id: actionProc
        property string verb: ""
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text);
                    root.lastAction = parsed.error
                        ? `${actionProc.verb} failed: ${parsed.error}`
                        : `${actionProc.verb}: ${parsed.status ?? parsed.saved ?? parsed.forgotten ?? "ok"}`;
                } catch (e) {
                    root.lastAction = `${actionProc.verb}: done`;
                }
                root.refresh();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim().length > 0)
                root.lastError = text.trim()
        }
    }

    IpcHandler {
        target: "ports"

        function refresh(): void {
            root.refresh();
        }

        function state(): string {
            return JSON.stringify({
                count: root.ports.length,
                bound: root.ports.filter(p => p.bound).length,
                managed: root.ports.filter(p => p.managed).length,
                error: root.lastError
            });
        }

        function start(port: int): void {
            root.startPort(port);
        }
        function stop(port: int): void {
            root.stopPort(port);
        }
        function del(port: int): void {
            root.deletePort(port);
        }
        function save(port: int, proto: string, name: string, command: string): void {
            root.savePort(port, proto, name, command);
        }
    }

    // A bounded poll, only while the sidebar tab is open: the tab calls
    // startPolling() when it becomes visible and stopPolling() when it
    // goes away, so an idle shell runs no scans at all.
    property bool pollActive: false
    Timer {
        interval: 5000
        repeat: true
        running: root.pollActive
        onTriggered: root.refresh()
    }
    function startPolling() {
        root.pollActive = true;
        root.refresh();
    }
    function stopPolling() {
        root.pollActive = false;
    }
}

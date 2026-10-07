#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════════
# The port manager's engine. One script, a handful of verbs:
#
#   scan                     every TCP/UDP port currently bound on this
#                            machine, with its owning process and whether
#                            a saved record / systemd user unit exists for it
#   save PORT PROTO CMD      remember a port so the sidebar can start it
#                            later (a plain command, spawned detached)
#   start PORT               bring a saved port up (unit start or spawn)
#   stop PORT                take a port down (unit stop or SIGTERM)
#   delete PORT              stop + remove the systemd user unit file that
#                            created the port + forget the record. Delete
#                            is REAL: the unit file is removed from disk,
#                            so the port cannot come back at login.
#   forget PORT              remove the saved record only (for foreign
#                            ports that are not ours to delete)
#
# QML cannot parse `ss -p` output, and the shell's other services
# (ProcessList, SystemNow) delegate to a script exactly like this.
# ═══════════════════════════════════════════════════════════════════════
import json
import os
import shlex
import signal
import subprocess
import sys
import time

II_UNIT_PREFIX = "ii-port-"
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "user", "ports")
STATE_FILE = os.path.join(STATE_DIR, "ports.json")
SYSTEMD_USER_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "systemd", "user")

VALID_PROTO = {"tcp", "udp"}


def _unit_name(port):
    return f"{II_UNIT_PREFIX}{port}.service"


def _fail(msg):
    raise SystemExit(json.dumps({"ok": False, "error": msg}))


def _out(obj):
    print(json.dumps(obj))


def read_state():
    try:
        with open(STATE_FILE) as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get("ports"), dict):
            return {"version": 1, "ports": {}}
        return data
    except FileNotFoundError:
        return {"version": 1, "ports": {}}
    except (json.JSONDecodeError, OSError):
        # A corrupt state file must not brick the whole tab: start empty.
        return {"version": 1, "ports": {}}


def write_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    os.replace(tmp, STATE_FILE)


def scan():
    """Every bound port with its owning process, in one table."""
    rows = []
    try:
        output = subprocess.run(
            ["ss", "-H", "-tulpn"], capture_output=True, text=True, timeout=15)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return rows
    for line in output.stdout.splitlines():
        # ss -H -tulpn columns (whitespace-separated):
        # Netid State Recv-Q Send-Q Local:Port Peer:Port [users:((...))]
        parts = [p for p in line.split() if p]
        if len(parts) < 5:
            continue
        proto, state, _rq, _sq, addr = parts[0], parts[1], parts[2], parts[3], parts[4]
        proc_part = next((p for p in parts[5:] if p.startswith("users:")), None)
        local = addr.rsplit(":", 1)
        if len(local) != 2:
            continue
        try:
            port = int(local[1])
        except ValueError:
            continue
        pid = None
        name = ""
        if proc_part:
            # "users:(("kitty",pid=12345,fd=6))" -> parse without eval().
            inner = proc_part
            for pre in ("users:((", "users:(("):
                if inner.startswith(pre):
                    inner = inner[len(pre):]
            inner = inner.rstrip(")")
            first = inner.split("),(")[0].strip()
            fields = [f.strip() for f in first.split(",")]
            if fields:
                name = fields[0].strip('"')
                for field in fields[1:]:
                    if field.startswith("pid="):
                        try:
                            pid = int(field[4:])
                        except ValueError:
                            pid = None
        # A LISTEN row is the honest ownership proof for TCP. UDP has no
        # LISTEN state (-u rows are "UNCONN"), so any udp row with an owner
        # counts as bound.
        bound = state == "LISTEN" or proto == "udp"
        rows.append({
            "port": port,
            "proto": proto.upper(),
            "ip": local[0],
            "state": "UNBOUND" if state == "UNCONN" else state,
            "bound": bound,
            "pid": pid,
            "name": name,
        })
    return rows


def process_live(pid):
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError, TypeError):
        return False


def unit_status(port):
    out = subprocess.run(
        ["systemctl", "--user", "is-active", _unit_name(port)],
        capture_output=True, text=True)
    status = out.stdout.strip()
    return status if status else "missing"


def unit_file_exists(port):
    return os.path.exists(os.path.join(SYSTEMD_USER_DIR, _unit_name(port)))


def owner_row(port):
    port = int(port)
    for row in scan():
        if row["port"] == port and row["pid"]:
            return row
    return None


def cmd_scan(_args):
    state = read_state()
    saved = state["ports"]
    seen_ports = {row["port"] for row in scan()}
    merged = []
    for row in scan():
        rec = saved.get(str(row["port"]))
        merged.append({
            **row,
            "managed": bool(rec),
            "unit": rec.get("unit") if rec else None,
            "unitFileExists": unit_file_exists(row["port"]) if rec else False,
            "unitActive": unit_status(row["port"]) if rec else None,
            "command": rec.get("command") if rec else None,
        })
    # Saved-but-stopped ports: they bind nothing right now, but the sidebar
    # must still show them with their Start button.
    for key, rec in saved.items():
        if int(key) in seen_ports:
            continue
        merged.append({
            "port": rec.get("port", int(key)),
            "proto": (rec.get("proto") or "tcp").upper(),
            "ip": "*",
            "state": "STOPPED",
            "bound": False,
            "pid": None,
            "name": rec.get("name") or "",
            "managed": True,
            "unit": rec.get("unit"),
            "unitFileExists": unit_file_exists(int(key)),
            "unitActive": unit_status(int(key)),
            "command": rec.get("command"),
        })
    _out(merged)


def cmd_start(args):
    if len(args) != 1:
        _fail("start takes exactly one port")
    try:
        port = int(args[0])
    except ValueError:
        _fail("port must be a number")
    state = read_state()
    rec = state["ports"].get(str(port))
    if owner_row(port):
        _out({"ok": True, "status": "already-running"})
        return
    if rec and rec.get("command"):
        command = rec["command"]
        # shlex, not str.split(): a quoted payload (python3 -c "...", a path
        # with spaces) must survive the split or the spawn dies on the args.
        command = shlex.split(command) if isinstance(command, str) else command
        try:
            subprocess.Popen(
                command, start_new_session=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, ValueError) as exc:
            _out({"ok": False, "error": str(exc)})
            return
        _out({"ok": True, "status": "spawned"})
        return
    _out({"ok": False, "error": f"no saved start command for port {port}"})


def cmd_stop(args):
    if len(args) != 1:
        _fail("stop takes exactly one port")
    try:
        port = int(args[0])
    except ValueError:
        _fail("port must be a number")
    state = read_state()
    rec = state["ports"].get(str(port))
    stopped = False
    if rec and rec.get("unit"):
        subprocess.run(
            ["systemctl", "--user", "stop", rec["unit"]], check=False)
        stopped = True
    row = owner_row(port)
    if row:
        # SIGTERM first, so the process can flush and close its socket; a
        # hard SIGKILL leaves the port stuck in TIME_WAIT for a minute.
        try:
            os.kill(row["pid"], signal.SIGTERM)
            stopped = True
        except ProcessLookupError:
            pass
        except PermissionError:
            _out({"ok": False, "error": f"no permission to stop pid {row['pid']}"})
            return
        # Wait briefly for the port to actually free, so the next scan is
        # honest; the socket can lag the kill by a moment.
        for _ in range(20):
            time.sleep(0.1)
            if not owner_row(port):
                break
    _out({"ok": True, "status": "stopped" if stopped else "not-running"})


def cmd_delete(args):
    if len(args) != 1:
        _fail("delete takes exactly one port")
    try:
        port = int(args[0])
    except ValueError:
        _fail("port must be a number")
    state = read_state()
    rec = state["ports"].get(str(port))
    removed_unit = False
    # The unit is probed by its CANONICAL name, not only through the saved
    # record: a unit can exist on disk without the sidebar ever having saved
    # the port (a hand-written unit, a record already forgotten), and delete
    # must still tear it down -- "remove everything that made this port" is
    # the whole point of the verb.
    unit = rec.get("unit") if rec else _unit_name(port)
    if rec and rec.get("unit"):
        subprocess.run(
            ["systemctl", "--user", "stop", rec["unit"]], check=False)
    elif unit_status(port) != "missing":
        subprocess.run(
            ["systemctl", "--user", "stop", _unit_name(port)], check=False)
    if unit_file_exists(port):
        path = os.path.join(SYSTEMD_USER_DIR, _unit_name(port))
        try:
            os.remove(path)  # THE genuine teardown: the unit file dies.
            removed_unit = True
        except OSError as exc:
            _out({"ok": False, "error": f"cannot remove {path}: {exc}"})
            return
        subprocess.run(
            ["systemctl", "--user", "daemon-reload"], check=False)
    # Anything still holding the port goes down too, unit or not.
    row = owner_row(port)
    if row:
        try:
            os.kill(row["pid"], signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    # And forget it, so it never reappears in the sidebar.
    state["ports"].pop(str(port), None)
    write_state(state)
    _out({"ok": True, "status": "deleted", "port": port,
          "unitRemoved": removed_unit})


def cmd_save(args):
    if len(args) != 4:
        _fail("save takes PORT PROTO NAME COMMAND")
    port_raw, proto, name, command = args
    try:
        port = int(port_raw)
    except ValueError:
        _fail("port must be a number")
    proto = proto.lower()
    if proto not in VALID_PROTO:
        _fail("proto must be tcp or udp")
    if not command.strip():
        _fail("command must not be empty")
    state = read_state()
    state["ports"][str(port)] = {
        "port": port,
        "proto": proto,
        "name": name.strip(),
        "command": command.strip(),
        "savedAt": int(time.time()),
    }
    write_state(state)
    _out({"ok": True, "saved": port})


def cmd_forget(args):
    if len(args) != 1:
        _fail("forget takes exactly one port")
    try:
        port = int(args[0])
    except ValueError:
        _fail("port must be a number")
    state = read_state()
    state["ports"].pop(str(port), None)
    write_state(state)
    _out({"ok": True, "forgotten": port})


def main():
    verbs = {
        "scan": (cmd_scan, 0),
        "start": (cmd_start, 1),
        "stop": (cmd_stop, 1),
        "delete": (cmd_delete, 1),
        "save": (cmd_save, 4),
        "forget": (cmd_forget, 1),
    }
    if len(sys.argv) < 2:
        _out(scan())
        return
    verb = sys.argv[1]
    if verb not in verbs:
        _fail(f"unknown verb {verb}")
    handler, argn = verbs[verb]
    args = sys.argv[2:]
    if len(args) != argn:
        _fail(f"{verb} takes {argn} argument(s), got {len(args)}")
    handler(args)


if __name__ == "__main__":
    main()

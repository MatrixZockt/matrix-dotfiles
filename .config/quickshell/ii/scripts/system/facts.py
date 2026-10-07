#!/usr/bin/env python3
"""What this machine IS, as JSON on stdout.

The card's live numbers (usage, clocks, throughput) say what the machine is
doing; this says what you are doing it on. A task manager that cannot tell you
which processor you have, how many cores it really has, which driver your
graphics chip is on or what model the disk is is only half a task manager.

Everything here is read from /sys, /proc and the few CLI tools that are always
present, so it works without root and without installing anything.

    {"system": {...}, "cpu": {...}, "memory": {...}, "gpus": [...],
     "disks": [...], "networks": [...], "batteries": [...], "temperatures": [...],
     "displays": [...]}

Fields that need root (DIMM part numbers and clock speeds live in SMBIOS, which
needs dmidecode as root) are simply absent rather than guessed at.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys


def read(path, default=""):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return default


def read_int(path, default=0):
    try:
        return int(read(path, str(default)))
    except ValueError:
        return default


def run(args):
    """Run a command and return its stdout, or empty when it is not available."""
    if not shutil.which(args[0]):
        return ""
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=4).stdout
    except Exception:
        return ""


# ── system ───────────────────────────────────────────────────────────────────
def os_pretty_name():
    for line in read("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            return line.split("=", 1)[1].strip().strip('"')
    return read("/proc/sys/kernel/ostype", "Linux")


def uptime_seconds():
    try:
        return int(float(read("/proc/uptime", "0").split()[0]))
    except (ValueError, IndexError):
        return 0


def system_facts():
    return {
        "hostname": read("/proc/sys/kernel/hostname"),
        "os": os_pretty_name(),
        "kernel": read("/proc/sys/kernel/osrelease"),
        "uptime": uptime_seconds(),
        "session": os.environ.get("XDG_CURRENT_DESKTOP", "Hyprland"),
        "desktop": os.environ.get("XDG_SESSION_DESKTOP", ""),
        "arch": run(["uname", "-m"]).strip() or read("/proc/sys/kernel/arch"),
        "shell": os.environ.get("SHELL", ""),
        "bootMode": "UEFI" if os.path.isdir("/sys/firmware/efi") else "BIOS",
        "vendor": read("/sys/devices/virtual/dmi/id/sys_vendor"),
        "model": read("/sys/devices/virtual/dmi/id/product_name"),
        "bios": read("/sys/devices/virtual/dmi/id/bios_version"),
    }


# ── cpu ──────────────────────────────────────────────────────────────────────
def cpu_facts():
    info = read("/proc/cpuinfo")
    model = ""
    for line in info.splitlines():
        if line.lower().startswith("model name"):
            model = line.split(":", 1)[1].strip()
            break
    if not model:
        # ARM boards report the model elsewhere.
        for line in read("/proc/device-tree/model", "").split("\x00"):
            if line.strip():
                model = line.strip()
                break

    packages = set()
    physical = set()
    logical = 0
    for path in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/topology/physical_package_id")):
        packages.add(read(path))
    for cpu in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/topology/core_id")):
        physical.add((read(cpu.rsplit("/", 2)[0] + "/physical_package_id"), read(cpu)))
        logical += 1

    freq_min = freq_max = 0
    for path in sorted(glob.glob("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")):
        freq_max = read_int(path) // 1000
    for path in sorted(glob.glob("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq")):
        freq_min = read_int(path) // 1000

    cache = ""
    match = re.search(r"cache size\s*:\s*(.+)", info)
    if match:
        cache = match.group(1).strip()

    l3 = read_int("/sys/devices/system/cpu/cpu0/cache/index3/size", 0)
    if l3:
        cache = f"{l3} KB" if l3 < 1024 else f"{round(l3 / 1024)} MB"

    governor = read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
    return {
        "model": model,
        "cores": len(physical) if physical else logical,
        "threads": logical or read_int("/proc/cpuinfo", 0),
        "sockets": len(packages) or 1,
        "cache": cache,
        "minMhz": freq_min,
        "maxMhz": freq_max,
        "governor": governor,
        "flags": ("hypervisor " in info),
    }


# ── memory ───────────────────────────────────────────────────────────────────
def meminfo():
    out = {}
    for line in read("/proc/meminfo").splitlines():
        key, _, value = line.partition(":")
        parts = value.split()
        if parts:
            out[key.strip()] = int(parts[0]) * 1024
    return out


def memory_facts():
    info = meminfo()
    total = info.get("MemTotal", 0)
    return {
        "total": total,
        "available": info.get("MemAvailable", 0),
        "free": info.get("MemFree", 0),
        "cached": info.get("Cached", 0),
        "buffers": info.get("Buffers", 0),
        "swapTotal": info.get("SwapTotal", 0),
        "swapFree": info.get("SwapFree", 0),
        # DIMM type and speed need root (SMBIOS). Only say what /proc knows.
        "slots": len(glob.glob("/sys/devices/system/memory/memory*")) or 0,
    }


# ── graphics ─────────────────────────────────────────────────────────────────
VENDORS = {
    "8086": "Intel",
    "10de": "NVIDIA",
    "1002": "AMD",
    "1022": "AMD",
    "1af4": "virtio",
    "15ad": "VMware",
    "1234": "QEMU",
}


def gpu_facts():
    """One entry per graphics chip, not per DRM card.

    /sys/class/drm has a card for every driver that registered one, and several
    of them are not a chip anybody wants listed (the display-only cards, the
    render nodes). Anything without a PCI slot is pinned to nothing and skipped
    -- that is what turned this list into five identical "GPU ()" rows.
    """
    lspci = run(["lspci", "-mm"])
    out = []
    seen = set()
    for uevent_path in sorted(glob.glob("/sys/class/drm/card[0-9]*/device/uevent")):
        uevent = dict(
            line.split("=", 1) for line in read(uevent_path).splitlines() if "=" in line
        )
        pci = uevent.get("PCI_SLOT_NAME", "")
        if not pci or pci in seen:
            continue
        seen.add(pci)
        driver = uevent.get("DRIVER", "")
        vendor_id, _, device_id = uevent.get("PCI_ID", "").partition(":")

        name = ""
        for line in lspci.splitlines():
            # lspci -mm quotes every field: "00:02.0" "VGA compatible controller" "Intel" ...
            fields = re.findall(r'"([^"]*)"', line)
            if fields and fields[0] == pci:
                name = " ".join(part for part in fields[2:4] if part)
                break
        if not name:
            vendor = VENDORS.get(vendor_id, vendor_id or "Unknown vendor")
            kind = "Graphics"
            for line in run(["lspci", "-n"]).splitlines():
                if line.startswith(pci) and "0300" in line:
                    kind = "Graphics"
            name = f"{vendor} {kind}"

        out.append({
            "pci": pci,
            "name": name,
            "driver": driver or "unknown driver",
            "vendorId": vendor_id,
            "deviceId": device_id,
            "classId": uevent.get("PCI_CLASS", ""),
        })
    return out


# ── storage ──────────────────────────────────────────────────────────────────
def disk_facts():
    out = []
    for path in sorted(glob.glob("/sys/block/*")):
        name = os.path.basename(path)
        if name.startswith(("loop", "ram", "zram", "dm-", "sr")):
            continue
        model = read(f"{path}/device/model") or read(f"{path}/device/name")
        if not model:
            continue
        sectors = read_int(f"{path}/size")           # 512-byte sectors
        rotational = read(f"{path}/queue/rotational", "1") == "1"
        if name.startswith("nvme"):
            kind, bus = "NVMe", "PCIe"
        elif rotational:
            kind, bus = "HDD", "SATA"
        else:
            kind, bus = "SSD", "SATA"
        if os.path.exists(f"{path}/device/type"):
            bus = read(f"{path}/device/type")
        mounts = []
        try:
            with open("/proc/mounts") as handle:
                for line in handle:
                    device, mount = line.split()[0], line.split()[1]
                    if os.path.basename(device).startswith(name):
                        mounts.append(mount)
        except OSError:
            pass
        out.append({
            "name": name,
            "model": model,
            "size": sectors * 512,
            "type": kind,
            "bus": bus,
            "rotational": rotational,
            "mounts": mounts[:4],
        })
    return out


# ── network ──────────────────────────────────────────────────────────────────
def network_facts():
    addresses = {}
    ip_out = run(["ip", "-j", "addr"])
    try:
        for interface in json.loads(ip_out or "[]"):
            info = {"v4": [], "v6": [], "mac": interface.get("address", "")}
            for addr in interface.get("addr_info", []):
                if addr.get("family") == "inet":
                    info["v4"].append(f"{addr['local']}/{addr['prefixlen']}")
                elif addr.get("family") == "inet6" and not addr["local"].startswith("fe80"):
                    info["v6"].append(f"{addr['local']}/{addr['prefixlen']}")
            addresses[interface.get("ifname")] = info
    except Exception:
        pass

    out = []
    for path in sorted(glob.glob("/sys/class/net/*")):
        name = os.path.basename(path)
        if name == "lo":
            continue
        wireless = os.path.isdir(f"{path}/wireless") or os.path.isdir(f"{path}/phy80211")
        carrier = read(f"{path}/carrier", "0")
        speed = read_int(f"{path}/speed", 0)
        info = addresses.get(name, {})
        out.append({
            "name": name,
            "type": "wifi" if wireless else "ethernet",
            "state": read(f"{path}/operstate"),
            "connected": carrier == "1",
            "speedMbps": speed if speed > 0 else 0,
            "mac": info.get("mac") or read(f"{path}/address"),
            "ipv4": info.get("v4", []),
            "ipv6": info.get("v6", []),
            "driver": os.path.basename(os.path.realpath(f"{path}/device/driver")) if os.path.exists(f"{path}/device/driver") else "",
        })
    return out


# ── battery, sensors, displays ───────────────────────────────────────────────
def battery_facts():
    out = []
    for path in sorted(glob.glob("/sys/class/power_supply/BAT*")):
        out.append({
            "name": os.path.basename(path),
            "model": read(f"{path}/model_name"),
            "manufacturer": read(f"{path}/manufacturer"),
            "technology": read(f"{path}/technology"),
            "cycles": read_int(f"{path}/cycle_count", -1),
            "energyFull": read_int(f"{path}/energy_full", 0) // 1000,
            "energyFullDesign": read_int(f"{path}/energy_full_design", 0) // 1000,
            "capacity": read_int(f"{path}/capacity", 0),
            "health": "Good" if read(f"{path}/health", "") == "Good" else read(f"{path}/health", ""),
        })
    return out


def temperature_facts():
    out = []
    for path in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        chip = read(f"{path}/name", os.path.basename(path))
        for label_path in sorted(glob.glob(f"{path}/temp*_label")):
            value = read_int(label_path.replace("_label", "_input"), -1000000)
            if value < -100000:
                continue
            out.append({
                "chip": chip,
                "label": read(label_path),
                "celsius": round(value / 1000.0, 1),
            })
    return out[:12]


def display_facts():
    out = []
    for path in sorted(glob.glob("/sys/class/drm/card[0-9]*-*")):
        name = os.path.basename(path)
        if not re.match(r"card\d+-[A-Za-z]", name):
            continue
        enabled = read(f"{path}/enabled", "disabled")
        modes = [line for line in read(f"{path}/modes").splitlines() if line]
        size = read(f"{path}/connector_id")
        out.append({
            "name": name,
            "connected": read(f"{path}/status", "unknown") == "connected",
            "enabled": enabled == "enabled",
            "modes": modes[:1],
            "connector": size,
        })
    return out


def main():
    facts = {
        "system": system_facts(),
        "cpu": cpu_facts(),
        "memory": memory_facts(),
        "gpus": gpu_facts(),
        "disks": disk_facts(),
        "networks": network_facts(),
        "batteries": battery_facts(),
        "temperatures": temperature_facts(),
        "displays": display_facts(),
    }
    json.dump(facts, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

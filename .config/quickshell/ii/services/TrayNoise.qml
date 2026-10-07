pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.services
import qs.modules.common

/**
 * Which tray icons are BACKGROUND SERVICE NOISE, and which are things the
 * person at the keyboard actually reaches for.
 *
 * The problem: on a desktop with avahi, NetworkManager, polkit, the kernel
 * manager, ccsm, a tray agent and a dozen more daemons running, the tray card
 * fills with icons that are all the same weight. Nothing is wrong with any of
 * them individually, and nothing is urgent, so the icons that DO want a click
 * (a chat app, a download, a cloud sync) have to compete with a wall of
 * status. The card stops being scannable.
 *
 * The fix is not to hide anything -- every one of these icons is a real
 * running service and stays reachable -- but to put the background ones behind
 * ONE labelled row so the everyday ones are what you see.
 *
 * How an item is judged, in order:
 *
 *   1. An explicit match against the list below, which is the whole reason
 *      this file exists. Guessing from names alone is not reliable enough to
 *      act on silently, so anything not listed here is treated as an app.
 *   2. Everything else is an APP and stays in the main grid.
 *
 * That ordering matters: the default is "this is something you want", so a new
 * daemon that registers an icon tomorrow appears in the main grid and is
 * noticed, rather than disappearing into Advanced because its name happened
 * to contain a lowercase letter. Silence is the worse failure.
 */
Singleton {
    id: root

    // ── The service list ────────────────────────────────────────────────
    //
    // Matched case-insensitively as a SUBSTRING of the item's id, title or
    // tooltip, because these apps are inconsistent about what they register:
    // NetworkManager is "nm-applet" on some systems and
    // "NetworkManager Applet" on others, and the id is the only field
    // guaranteed to exist.
    //
    // Deliberately generous within each family and silent outside it. A false
    // positive costs one extra click on something nobody opens; a false
    // negative puts a status icon back in the main grid.
    readonly property var servicePatterns: [
        // Avahi / mDNS discovery -- an mDNS responder is not a thing you click
        "avahi",
        "avahi-daemon",
        "avahi-browse",

        // NetworkManager's applet and its applets' helpers
        "nm-applet",
        "networkmanager",
        // KDE's applet registers as `org.kde.plasma.networkmanagement` with
        // the title "Network Management" -- no "manager" anywhere in it, so
        // "networkmanager" alone misses the most common network icon on a
        // Plasma desktop. Found by the test harness, not by reading the list.
        "networkmanagement",
        "nmcli",

        // Desktop portals: xdg-desktop-portal, its gtk/qt/kde backends and
        // the per-app portals (flatpak, gvfs). Every GNOME/KDE install runs
        // several; each registers its own icon.
        "xdg-desktop-portal",
        "xdgportal",
        "portal",
        "gnome-shell-portal",
        "kdeconnect",

        // polkit authentication agent
        "polkit",
        "pkexec",

        // power / thermal / hardware daemons
        "upower",
        "powerdevil",
        "powermanagement",
        "thermald",
        "tlp",
        "thinkpad",

        // audio and mixer daemons
        "pavucontrol",
        "pulseaudio",
        "pipewire",
        "wireplumber",
        "rtcwifi",

        // input method frameworks' tray agents
        "fcitx",
        "ibus",
        "kime",
        "scim",

        // display/compositor helper daemons
        "kscreen",
        "kwin",
        "systemd",

        // distro and package tooling that registers an icon while working
        "ccsm",
        "cachyos",
        "kernel-manager",
        "kernelmanager",
        "octopi",
        "yay",
        "paru",
        "pamac",

        // assorted desktop daemons with tray icons on most desktops
        "blueman",
        "bluez",
        "colord",
        "fwupd",
        "gpg-agent",
        "seahorse",
        "cups",
        "nvidia",
        "optimus",
        // NOT a bare "prime". Prime Runner is an ordinary launcher app, and a
        // two-way substring match would file it as service noise -- an everyday
        // icon hidden behind a disclosure, which is the exact failure the
        // "default is app" rule exists to prevent. Only the switcher's own
        // spellings count.
        "prime-select",
        "prime.offload",
    ]

    /**
     * Is this a background service rather than an app?
     *
     * `item` is a SystemTrayItem (id / title / tooltip) or a shell-owned
     * registry entry (cls / name). Both are probed, so one call site covers
     * the tray's two sources without the caller caring which it has.
     */
    function isService(item) {
        if (!item)
            return false;
        const haystack = [item.id, item.title, item.tooltip,
                          item.cls, item.name, item.iconName]
            .filter(v => typeof v === "string" && v.length > 0)
            .join(" ")
            .toLowerCase();
        if (haystack.length === 0)
            return false;
        if (root.matchesExtra(haystack))
            return true;
        for (const pattern of servicePatterns) {
            if (haystack.includes(pattern.toLowerCase()))
                return true;
        }
        return false;
    }

    /**
     * Split a list into the two halves the card renders.
     * Returns { apps, services } -- both new arrays, so the caller can bind
     * two Repeaters to them independently.
     */
    function split(items) {
        const apps = [];
        const services = [];
        for (const item of items || []) {
            (root.isService(item) ? services : apps).push(item);
        }
        return { apps: apps, services: services };
    }

    /**
     * The user's own additions. A comma-separated string in the config, so
     * the list is editable without touching this file:
     *   Config.options.bar.tray.extraServicePatterns
     * Anything matched here is treated as service noise too, which is the
     * escape hatch for the daemon nobody thought of here.
     */
    function extraPatterns() {
        const raw = Config.options?.bar?.tray?.extraServicePatterns ?? "";
        return String(raw)
            .split(",")
            .map(s => s.trim().toLowerCase())
            .filter(s => s.length > 0);
    }

    function matchesExtra(haystack) {
        for (const p of root.extraPatterns()) {
            if (haystack.includes(p))
                return true;
        }
        return false;
    }
}

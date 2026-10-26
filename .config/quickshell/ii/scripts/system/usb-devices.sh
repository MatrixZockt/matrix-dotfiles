#!/usr/bin/env bash
# Every USB device on the machine right now, with the two facts that decide
# whether plugging it in is worth a notice.
#
# WHY THIS EXISTS. The session's drive census asks lsblk, and lsblk only knows
# about BLOCK devices. A phone on the end of a cable, a gamepad, a webcam, a
# headset dongle -- every one of them is a USB device with no /dev node at all,
# so "I get no notification when I plug something in" is literally true of
# them: nothing in the session is looking. This is the other census.
#
# THE ONE FACT THAT SEPARATES A PORT FROM A SOLDER JOINT is `removable`, and it
# is read from sysfs per DEVICE, not guessed from the name. Measured on this
# machine (Razer Blade, 2026-10-14), the discrimination is exact:
#
#   /sys/bus/usb/devices/1-8/removable   -> fixed      Integrated Camera
#   /sys/bus/usb/devices/1-10/removable  -> fixed      the laptop's own keyboard
#   /sys/bus/usb/devices/1-14/removable  -> fixed      the internal Bluetooth
#   /sys/bus/usb/devices/1-12/removable  -> removable  a Samsung phone on a cable
#
# That is the same line the drive census draws between the NVMe and a stick, and
# for the same reason: a notice about hardware nobody moved is noise. A device
# whose port the firmware cannot classify reports `unknown` and is deliberately
# NOT announced -- silence about an unfamiliar port is the honest answer, and
# the alternative (announcing everything) fires on every resume, when the
# internal camera and Bluetooth re-enumerate with the rest of the bus.
#
# HUBS (class 09) ARE SKIPPED. A hub is a splitter: the dock behind it, not the
# hub, is what the hand did, and the hub's children report their own port.
#
# MASS STORAGE (device or interface class 08) IS FLAGGED, NOT FILTERED, because
# the caller has to know it: a stick is already announced by the drive census,
# in more detail (its label, its filesystem, its size), and announcing it twice
# for one plug would be worse than not announcing it here.
#
# OUTPUT (one record per line, pipe separated; no output when nothing is
# plugged in):
#
#   dev|<name>|<product>|<manufacturer>|<removable>|<class>|<mass storage>|<mtp>
#
# `<name>` is the sysfs device name ("1-12"), which is the stable handle: the
# kernel never reuses it while the device is present, and both the caller and
# the check suite address a device by it.
# The tree to read, overridable so the classifier can be asked about devices
# this machine does not have: a USB stick (mass storage, which the caller must
# NOT announce -- the drive census owns it) cannot be plugged in from a script
# any more than a phone can, and "one plug, one notice" is a claim about the
# rule rather than about any port. Point USBROOT at a fixture directory and the
# same code answers for it.
set -u

root="${USBROOT:-/sys/bus/usb/devices}"

for dir in "$root"/*; do
    # idVendor exists on device directories only, but the interface directories
    # carry it too -- the colon test below is what separates them.
    [ -r "$dir/idVendor" ] || continue
    name="${dir##*/}"
    # Interfaces are named "<device>:<config>.<interface>" and describe a
    # function of a device, not the device. One plug is one device.
    case "$name" in
        *:*) continue ;;
    esac
    # Root hubs are named "usb1", "usb2", ...; they are the bus itself.
    case "$name" in
        usb*) continue ;;
    esac

    class="$(cat "$dir/bDeviceClass" 2>/dev/null)"
    # 09 is a hub: a splitter, and the thing behind it is the actual plug.
    [ "$class" = "09" ] && continue

    mass=""
    mtp=""
    for iface in "$dir/$name":*; do
        [ -r "$iface/bInterfaceClass" ] || continue
        iclass="$(cat "$iface/bInterfaceClass" 2>/dev/null)"
        [ "$iclass" = "08" ] && mass=1
        # 06 Still Imaging is what MTP borrows from the camera world -- the same
        # tell scripts/system/mtp-devices.sh mounts phones by.
        [ "$iclass" = "06" ] && mtp=1
    done
    [ "$class" = "08" ] && mass=1

    printf 'dev|%s|%s|%s|%s|%s|%s|%s\n' \
        "$name" \
        "$(cat "$dir/product" 2>/dev/null)" \
        "$(cat "$dir/manufacturer" 2>/dev/null)" \
        "$(cat "$dir/removable" 2>/dev/null)" \
        "$class" \
        "$mass" \
        "$mtp"
done

exit 0

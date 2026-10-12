#!/usr/bin/env bash
# What is connected over MTP right now, and which of those things are mounted.
#
# WHY THIS EXISTS AT ALL. A phone in "File transfer" mode is NOT a disk: it has
# no /dev node, so it never appears in lsblk, and a drive list built on lsblk
# can only ever answer "nothing is plugged in" about it. Which is exactly the
# report this script was written for -- a Samsung on the end of a USB cable,
# invisible to the file manager, because the file manager was asking the kernel
# about block devices and a phone is not one.
#
# So the question is asked where the answer actually lives: sysfs. The one
# thing the kernel does expose about an MTP device is the interface class the
# protocol borrows from the camera world -- 06, Still Imaging. That is what
# `lsusb -t` shows for a Samsung in file-transfer mode, and a PTP camera shows
# the same thing, which is right: a camera's photos are readable through the
# same FUSE mounter.
#
# OUTPUT (one record per line, pipe separated):
#
#   dev|<usb name>|<vendor id>|<product id>|<manufacturer>|<product>
#   mounts|<mount point>          one line per mounted af-mtp-mount
#
# Nothing here opens the device. That is deliberate and load-bearing: MTP is a
# single-session protocol, so a probe that claimed the device would knock the
# mount that is reading it offline. This reads descriptors only.
#
# Exit status: 0 when at least one device was found, 1 when none was -- so a
# caller (and the check suite) can ask "is anything on MTP right now?" without
# parsing anything.
set -u

found=0

# The mounts first: a caller learns which of the devices below is already open
# before it decides anything about them.
awk '$3 == "fuse.aft-mtp-mount" { printf "mounts|%s\n", $2 }' /proc/self/mounts 2>/dev/null

for dir in /sys/bus/usb/devices/*; do
    [ -r "$dir/idVendor" ] || continue
    name="${dir##*/}"
    # Interface directories are named "<device>:<config>.<interface>" and only
    # the colon-less ones describe a whole device.
    case "$name" in
        *:*) continue ;;
    esac

    speaks_mtp=""
    for iface in "$dir/$name":*; do
        [ -r "$iface/bInterfaceClass" ] || continue
        [ "$(cat "$iface/bInterfaceClass" 2>/dev/null)" = "06" ] && speaks_mtp=1
    done
    [ -n "$speaks_mtp" ] || continue

    printf 'dev|%s|%s|%s|%s|%s\n' \
        "$name" \
        "$(cat "$dir/idVendor" 2>/dev/null)" \
        "$(cat "$dir/idProduct" 2>/dev/null)" \
        "$(cat "$dir/manufacturer" 2>/dev/null)" \
        "$(cat "$dir/product" 2>/dev/null)"
    found=1
done

[ "$found" = 1 ] || exit 1
exit 0

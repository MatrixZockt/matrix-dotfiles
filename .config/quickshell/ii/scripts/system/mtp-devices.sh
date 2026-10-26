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
#   mounts|<mount point>|<entries>   one line per mounted af-mtp-mount
#
# ENTRIES IS THE POINT, and it is not decoration: "mounted" and "readable" are
# two different questions for MTP, and an AFT session that was refused storages
# (the phone was locked, or its "allow access to phone data" prompt had not been
# answered yet) mounts a real, perfectly empty directory and answers "nothing"
# for the rest of that session's life -- even after the phone is unlocked. A
# caller that reads a live mount as "the phone is open" shows an empty folder
# about a phone that is full, and never asks again. So the count is reported:
# 0 means the phone is refusing (a fresh session is needed), -1 means the mount
# did not answer at all (a dead FUSE session), and anything above 0 is a phone
# whose contents can be listed.
#
# Nothing here opens the device. That is deliberate and load-bearing: MTP is a
# single-session protocol, so a probe that claimed the device would knock the
# mount that is reading it offline. This reads descriptors only -- and lists a
# directory that some other process is already serving.
#
# Exit status: 0 when at least one device was found, 1 when none was -- so a
# caller (and the check suite) can ask "is anything on MTP right now?" without
# parsing anything.
set -u

found=0

# The mounts first: a caller learns which of the devices below is already open
# before it decides anything about them.
while read -r mtp_mnt; do
    [ -n "$mtp_mnt" ] || continue
    # `ls -A` distinguishes the two failures by its EXIT STATUS: a live but
    # refused session lists nothing and succeeds, a dead one fails. Bounded by
    # a timeout, because a FUSE session whose daemon is wedged blocks a read
    # instead of failing it -- and this script is on the hotplug path.
    if mtp_out="$(timeout 5 ls -A "$mtp_mnt" 2>/dev/null)"; then
        mtp_n="$(printf '%s\n' "$mtp_out" | grep -c '[^[:space:]]')"
    else
        mtp_n=-1
    fi
    printf 'mounts|%s|%s\n' "$mtp_mnt" "$mtp_n"
done < <(awk '$3 == "fuse.aft-mtp-mount" { print $2 }' /proc/self/mounts 2>/dev/null)

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

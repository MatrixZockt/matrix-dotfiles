#!/usr/bin/env bash
# One transfer, one process, one set of progress numbers.
#
# The Files window used to build a shell line out of `gio copy`/`gio move` and
# nothing else: no progress, no shared total, and a GVfs verb that REFUSES a
# directory outright ("Can't recursively copy directory"), so pasting a folder
# onto a USB stick was the case that had a special case bolted onto it.
#
# This script is that special case made general. It takes the whole batch, works
# out the names, moves the bytes, and narrates itself on stdout in lines the QML
# side reads as they arrive:
#
#     BEGIN <total_bytes> <count>
#     ITEM <index> <count> <name>
#     PROGRESS <done_bytes> <total_bytes>
#     SKIP <name>
#     FAIL <message>
#     DONE
#
# A name that is already in the destination is a QUESTION, not a default:
# `file-transfer.sh conflicts DEST SOURCE...` prints `CONFLICT <name> dir|file`
# per collision (and `COUNT <n>`), and the window asks which of replace / keep
# both / skip to use. The answer arrives in ON_CONFLICT -- see the policy block
# below for what each one does to a file and to a folder.
#
# Byte counts are apparent sizes (`du -sb`), which is what rsync reports as
# transferred, so the bar's total and the engine's counter are the same unit.
#
# Naming is the rule Paste has always used: never clobber, land beside as
# "name - copy.ext", then "name - copy (2).ext". Collisions are decided here
# rather than per engine so a copy and a move cannot disagree.
#
# The engine is rsync when it is installed (it reports progress, handles files
# and trees the same way, and copies onto vfat/exfat/ntfs without arguing about
# the permissions those filesystems cannot store); otherwise `cp -a`, which
# still copies but can only report per file rather than per byte.
set -u
export LC_ALL=C

say() { printf '%s\n' "$*"; }

mode=${1:-}
shift 2>/dev/null || true
dest=${1:-}
shift 2>/dev/null || true

if [ -z "$mode" ] || [ -z "$dest" ] || [ "$#" -eq 0 ]; then
    say "FAIL usage: file-transfer.sh copy|move DEST SOURCE..."
    exit 2
fi
case "$mode" in
    copy|move|conflicts) ;;
    *) say "FAIL unknown mode: $mode"; exit 2 ;;
esac
if [ ! -d "$dest" ]; then
    say "FAIL destination is not a folder: $dest"
    exit 2
fi

# ── What happens to a name that is already there ─────────────────────────
# The window asks before it transfers (mode `conflicts` below is that
# question), and hands the answer back in ON_CONFLICT:
#
#   keep     files land beside as "name - copy.ext"; a FOLDER is filled in,
#            i.e. only the names it does not have yet are copied into it
#   replace  the existing name is removed and the incoming item takes it:
#            a file overwrites a file, a folder replaces the whole folder
#   skip     the item is left alone and nothing is copied for it
#
# The default stays `keep`, so a caller that never asks still cannot clobber
# anything -- the rule this script has always had.
policy=${ON_CONFLICT:-keep}
case "$policy" in
    keep|replace|skip) ;;
    *) policy=keep ;;
esac

# ── The collision question, answered without moving a byte ──────────────
# `conflicts DEST SOURCE...` prints one line per source whose name is already
# taken in DEST, then a count, so the window can decide whether to ask before
# it starts a transfer that would have to make the decision for it.
#
#     CONFLICT <name> dir|file
#     COUNT <n>
if [ "$mode" = "conflicts" ]; then
    n=0
    for src in "$@"; do
        [ -e "$src" ] || continue
        name=$(basename -- "$src")
        if [ -e "$dest/$name" ] || [ -L "$dest/$name" ]; then
            if [ -d "$dest/$name" ]; then kind=dir; else kind=file; fi
            say "CONFLICT $name $kind"
            n=$((n + 1))
        fi
    done
    say "COUNT $n"
    exit 0
fi

# ── The name this item will land under ──────────────────────────────────
# Byte-for-byte the rule the paste path always applied, so a file that used to
# arrive as "x - copy.txt" still does.
unique_target() {
    local dst=$1 base=$2 target stem ext i
    target="$dst/$base"
    if [ ! -e "$target" ]; then printf '%s' "$target"; return; fi
    stem=${base%.*}
    ext=${base##*.}
    if [ "$stem" = "$base" ]; then ext=""; else ext=".$ext"; fi
    target="$dst/$stem - copy$ext"
    i=2
    while [ -e "$target" ]; do
        target="$dst/$stem - copy ($i)$ext"
        i=$((i + 1))
    done
    printf '%s' "$target"
}

# ── How many bytes are on the way ───────────────────────────────────────
total=0
sizes=()
for src in "$@"; do
    bytes=$(du -sb -- "$src" 2>/dev/null | cut -f1)
    bytes=${bytes:-0}
    sizes+=("$bytes")
    total=$((total + bytes))
done
say "BEGIN $total $#"

# A filesystem that cannot store unix permissions must not be told about them,
# or rsync answers "chmod ... Operation not supported" and exits non-zero on a
# copy that actually landed.
fstype=$(stat -f -c %T -- "$dest" 2>/dev/null || echo unknown)
fat_opts=()
case "$fstype" in
    vfat|msdos|exfat|ntfs|fuseblk|cifs|smb3|smb2|nfs*)
        fat_opts=(--no-perms --no-owner --no-group --omit-dir-times)
        ;;
esac

have_rsync=0
command -v rsync >/dev/null 2>&1 && have_rsync=1

# ── The bytes ───────────────────────────────────────────────────────────
# $1 src, $2 target, $3 this item's size, $4 bytes already done before it.
# Prints PROGRESS lines as the copy runs; returns the engine's exit code.
copy_bytes() {
    local src=$1 target=$2 size=$3 base=$4 rc=0 line bytes
    # Set by the item loop when a folder is being FILLED rather than copied
    # into a fresh name: never overwrite what is already inside it.
    local merge_opts=()
    [ "${merge_only:-0}" = "1" ] && merge_opts=(--ignore-existing)
    if [ "$have_rsync" -eq 1 ]; then
        # rsync reads a destination that does not exist yet as a folder to fill,
        # so a folder copy has to name the CONTENTS (`src/` into `target/`) or
        # the result is `target/src/...` -- a tree nested one level too deep,
        # which is what the first run of this script did. A file copy still
        # takes the whole path as the file's name, which is what a paste means.
        local from to
        if [ -d "$src" ]; then
            mkdir -p -- "$target" || { say "FAIL $target could not be created"; return 1; }
            from="$src/"; to="$target/"
        else
            from="$src"; to="$target"
        fi
        # --no-inc-recursive is what makes the total honest from the first line:
        # without it rsync counts the file list lazily and the percentage jumps.
        # The \r-to-\n translation is the whole trick of this script: progress2
        # updates one line in place, and a line that never ends is a line the
        # window never sees.
        #
        # The step is a hundredth of the batch (at least 32 KiB), and only a
        # line that MOVED is printed: rsync keeps repeating the same count, and
        # a bar that redraws on an unchanged number is just noise.
        local step prev=0
        step=$((total / 100))
        [ "$step" -lt 32768 ] && step=32768
        # Line-buffered, because rsync writes progress to stderr: through a pipe
        # that is block-buffered, so a burst of updates all arrived at the end
        # and the bar sat at 0% for a whole copy and then jumped to 100%.
        local rsync_cmd=(rsync)
        command -v stdbuf >/dev/null 2>&1 && rsync_cmd=(stdbuf -oL -eL rsync)
        # Progress on stdout, and the REASON on a file of its own. They used to
        # share one stream and the error was lost in it: a copy that failed on
        # an unmountable cluster reported "could not be copied" and nothing
        # else, when rsync had already said exactly which call failed and why.
        local errf
        errf=$(mktemp 2>/dev/null) || errf=""
        "${rsync_cmd[@]}" -a "${fat_opts[@]}" "${merge_opts[@]}" --info=progress2 --no-inc-recursive -- "$from" "$to" \
            2>"${errf:-/dev/null}" |
            tr '\r' '\n' |
            while IFS= read -r line; do
                case "$line" in
                    *[0-9]%*)
                        bytes=$(printf '%s\n' "$line" | awk '{v=$1; gsub(/[^0-9]/,"",v); print v+0; exit}')
                        [ "${bytes:-0}" -gt "$prev" ] 2>/dev/null || continue
                        if [ $((bytes - prev)) -ge "$step" ] || [ "$bytes" -ge "$size" ]; then
                            say "PROGRESS $((base + bytes)) $total"
                            prev=$bytes
                        fi
                        ;;
                esac
            done
        rc=${PIPESTATUS[0]}
        if [ "$rc" -ne 0 ] && [ -n "$errf" ] && [ -s "$errf" ]; then
            say "FAIL $(head -n 1 "$errf" | sed 's/^rsync: //')"
        fi
        [ -n "$errf" ] && rm -f "$errf"
        return "$rc"
    fi
    # No rsync: cp -a copies the same thing, and the bar steps per item.
    # -n is this branch's --ignore-existing (a fill must not overwrite).
    local msg cp_n=()
    [ "${merge_only:-0}" = "1" ] && cp_n=(-n)
    if [ -d "$src" ]; then
        mkdir -p -- "$target" 2>/dev/null
        msg=$(cp -a "${cp_n[@]}" -- "$src"/. "$target"/ 2>&1) || { rc=$?; say "FAIL ${msg:-cp failed}"; return "$rc"; }
    else
        msg=$(cp -a "${cp_n[@]}" -- "$src" "$target" 2>&1) || { rc=$?; say "FAIL ${msg:-cp failed}"; return "$rc"; }
    fi
    say "PROGRESS $((base + size)) $total"
    return 0
}

# ── Each item ───────────────────────────────────────────────────────────
index=0
done_bytes=0
failures=0
for src in "$@"; do
    index=$((index + 1))
    size=${sizes[$((index - 1))]}
    name=$(basename -- "$src")
    say "ITEM $index $# $name"

    if [ ! -e "$src" ]; then
        say "FAIL $name is gone"
        failures=$((failures + 1))
        done_bytes=$((done_bytes + size))
        continue
    fi

    # ── The name this item lands under, and what happens to the one there ──
    # `merge_only` is per item: the next source in the batch must not inherit
    # a folder's fill from the one before it.
    merge_only=0
    collide=0
    if [ -e "$dest/$name" ] || [ -L "$dest/$name" ]; then collide=1; fi

    if [ "$collide" -eq 1 ] && [ "$policy" = "skip" ]; then
        # Asked for, and answered: leave this one exactly as it is.
        say "SKIP $name"
        say "PROGRESS $((done_bytes + size)) $total"
        done_bytes=$((done_bytes + size))
        continue
    fi

    if [ "$collide" -eq 1 ] && [ "$policy" = "replace" ]; then
        # A replace is a replace: the old name goes first, whatever it was
        # (a file onto a folder, a folder onto a bigger folder), so nothing
        # stale is left inside a folder that was supposed to be swapped.
        target="$dest/$name"
        if [ -e "$target" ] || [ -L "$target" ]; then
            if ! rm -rf -- "$target" 2>/dev/null; then
                say "FAIL $name could not be replaced"
                failures=$((failures + 1))
                done_bytes=$((done_bytes + size))
                continue
            fi
        fi
    elif [ "$collide" -eq 1 ] && [ "$policy" = "keep" ] && [ -d "$src" ] && [ -d "$dest/$name" ]; then
        # Folder onto folder, keep both: FILL it -- the names it is missing
        # are copied in, the ones it already has are left untouched.
        target="$dest/$name"
        merge_only=1
    else
        target=$(unique_target "$dest" "$name")
    fi

    same_fs=0
    if [ "$(stat -c %d -- "$src" 2>/dev/null)" = "$(stat -c %d -- "$dest" 2>/dev/null)" ]; then
        same_fs=1
    fi

    # A move inside one filesystem is a rename: no bytes to narrate.
    if [ "$mode" = "move" ] && [ "$same_fs" -eq 1 ]; then
        if mv -- "$src" "$target" 2>/dev/null; then
            say "PROGRESS $((done_bytes + size)) $total"
            say "OK $target"
            done_bytes=$((done_bytes + size))
            continue
        fi
        say "FAIL $name could not be moved"
        failures=$((failures + 1))
        done_bytes=$((done_bytes + size))
        continue
    fi

    if copy_bytes "$src" "$target" "$size" "$done_bytes"; then
        # The move half of a cross-filesystem move: the source only goes once
        # the copy has landed, so an interrupted transfer never loses the file.
        if [ "$mode" = "move" ]; then
            rm -rf -- "$src" || say "FAIL $name copied but the original could not be removed"
        fi
        say "PROGRESS $((done_bytes + size)) $total"
        say "OK $target"
    else
        # A half-written target is not a copy; take it back out.
        [ -e "$target" ] && rm -rf -- "$target" 2>/dev/null
        say "FAIL $name could not be copied"
        failures=$((failures + 1))
    fi
    done_bytes=$((done_bytes + size))
done

say "DONE"
[ "$failures" -eq 0 ] || exit 1
exit 0

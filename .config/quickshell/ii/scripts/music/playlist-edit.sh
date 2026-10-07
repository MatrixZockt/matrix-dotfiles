#!/usr/bin/env bash
# Add a track to a playlist folder, or create a playlist folder.
#
# WHY A SCRIPT AND NOT INLINE QML. MusicPlayer already talks to a helper for
# cover extraction (scripts/music/extract-art.sh) for the same reason: a
# `find`/quoting minefield built as a JS string in QML is unreadable and, when
# it breaks, breaks for every track at once. This one is small, but the name
# handling below is exactly the kind of thing that must not be assembled by
# string concatenation in QML.
#
# THE DATA MODEL IS FOLDERS. A playlist is a directory under
# ~/Music/Spotify and a track is a file inside it, because that is what
# MusicPlayer's scan reads (scanCommand(): `find ... -name '*.mp3'`, grouped
# by the first path segment). So "add this song to that playlist" is "put a
# reference to the file in that directory", and the rescan that follows picks
# it up with no database and no change to playback.
#
# WHY HARDLINK FIRST. These are 125 real MP3s. Copying on every add would
# quietly double the library's disk usage, and a duplicate added twice would
# double it again. `ln` makes a second directory entry for the same inode:
# free, and completely invisible to the scanner and to mpv, both of which only
# ever open paths.
#
# It can fail, though. os.link(2) returns EXDEV across filesystems, so if the
# source track and the playlist ever end up on different mounts the hardlink
# is impossible and the fallback is a real copy. `ln` without -s is used
# deliberately: a symbolic link would be free too, but it dangles the moment
# the original file is moved or the folder is reorganised, and the scanner
# would happily list a track that cannot be played.
#
# Output is ONE status token on stdout, which MusicPlayer turns into a
# property. Keep it a single line: the caller has no parser, only `startsWith`.
set -u

MUSIC_DIR="$HOME/Music/Spotify"

die() { printf 'ERROR %s\n' "$1"; exit 1; }

# A playlist name is a path segment, so it is validated rather than escaped.
# Empty, ".", ".." and anything containing "/" are refused -- without this, a
# name like "../../.config" would let a playlist write land anywhere on disk.
#
# There is deliberately NO NUL check here. The first version had
# `*$'\0'*) die ...` and it rejected EVERY name, including "ZZ-test-tmp":
# bash strings cannot contain a NUL, so $'\0' expands to the empty string and
# the pattern degrades to `**`, which matches everything. A guard that fails
# open in the direction of "rejecting the whole world" looks exactly like the
# feature being broken rather than like a bug in the guard.
check_name() {
    case "$1" in
        "") die "empty name" ;;
        "."|"..") die "reserved name: $1" ;;
        */*) die "name may not contain /" ;;
    esac
    [ "${#1}" -gt 120 ] && die "name too long"
    return 0
}

cmd_add() {
    src="$1"; name="$2"
    check_name "$name"
    [ -f "$src" ] || die "source is not a file: $src"

    dest_dir="$MUSIC_DIR/$name"
    mkdir -p "$dest_dir" || die "cannot create $dest_dir"

    base=$(basename "$src")

    # Duplicate guard. The scanner groups by filename, so a second file with
    # the same name is either invisible or, once renamed, a silent double.
    # Compare by real path so a hardlink to the same inode is also caught.
    [ -e "$dest_dir/$base" ] && { printf 'DUPLICATE %s\n' "$base"; exit 0; }
    for existing in "$dest_dir"/*.mp3; do
        [ -e "$existing" ] || continue
        if [ "$existing" -ef "$src" ]; then printf 'DUPLICATE %s\n' "$base"; exit 0; fi
    done

    if ln "$src" "$dest_dir/$base" 2>/dev/null; then
        printf 'LINKED %s -> %s\n' "$base" "$name"
    elif cp "$src" "$dest_dir/$base" 2>/dev/null; then
        # EXDEV, or a filesystem with no hardlinks. The copy is the fallback
        # that keeps this working rather than failing the add outright.
        printf 'COPIED %s -> %s\n' "$base" "$name"
    else
        die "could not link or copy $base into $name"
    fi
}

cmd_create() {
    name="$1"
    check_name "$name"
    if [ -d "$MUSIC_DIR/$name" ]; then printf 'EXISTS %s\n' "$name"; exit 0; fi
    mkdir -p "$MUSIC_DIR/$name" || die "cannot create $MUSIC_DIR/$name"
    printf 'CREATED %s\n' "$name"
}

case "${1:-}" in
    add)    [ $# -eq 3 ] || die "usage: $0 add <track-path> <playlist>"; cmd_add "$2" "$3" ;;
    create) [ $# -eq 2 ] || die "usage: $0 create <playlist>";         cmd_create "$2" ;;
    *)      die "usage: $0 {add <track-path> <playlist> | create <playlist>}" ;;
esac
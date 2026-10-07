#!/usr/bin/env bash
# Build the login-template index the shell reads.
#
# WHY THIS EXISTS
# ---------------
# services/LoginLayouts.qml used to carry a hand-written copy of the template
# list -- seven entries (classic, corner, minimal, glass, studio, beacon, ops)
# that its own header described as "the source the .js fragments mirror".
# It was not a source, it was a copy, and it drifted: when `sheet` was added
# to the SDDM theme it never reached this list, so the lock screen asked for
# "sheet", found nothing, and silently fell back to `classic`. The login
# screen drew one design and the lock drew another, with no error anywhere --
# exactly the drift this script exists to make impossible.
#
# The fragments in hypr/custom/sddm-theme/layouts/*.js ARE the source. They
# are what set-login-layout.sh composes into active.js and what
# install-sddm-theme.sh bakes into the installed theme, so they are what the
# greeter actually renders. This script reads them and emits the same numbers
# as JSON for the shell, which means changing a login design now changes the
# lock too, with no second edit.
#
# `active.js` is the composed fragment (a copy of the selected template plus
# `activeLayout`), not a template of its own, so it is skipped.
#
# Display metadata the picker needs -- the translated name and the icon --
# is not in the fragments: they describe geometry, not UI chrome. Those stay
# in LoginLayouts.qml as a lookup keyed by slug, with a derived-name fallback,
# because a missing icon must never cost you a working template.
#
#   generate-layout-index.sh            rewrite the JSON
#   generate-layout-index.sh --print    write to stdout instead
set -uo pipefail

SRC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/sddm-theme/layouts"
OUT="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/loginLayouts.json"

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

if [[ ! -d "$SRC_DIR" ]]; then
    echo "generate-layout-index: no such directory: $SRC_DIR" >&2
    exit 1
fi

# Pull one `var name = value` out of a fragment. Prints nothing when the
# fragment leaves the variable out, which is the case the caller's default
# then covers.
read_var() {
    local file="$1" name="$2"
    sed -n "s/^[[:space:]]*var[[:space:]]\+$name[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$file" \
        | head -n1 \
        | sed 's/[[:space:]]*\/\/.*$//; s/[[:space:]]*$//; s/^"//; s/"$//'
}

entries=()
for frag in "$SRC_DIR"/*.js; do
    [[ -e "$frag" ]] || continue
    slug="$(basename "$frag" .js)"
    # The composed file is the current selection, not a selectable template.
    [[ "$slug" == "active" ]] && continue

    align="$(read_var "$frag" align)"
    voff="$(read_var "$frag" verticalOffset)"
    clock="$(read_var "$frag" clockVisible)"
    card="$(read_var "$frag" card)"
    cscale="$(read_var "$frag" clockScale)"
    hud="$(read_var "$frag" hud)"
    sheet="$(read_var "$frag" sheet)"

    # Defaults match Main.qml's own fallbacks in applyLoginFragment(), so a
    # fragment that omits a variable renders the same way on both sides.
    [[ -z "$align"   ]] && align="center"
    [[ -z "$voff"    ]] && voff="0.04"
    [[ -z "$clock"   ]] && clock="true"
    [[ -z "$card"    ]] && card="false"
    [[ -z "$cscale"  ]] && cscale="1.0"
    [[ -z "$hud"     ]] && hud="false"
    [[ -z "$sheet"   ]] && sheet="false"

    # A template that says "neither hud nor sheet nor card nor an offset"
    # is still valid; only a non-numeric offset or scale is worth refusing.
    if ! [[ "$voff" =~ ^-?[0-9.]+$ ]] || ! [[ "$cscale" =~ ^[0-9.]+$ ]]; then
        echo "generate-layout-index: skipping '$slug' (verticalOffset='$voff' clockScale='$cscale')" >&2
        continue
    fi

    entries+=("$(printf '    {"value": "%s", "align": "%s", "verticalOffset": %s, "clockVisible": %s, "card": %s, "clockScale": %s, "hud": %s, "sheet": %s}' \
        "$slug" "$align" "$voff" "$clock" "$card" "$cscale" "$hud" "$sheet")")
done

if [[ ${#entries[@]} -eq 0 ]]; then
    echo "generate-layout-index: no usable fragments in $SRC_DIR" >&2
    exit 1
fi

# Which template is ACTUALLY in force at the greeter.
#
# This is read from active.js -- the composed fragment set-login-layout.sh
# writes -- and not from the shell's own Persistent.states.loginLayout,
# because that is a second, independent record of the same fact and the two
# drift apart: choosing a layout with the script updates active.js and
# nothing else, so the shell went on believing "classic" while the login
# screen drew whatever had just been set. The greeter's own record is the
# one that describes what you actually see at boot, so it is the one the lock
# follows.
active="$(read_var "$SRC_DIR/active.js" activeLayout)"
[[ -z "$active" ]] && active="$(head -n1 "$SRC_DIR/active.js" 2>/dev/null | sed -n 's|^//[[:space:]]*login-layout:[[:space:]]*\([a-z]*\).*$|\1|p')"
[[ -z "$active" ]] && active="classic"

# A greeter pointing at a template that no longer exists would fall back to
# its own shipped arrangement, so say so rather than silently disagreeing.
if ! printf '%s\n' "${entries[@]}" | grep -q "\"value\": \"$active\""; then
    echo "generate-layout-index: warning: active layout '$active' has no fragment" >&2
fi

json="$(
    printf '{\n'
    printf '  "_comment": "GENERATED by scripts/login/generate-layout-index.sh from %s -- do not edit. These are the login screen'"'"'s own layout fragments; the lock screen reads them so the two cannot drift.",\n' "$SRC_DIR"
    printf '  "active": "%s",\n' "$active"
    printf '  "layouts": [\n'
    last=$(( ${#entries[@]} - 1 ))
    for i in "${!entries[@]}"; do
        if (( i < last )); then
            printf '%s,\n' "${entries[$i]}"
        else
            printf '%s\n' "${entries[$i]}"
        fi
    done
    printf '  ]\n'
    printf '}\n'
)"

if (( PRINT_ONLY )); then
    printf '%s\n' "$json"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
# Write-then-move so a reader never sees a half-written index, and skip the
# write entirely when nothing changed so file watchers do not fire for free.
if [[ -f "$OUT" ]] && cmp -s <(printf '%s\n' "$json") "$OUT"; then
    exit 0
fi
tmp="$(mktemp "${OUT}.XXXXXX")" || exit 1
printf '%s\n' "$json" > "$tmp" && mv -f "$tmp" "$OUT"
#!/usr/bin/env bash
# Smoke-tests the SDDM theme in a real QML engine without rebooting or X.
# Catches what qmllint cannot see (duplicate methods, broken bindings) --
# the failure mode that made SDDM silently fall back to the stock greeter.
# Usage: bash ~/.config/hypr/custom/sddm-theme/check/run-check.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$SRC/Main.qml" "$TMP/"
cp -r "$SRC/layouts" "$TMP/layouts" 2>/dev/null || true
# The battery readout and its native module. The plugin itself is built by
# install-sddm-theme.sh into the INSTALLED theme, so it is usually absent here:
# the readout then fails to load, which is exactly the case this harness should
# keep passing -- the login screen must never depend on it.
cp "$SRC/BatteryReadout.qml" "$TMP/" 2>/dev/null || true
cp -r "$SRC/battery" "$TMP/battery" 2>/dev/null || true
cp -r "$DIR/SddmComponents" "$TMP/"
cp "$DIR/harness.qml" "$TMP/"
# Run with a hard timeout; a load failure prints QML errors but the engine
# stays alive, so we judge by what stderr says.
OUT=$(timeout 10 env QT_FORCE_STDERR_LOGGING=1 \
      /usr/lib/qt6/bin/qml -platform offscreen -I "$TMP" "$TMP/harness.qml" 2>&1 || true)
if echo "$OUT" | grep -qiE "duplicate|Cannot assign to non-existent|does not have a property|is not a type|SyntaxError|ReferenceError"; then
    echo "THEME BROKEN:"
    echo "$OUT" | grep -iE "duplicate|Cannot assign|not a type|SyntaxError|ReferenceError" | sort -u
    exit 1
fi
echo "Theme loads clean (qmllint-level + engine-level)."

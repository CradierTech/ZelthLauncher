#!/usr/bin/env bash
# ============================================================================
#  Zelth bundle verifier
#  Checks an archive actually contains what the installers expect, and does
#  NOT contain dev-only files that must never reach a public release.
#
#  Usage:  bash verify-bundle.sh <archive> <platform:linux|windows>
#  Handles paths containing spaces (game version dirs do).
# ============================================================================
set -uo pipefail

ARCHIVE="${1:-}"
PLATFORM="${2:-}"
[ -n "$ARCHIVE" ] || { echo "usage: $0 <archive> <linux|windows>" >&2; exit 2; }
[ -f "$ARCHIVE" ] || { echo "no such file: $ARCHIVE" >&2; exit 2; }
[ -n "$PLATFORM" ] || PLATFORM=linux

case "$ARCHIVE" in
    *.tar.gz|*.tgz) LIST_CMD="tar -tzf" ;;
    *.zip)          LIST_CMD="__ZIP__" ;;
    *) echo "unsupported archive type: $ARCHIVE" >&2; exit 2 ;;
esac

TMP="$(mktemp)"; trap 'rm -f "$TMP" "$TMP.norm"' EXIT

if [ "$LIST_CMD" = "__ZIP__" ]; then
    # -slt gives a clean "Path = " key; column parsing corrupts names with spaces
    7z l -slt "$ARCHIVE" 2>/dev/null | sed -n 's/^Path = //p' | sed 's|^\./||' | sort > "$TMP.norm"
else
    $LIST_CMD "$ARCHIVE" 2>/dev/null | sed 's|^\./||' | sed 's|/$||' | sort > "$TMP.norm"
fi

if [ ! -s "$TMP.norm" ]; then
    echo "FAIL  could not list archive (corrupt or unsupported): $ARCHIVE" >&2
    exit 1
fi

FAIL=0
pass() { printf '  \033[38;5;115mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[38;5;210mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "verifying $ARCHIVE as $PLATFORM ($(wc -l < "$TMP.norm") entries)"

# ---- must be present -------------------------------------------------------
REQUIRED="package.json main.js preload.js renderer.js launcher.js index.html styles.css
zelth zelth.cmd zelth.png zelth-meteor-config.nbt zelth-meteor-theme.nbt
game/libraries game/runtime"
for f in $REQUIRED; do
    grep -qx "$f" "$TMP.norm" && pass "$f" || bad "MISSING: $f"
done

# ---- both game versions ----------------------------------------------------
for v in "zelth Cheats 1.21.11 Fabric" "zelth Prime 1.21.11 fabric"; do
    if grep -q "^game/versions/$v/" "$TMP.norm"; then
        n=$(grep -c "^game/versions/$v/" "$TMP.norm")
        pass "game version: $v ($n files)"
    else
        bad "MISSING game version: $v"
    fi
done

# ---- platform JRE correct, other one absent --------------------------------
if [ "$PLATFORM" = "windows" ]; then
    grep -qx "game/runtime/java-runtime-delta/windows/java-runtime-delta/bin/java.exe" "$TMP.norm" \
        && pass "windows JRE (java.exe)" || bad "MISSING windows JRE java.exe"
    if grep -q '^game/runtime/java-runtime-delta/linux/' "$TMP.norm"; then
        bad "LEAK: linux JRE shipped in a windows bundle"
    else
        pass "no linux JRE leak"
    fi
else
    grep -qx "game/runtime/java-runtime-delta/linux/java-runtime-delta/bin/java" "$TMP.norm" \
        && pass "linux JRE (java)" || bad "MISSING linux JRE java"
    if grep -q '^game/runtime/java-runtime-delta/windows/' "$TMP.norm"; then
        bad "LEAK: windows JRE shipped in a linux bundle"
    else
        pass "no windows JRE leak"
    fi
fi

# ---- dev-only files must NEVER be in a published bundle --------------------
FORBIDDEN="CHEATS.md install.bin zelth.bin zelthpack zelth_theme.py zelth.desktop
package-lock.json .gitignore .git"
for f in $FORBIDDEN; do
    grep -qx "$f" "$TMP.norm" && bad "LEAK: dev-only file present: $f" || pass "no $f"
done

if grep -q '^installer/' "$TMP.norm"; then bad "LEAK: installer/ inside bundle"; else pass "no installer/ inside bundle"; fi
if grep -q '^node_modules/' "$TMP.norm"; then bad "LEAK: node_modules/ inside bundle"; else pass "no node_modules/ inside bundle"; fi

echo
[ "$FAIL" = "0" ] && printf '\033[38;5;151m%s verified clean\033[0m\n' "$PLATFORM" \
                 || printf '\033[38;5;210m%s -- %d PROBLEM(S)\033[0m\n' "$PLATFORM" "$FAIL"
exit "$FAIL"

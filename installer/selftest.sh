#!/usr/bin/env bash
# ============================================================================
#  Zelth installer - regression suite
#  Usage:  bash selftest.sh [path/to/install.sh]
# ============================================================================
#
#  Builds a throwaway bundle, serves it over localhost, and exercises every
#  code path of install.sh against a fake $HOME so your real system is never
#  touched. Safe to run repeatedly.

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh}"
WORK="${TMPDIR:-/tmp}/zelth-selftest.$$"
PORT="${ZELTH_SELFTEST_PORT:-8877}"
REAL_SRC="${ZELTH_SELFTEST_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

PASS=0
FAIL=0
cleanup() { rm -rf "$WORK"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM

chk() { if [ "$1" = "0" ]; then printf '  \033[38;5;115mPASS\033[0m  %s\n' "$2"; PASS=$((PASS+1));
        else printf '  \033[38;5;210mFAIL\033[0m  %s\n' "$2"; FAIL=$((FAIL+1)); fi; }
hdr() { printf '\n\033[1m-- %s --\033[0m\n' "$1"; }

# ---------------------------------------------------------------- fixture ---
mkdir -p "$WORK/pub" "$WORK/src/game/versions/zelth Prime 1.21.11 fabric"
(
  cd "$WORK/src"
  for f in package.json main.js index.html styles.css renderer.js preload.js launcher.js; do
      echo "/* selftest stub $f */" > "$f"
  done
  printf '#!/usr/bin/env bash\necho zelth\n' > zelth; chmod +x zelth
  printf '\x89PNG\r\n\x1a\n-selftest-icon' > zelth.png
  echo '{"name":"zelth","version":"0.0.0-selftest","main":"main.js"}' > package.json
  # a world shipped in the bundle, so upgrade precedence can be asserted
  mkdir -p "game/versions/zelth Prime 1.21.11 fabric/saves/BundledWorld"
  echo BUNDLE2 > "game/versions/zelth Prime 1.21.11 fabric/saves/BundledWorld/level.dat"
  tar -czf "$WORK/pub/zelth-latest.tar.gz" .
)
( cd "$WORK/pub" && sha256sum zelth-latest.tar.gz > SHA256SUMS )
cat > "$WORK/pub/manifest.json" <<'EOF'
{ "version": "9.9.9", "bundle": "zelth-latest.tar.gz", "electron": "33.4.11" }
EOF

if command -v python3 >/dev/null 2>&1; then
  ( cd "$WORK/pub" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
  SRV_PID=$!
  sleep 2
fi
BASE="http://127.0.0.1:$PORT"
if [ -n "$SRV_PID" ] && curl -fsS --connect-timeout 5 -o /dev/null "$BASE/manifest.json" 2>/dev/null; then
  HAVE_HTTP=1
else
  HAVE_HTTP=0
  SRV_PID=""
  printf '\033[38;5;223m!\033[0m no local HTTP server - remote tests will be skipped\n'
fi

fh() { rm -rf "$WORK/home"; mkdir -p "$WORK/home"; }

# ------------------------------------------------------------------ tests ---
hdr "static"
bash -n "$SCRIPT" >/dev/null 2>&1; chk $? "bash -n $SCRIPT"
if command -v python3 >/dev/null 2>&1 && [ -f "$(dirname "$SCRIPT")/check_printf.py" ]; then
  python3 "$(dirname "$SCRIPT")/check_printf.py" "$SCRIPT" >/dev/null; chk $? "printf arg/format balance"
fi

hdr "argument handling"
bash "$SCRIPT" --help    >/dev/null 2>&1; chk $? "--help exits 0"
bash "$SCRIPT" --version >/dev/null 2>&1; chk $? "--version exits 0"
bash "$SCRIPT" --bogus   >/dev/null 2>&1; [ $? = 2 ]; chk $? "unknown flag exits 2"

hdr "dry run leaves no trace"
fh
HOME="$WORK/home" bash "$SCRIPT" --from "$REAL_SRC" --dir "$WORK/home/z" \
      --dry-run --no-electron --no-desktop --no-cli >/dev/null 2>&1; chk $? "dry-run (local source) exits 0"
[ -z "$(find "$WORK/home" -mindepth 1 2>/dev/null)" ]; chk $? "dry-run wrote nothing"

if [ "$HAVE_HTTP" = "1" ]; then
  fh
  HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z" --dry-run >/dev/null 2>&1
  chk $? "dry-run (remote) exits 0"
  [ -z "$(find "$WORK/home" -mindepth 1 2>/dev/null)" ]; chk $? "dry-run (remote) wrote nothing"

  hdr "remote install"
  fh
  HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z" \
        --no-electron --force --no-cache >/dev/null 2>&1; chk $? "install exits 0"
  [ -f "$WORK/home/z/package.json" ];      chk $? "package.json staged"
  [ -f "$WORK/home/z/launcher.js" ];       chk $? "launcher.js staged"
  [ -d "$WORK/home/z/game/versions" ];     chk $? "game data staged"
  [ -x "$WORK/home/z/uninstall.sh" ];      chk $? "uninstaller written and executable"
  [ -f "$WORK/home/.local/share/applications/zelth.desktop" ]; chk $? "desktop entry written"
  [ -L "$WORK/home/.local/bin/zelth" ];    chk $? "cli symlink created"
  grep -q 'version.*9\.9\.9' /dev/null 2>/dev/null

  hdr "manifest override"
  grep -q 'Zelth is ready' /dev/null 2>/dev/null
  out="$(HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z2" --no-electron --force 2>&1)"
  printf '%s' "$out" | grep -q '9\.9\.9'; chk $? "version taken from manifest.json"
  printf '%s' "$out" | grep -q 'sha256'; chk $? "checksum verified against SHA256SUMS"

  hdr "reinstall"
  # a world the player created, plus a diverged copy of the bundled one
  SV="$WORK/home/z/game/versions/zelth Prime 1.21.11 fabric/saves"
  mkdir -p "$SV/MyWorld"
  echo REAL    > "$SV/MyWorld/level.dat"
  echo BUNDLE1 > "$SV/BundledWorld/level.dat"
  HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z" \
        --no-electron --force >/dev/null 2>&1; chk $? "reinstall exits 0"
  [ -d "$WORK/home/z.prev" ]; chk $? "previous install kept as .prev"

  hdr "saves survive an upgrade"
  SV2="$WORK/home/z/game/versions/zelth Prime 1.21.11 fabric/saves"
  [ -f "$SV2/MyWorld/level.dat" ]; chk $? "player world survived reinstall"
  [ "$(cat "$SV2/MyWorld/level.dat" 2>/dev/null)" = "REAL" ]; chk $? "world contents intact"
  # the freshly-extracted bundle ships BUNDLE2; the old install's BUNDLE1 must win
  [ "$(cat "$SV2/BundledWorld/level.dat" 2>/dev/null)" = "BUNDLE1" ]; chk $? "existing saves win over the new bundle"

  hdr "--no-preserve-saves opts out"
  HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z" \
        --no-electron --force --no-preserve-saves >/dev/null 2>&1
  [ $? = 0 ]; chk $? "reinstall with --no-preserve-saves exits 0"
  SV3="$WORK/home/z/game/versions/zelth Prime 1.21.11 fabric/saves"
  [ ! -d "$SV3/MyWorld" ]; chk $? "opt-out wipes the world (as documented)"

  hdr "launch control"
  HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z" \
        --no-electron --force --no-launch >/dev/null 2>&1
  [ $? = 0 ]; chk $? "--no-launch installs cleanly"
  grep -q 'no-launch' <(HOME="$WORK/home" bash "$SCRIPT" --help 2>&1); chk $? "--no-launch documented in --help"

  hdr "integrity"
  cp "$WORK/pub/zelth-latest.tar.gz" "$WORK/pub/keep.tgz"
  printf 'tamper' >> "$WORK/pub/zelth-latest.tar.gz"
  fh
  HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z" \
        --no-electron --force --no-cache >/dev/null 2>&1
  [ $? != 0 ]; chk $? "corrupt bundle aborts non-zero"
  [ ! -d "$WORK/home/z" ]; chk $? "nothing installed from corrupt bundle"
  mv -f "$WORK/pub/keep.tgz" "$WORK/pub/zelth-latest.tar.gz"

  hdr "uninstall"
  fh
  HOME="$WORK/home" bash "$SCRIPT" --channel "$BASE" --dir "$WORK/home/z" \
        --no-electron --force --no-cache >/dev/null 2>&1
  HOME="$WORK/home" bash "$SCRIPT" --uninstall --dir "$WORK/home/z" >/dev/null 2>&1
  chk $? "uninstall exits 0"
  [ ! -e "$WORK/home/z" ]; chk $? "install dir removed"
  [ ! -L "$WORK/home/.local/bin/zelth" ]; chk $? "cli symlink removed (no dangling link)"
  [ ! -e "$WORK/home/.local/share/applications/zelth.desktop" ]; chk $? "desktop entry removed"
fi

hdr "local source install"
if [ -f "$REAL_SRC/package.json" ]; then
  fh
  HOME="$WORK/home" bash "$SCRIPT" --from "$REAL_SRC" --dir "$WORK/home/z" \
        --no-electron --no-desktop --no-cli --force >/dev/null 2>&1; chk $? "install from --from exits 0"
  [ -f "$WORK/home/z/main.js" ]; chk $? "app files copied"
  [ ! -d "$WORK/home/z/installer" ]; chk $? "dev-only dirs excluded"
else
  printf '  \033[38;5;103mSKIP\033[0m  no source tree at %s\n' "$REAL_SRC"
fi

printf '\n'
if [ "$FAIL" = "0" ]; then
  printf '\033[38;5;151m%d passed, 0 failed\033[0m\n' "$PASS"
else
  printf '\033[38;5;210m%d passed, %d FAILED\033[0m\n' "$PASS" "$FAIL"
fi
[ "$FAIL" = "0" ]

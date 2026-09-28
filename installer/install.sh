#!/usr/bin/env bash
# ============================================================================
#  Zelth Launcher - One-Shot Installer
# ============================================================================
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/install.sh | bash
#    curl -fsSL https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/install.sh | bash -s -- --help
#
#  What it does:
#    1. Pre-flight checks (arch, disk, network, deps)
#    2. Fetches the Zelth bundle (app + game data) with checksum verification
#    3. Installs Electron with NO sudo and NO npm (prebuilt binary)
#    4. Stages everything into ~/.local/share/zelth
#    5. Registers a .desktop entry, icon and ~/.local/bin/zelth CLI shim
#    6. Writes an uninstall.sh next to the app
#
#  This script never modifies the launcher UI.
# ============================================================================

set -uo pipefail

# ============================================================================
#  CONFIG  (edit these, or override with env vars before running)
# ============================================================================
ZELTH_VERSION="${ZELTH_VERSION:-3.0.0}"
ZELTH_CHANNEL="${ZELTH_CHANNEL:-stable}"
ZELTH_REPO="${ZELTH_REPO:-CradierTech/ZelthLauncher}"
ELECTRON_VERSION="${ELECTRON_VERSION:-33.4.11}"
INSTALL_DIR="${ZELTH_DIR:-$HOME/.local/share/zelth}"
BUNDLE_NAME="${ZELTH_BUNDLE:-zelth-latest-linux.tar.gz}"
APP_NAME="Zelth"
APP_ID="zelth"
# ============================================================================

# ---- resolved later -------------------------------------------------------
DIST_URL=""
BUNDLE_URL=""
MANIFEST_URL=""
SRC_DIR=""
DO_ELECTRON=1
DO_SAVES=1
DO_LAUNCH=1
DO_DESKTOP=1
DO_CLI=1
DO_VERIFY=1
DO_UNINSTALL=0
DO_HELP=0
SHOW_VERSION=0
FORCE=0
KEEP_CACHE=1
DRY_RUN=0
TMPDIR_Z=""
FETCHED_TARBALL=""
CACHE_DIR="$HOME/.cache/zelth"

# ============================================================================
#  BILINGUAL  (English / Português)
# ============================================================================
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US.UTF-8}}}" in
    pt*|PT*) LANG_SEL=pt ;;
    *)      LANG_SEL=en ;;
esac

# ============================================================================
#  UI  -  "moonlit night" palette
# ============================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
    C_MOON=$'\033[38;5;189m'    # #cdd6f4
    C_TEXT=$'\033[38;5;188m'    # #bac2de
    C_MUTED=$'\033[38;5;103m'   # #6c7086
    C_GOLD=$'\033[38;5;222m'    # #f9e2af
    C_BLUE=$'\033[38;5;111m'    # #89b4fa
    C_TEAL=$'\033[38;5;115m'    # #94e2d5
    C_GREEN=$'\033[38;5;151m'   # #a6e3a1
    C_PEACH=$'\033[38;5;223m'   # #fab387
    C_RED=$'\033[38;5;210m'     # #f38ba8
    C_VIOLET=$'\033[38m;5;141m' # #b4befe
    C_RESET=$'\033[0m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_MOON=""; C_TEXT=""; C_MUTED=""; C_GOLD=""; C_BLUE=""; C_TEAL=""
    C_GREEN=""; C_PEACH=""; C_RED=""; C_VIOLET=""
fi

# unicode glyphs degrade gracefully
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_UNICODE:-}" ]; then
    G_MOON="☾"; G_DOT="·"; G_OK="✔"; G_WARN="▲"; G_ERR="✖"; G_INFO="i"
    G_ARROW="❯"; G_SEP="─"
else
    G_MOON=""; G_DOT="*"; G_OK="+"; G_WARN="!"; G_ERR="x"; G_INFO="-"
    G_ARROW=">"; G_SEP="-"
fi

t() { # t <en> <pt>
    if [ "$LANG_SEL" = "pt" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# ---- primitive printers ---------------------------------------------------
c_moon()  { printf '%s%s%s %s%s\n'   "$C_MOON"  "$G_MOON" "$C_RESET" "$C_MOON"  "$*"; }
c_gold()  { printf '%s\n' "$C_GOLD$*${C_RESET}"; }
c_blue()  { printf '%s\n' "$C_BLUE$*${C_RESET}"; }
c_teal()  { printf '%s\n' "$C_TEAL$*${C_RESET}"; }
c_green() { printf '%s%s%s %s%s\n'   "$C_GREEN" "$G_OK"   "$C_RESET" "$C_GREEN" "$*"; }
c_warn()  { printf '%s%s%s %s%s\n'   "$C_PEACH" "$G_WARN" "$C_RESET" "$C_PEACH" "$*"; }
c_err()   { printf '%s%s%s %s%s\n'   "$C_RED"   "$G_ERR"  "$C_RESET" "$C_RED"   "$*" >&2; }
c_info()  { printf '%s%s%s %s%s\n'   "$C_BLUE"  "$G_INFO" "$C_RESET" "$C_TEXT"  "$*"; }
c_muted() { printf '%s\n' "$C_MUTED$*${C_RESET}"; }
c_skip()  { printf '%s\n' "$C_MUTED$G_DOT $*${C_RESET}"; }

rule() {
    local w i=0 line=""
    w="$(tty_cols 2>/dev/null || echo 64)"
    [ -z "$w" ] && w=64
    while [ $i -lt "$w" ]; do line="$line$G_SEP"; i=$((i+1)); done
    RULE="$line"
    printf '%s%s%s\n' "$C_MUTED" "$RULE" "$C_RESET"
}

tty_cols() {
    if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
        tput cols 2>/dev/null
    else
        echo 64
    fi
}

section() {
    printf '\n'
    printf '%s%s%s %s%s%s\n' "$C_MOON" "$G_MOON" "$C_RESET" "$C_BOLD$C_MOON" "$*" "$C_RESET"
    rule
}

step()  { printf '%s%s %s%s%s\n' "$C_GOLD" "$G_ARROW" "$C_RESET" "$C_TEXT" "$*"; }
ok()    { printf '%s%s %s%s%s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$C_GREEN" "$*"; }
warn()  { printf '%s%s %s%s%s\n' "$C_PEACH" "$G_WARN" "$C_RESET" "$C_PEACH" "$*"; }
fail()  { c_err "$*"; exit 1; }
have()  { printf '%s%s %s%s%s\n' "$C_TEAL" "$G_OK" "$C_RESET" "$C_TEAL" "$*"; }

die() { c_err "$*"; cleanup; exit 1; }

banner() {
    printf '%s' "$C_VIOLET"
    cat <<'EOF'
      ▄▄▄▄▄▄   ▄▄▄▄▄▄
     █      █ █      █
    █   ███  █ █   ███  █
    █   ███  █ █   ███  █
     █      █ █      █
      ▀▀▀▀▀▀   ▀▀▀▀▀▀
EOF
    printf '%s' "$C_RESET"
    printf '%s%sZelth%s %s·%s %sInstaller %sv%s%s %s·%s %sLinux%s\n' \
        "$C_BOLD" "$C_MOON" "$C_RESET" \
        "$C_MUTED" "$C_RESET" "$C_MOON" \
        "$C_GOLD" "$ZELTH_VERSION" "$C_RESET" \
        "$C_MUTED" "$C_RESET" "$C_MOON" "$C_RESET"
    rule >/dev/null
    printf '%s%s%s\n' "$C_MUTED" "$RULE" "$C_RESET"
}

# ============================================================================
#  ARGUMENT PARSING
# ============================================================================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)          DO_HELP=1 ;;
            -v|--version)       SHOW_VERSION=1 ;;
            -u|--uninstall)     DO_UNINSTALL=1 ;;
            --from)             SRC_DIR="${2:-}"; shift ;;
            --from=*)           SRC_DIR="${1#*=}" ;;
            --dir)              INSTALL_DIR="${2:-}"; shift ;;
            --dir=*)            INSTALL_DIR="${1#*=}" ;;
            --channel)          ZELTH_CHANNEL="${2:-}"; shift ;;
            --channel=*)        ZELTH_CHANNEL="${1#*=}" ;;
            --electron-version) ELECTRON_VERSION="${2:-}"; shift ;;
            --electron-version=*) ELECTRON_VERSION="${1#*=}" ;;
            --bundle)           BUNDLE_NAME="${2:-}"; shift ;;
            --bundle=*)         BUNDLE_NAME="${1#*=}" ;;
            --repo)             ZELTH_REPO="${2:-}"; shift ;;
            --repo=*)           ZELTH_REPO="${1#*=}" ;;
            --no-preserve-saves) DO_SAVES=0 ;;
            --no-launch)        DO_LAUNCH=0 ;;
            --no-electron)      DO_ELECTRON=0 ;;
            --no-desktop)       DO_DESKTOP=0 ;;
            --no-cli)           DO_CLI=0 ;;
            --no-verify)        DO_VERIFY=0 ;;
            --no-cache)         KEEP_CACHE=0 ;;
            --force|-f)         FORCE=1 ;;
            --dry-run)          DRY_RUN=1 ;;
            --lang)             LANG_SEL="${2:-en}"; shift ;;
            --lang=*)           LANG_SEL="${1#*=}" ;;
            --)                 shift; break ;;
            *)
                c_err "$(t "Unknown option" "Opcao desconhecida"): $1"
                c_muted "$(t "Try --help" "Tente --help")"
                exit 2
                ;;
        esac
        shift
    done
}

usage() {
    banner
    cat <<EOF

${C_BOLD}${C_MOON}USAGE${C_RESET}
  ${C_BLUE}curl -fsSL https://raw.githubusercontent.com/${ZELTH_REPO}/main/installer/install.sh | bash${C_RESET}
  ${C_BLUE}curl -fsSL .../install.sh | bash -s -- [options]${C_RESET}

${C_BOLD}${C_MOON}OPTIONS${C_RESET}
  ${C_GOLD}--from <dir>${C_RESET}        install from a local folder (no download)
  ${C_GOLD}--dir <path>${C_RESET}         install location        (default: ~/.local/share/zelth)
  ${C_GOLD}--uninstall${C_RESET}          remove the installation completely
  ${C_GOLD}--channel <name>${C_RESET}    stable | beta | nightly   (default: stable)
  ${C_GOLD}--repo <owner/name>${C_RESET} source repository
  ${C_GOLD}--bundle <file>${C_RESET}      bundle tarball name    (default: ${BUNDLE_NAME})
  ${C_GOLD}--electron-version <x.y.z>${C_RESET}
  ${C_GOLD}--no-electron${C_RESET}       skip the Electron runtime
  ${C_GOLD}--no-desktop${C_RESET}        skip .desktop + icon registration
  ${C_GOLD}--no-cli${C_RESET}           skip the ~/.local/bin/zelth symlink
  ${C_GOLD}--no-verify${C_RESET}         skip checksum verification
  ${C_GOLD}--no-preserve-saves${C_RESET} wipe existing game saves on upgrade (default: keep them)
  ${C_GOLD}--no-launch${C_RESET}        install only, do not start the launcher
  ${C_GOLD}--no-cache${C_RESET}          re-download even if cached
  ${C_GOLD}--lang <en|pt>${C_RESET}      force UI language
  ${C_GOLD}--force${C_RESET}             overwrite an existing install without asking
  ${C_GOLD}--dry-run${C_RESET}           show what would happen, change nothing
  ${C_GOLD}-h, --help${C_RESET}           this screen
  ${C_GOLD}-v, --version${C_RESET}        print version

${C_BOLD}${C_MOON}ENVIRONMENT${C_RESET}
  ${C_MUTED}ZELTH_VERSION ZELTH_CHANNEL ZELTH_REPO ZELTH_DIR ZELTH_BUNDLE ELECTRON_VERSION
  ${C_MUTED}NO_COLOR  NO_UNICODE${C_RESET}

${C_BOLD}${C_MOON}INSTALLS INTO${C_RESET}
  ${C_TEXT}$INSTALL_DIR${C_RESET}                    launcher + Electron + game
  ${C_TEXT}$HOME/.local/bin/zelth${C_RESET}                 command line shim
  ${C_TEXT}$HOME/.local/share/applications/zelth.desktop${C_RESET}
  ${C_TEXT}$HOME/.local/share/icons/hicolor/512x512/apps/zelth.png${C_RESET}
  ${C_TEXT}$HOME/.cache/zelth/${C_RESET}                    download cache

${C_BOLD}${C_MOON}NEEDS${C_RESET}
  ${C_TEXT}x86_64 or aarch64 Linux, bash, curl, tar, ~1.5 GB free, internet.
  ${C_TEXT}No root. No npm. No Node.js.${C_RESET}
  ${C_MUTED}Java is bundled inside the launcher (game/runtime).${C_RESET}

EOF
}

cleanup() {
    [ -n "$TMPDIR_Z" ] && [ -d "$TMPDIR_Z" ] && rm -rf "$TMPDIR_Z"
    return 0
}
trap cleanup EXIT INT TERM

# ============================================================================
#  UTILITIES
# ============================================================================
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# progress bar only when a human is watching
if [ -t 2 ]; then RSYNC_PROGRESS="--info=progress2"; else RSYNC_PROGRESS=""; fi

sha256_of() {
    if have_cmd sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif have_cmd shasum;  then shasum -a 256 "$1" | awk '{print $1}'
    else echo ""; fi
}

human_size() {
    local b="${1:-0}"
    if have_cmd numfmt; then numfmt --to=iec --suffix=B "$b" 2>/dev/null && return; fi
    awk -v b="$b" 'BEGIN{ split("B KiB MiB GiB TiB",u," "); i=1;
        while (b>=1024 && i<5) { b/=1024; i++ } printf "%.1f %s\n", b, u[i] }'
}

free_mb() {
    local d
    d="$(dirname "$INSTALL_DIR")"
    [ -d "$d" ] || d="$HOME"
    df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}'
}

confirm() { # confirm <prompt>
    if [ "$FORCE" = "1" ]; then return 0; fi
    if [ ! -t 0 ]; then return 0; fi
    local a
    printf '%s %s%s%s [%sY/n%s] ' "$C_GOLD" "$G_ARROW" "$C_RESET" "$1" "$C_MOON" "$C_RESET"
    read -r a || return 0
    case "$a" in ""|y|Y|yes|s|S|si|sim) return 0 ;; *) return 1 ;; esac
}

# curl wrapper: progress bar on a tty, quiet otherwise
fetch() { # fetch <url> <outfile> [extra curl args...]
    local url="$1" out="$2"; shift 2
    if [ -t 1 ]; then
        curl -fL --progress-bar --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$@" "$url"
    else
        curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$@" "$url"
    fi
}

# ============================================================================
#  PREFLIGHT
# ============================================================================
detect_distro() {
    local id="" ver="" like=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null
        id="${ID:-}"; ver="${VERSION_ID:-}"; like="${ID_LIKE:-}"
    fi
    case "$like" in *nixos*) DIST_FAMILY="nixos" ;; esac
    case "$id" in
        nixos)            DIST_FAMILY="nixos" ;;
        steamos|bazzite)  DIST_FAMILY="immutable-steamos" ;;
        fedora|silverblue|kinoite|bluefin) DIST_FAMILY="immutable-rpm" ;;
        arch|endeavouros|garuda|cachyos|manjaro) DIST_FAMILY="arch" ;;
        debian|ubuntu|pop|zorin|linuxmint|elementary|kali) DIST_FAMILY="debian" ;;
        fedora|rhel|centos) DIST_FAMILY="fedora" ;;
        opensuse*|suse)   DIST_FAMILY="suse" ;;
        flatcar)          DIST_FAMILY="immutable-flatcar" ;;
        alpine)           DIST_FAMILY="alpine" ;;
        void)             DIST_FAMILY="void" ;;
        gentoo)           DIST_FAMILY="gentoo" ;;
        *)                DIST_FAMILY="unknown" ;;
    esac
    DIST_ID="${id:-linux}"; DIST_VER="${ver:-?}"
}

# immutable distros cannot install system packages; we use zero system packages
# so we only need to know them for the advisory footer.
IMMUTABLE=0

preflight() {
    section "$(t 'PRE-FLIGHT' 'PRE-VERIFICACAO')"

    # --- shell / os ---
    if have_cmd bash; then
        have "bash ${BASH_VERSION%%(*}"
    else
        fail "$(t 'bash 4+ is required' 'bash 4+ e obrigatorio')"
    fi

    case "$(uname -s)" in
        Linux) have "Linux $(uname -r)" ;;
        *)     warn "$(t "Unexpected platform $(uname -s) - trying anyway" "Plataforma inesperada $(uname -s) - tentando assim mesmo")" ;;
    esac

    # --- arch ---
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)  ARCH_OK=1; have "x86_64" ;;
        aarch64|arm64) ARCH_OK=1; have "aarch64" ;;
        *)             ARCH_OK=0; fail "$(t "Unsupported CPU: $ARCH" "CPU nao suportada: $ARCH")" ;;
    esac
    ELECTRON_ARCH="$( [ "$ARCH" = "aarch64" ] && echo arm64 || echo x64 )"

    # --- root ---
    if [ "$(id -u)" = "0" ]; then
        warn "$(t 'Running as root - installing into /root' 'Rodando como root - instalando em /root')"
    fi

    # --- distro ---
    detect_distro
    case "$DIST_FAMILY" in
        immutable-*|flatcar) IMMUTABLE=1 ;;
    esac
    c_info "$(t "Distro: $DIST_ID $DIST_VER ($DIST_FAMILY)" "Distro: $DIST_ID $DIST_VER ($DIST_FAMILY)")"
    if [ "$IMMUTABLE" = "1" ]; then
        c_green "$(t 'Immutable distro detected - using the zero-sudo path' 'Distro imutavel detectada - usando o caminho sem sudo')"
    fi

    # --- required tools ---
    local missing=""
    have_cmd curl  || missing="$missing curl"
    have_cmd tar   || missing="$missing tar"
    have_cmd sha256sum || have_cmd shasum || missing="$missing sha256sum|shasum"
    if [ -n "$missing" ]; then
        warn "$(t "Missing:$missing" "Faltando:$missing")"
        if [ "$IMMUTABLE" = "1" ]; then
            fail "$(t 'Install them with your package manager and re-run' 'Instale-os com seu gerenciador e rode de novo')"
        fi
        fail "$(t 'Install them and re-run this script' 'Instale-os e rode este script de novo')"
    fi
    have "curl, tar, sha256"
    have_cmd unzip >/dev/null 2>&1 && have "unzip (electron)" || c_skip "unzip $(t '(optional, for .zip bundles)' '(opcional, para bundles .zip)')"
    have_cmd python3 >/dev/null 2>&1 && have "python3 (manifest)" || c_skip "python3 $(t '(optional)' '(opcional)')"

    # --- network ---
    step "$(t 'Checking network' 'Verificando rede')..."
    if [ -n "$SRC_DIR" ]; then
        c_skip "$(t 'local source, network not needed' 'fonte local, rede nao necessaria')"
    else
        local host="github.com"
        if curl -fsS --connect-timeout 8 -o /dev/null "https://$host" 2>/dev/null; then
            have "network $(t 'ok' 'ok') (github.com reachable)"
        elif curl -fsS --connect-timeout 8 -o /dev/null "https://api.github.com" 2>/dev/null; then
            have "network $(t 'ok' 'ok') (api.github.com reachable)"
        else
            fail "$(t 'No internet connection' 'Sem conexao com a internet')"
        fi
    fi

    # --- disk ---
    local need=1200 have_mb
    have_mb="$(free_mb)"
    if [ -n "$have_mb" ] && [ "$have_mb" -lt "$need" ]; then
        fail "$(t "Not enough disk space: $(human_size $((have_mb*1024))) free, need 1.2 GB" "Espaco insuficiente: $(human_size $((have_mb*1024))) livres, precisa de 1.2 GB")"
    elif [ -n "$have_mb" ]; then
        have "$(t 'Disk: free' 'Disco: livres') $(human_size $((have_mb*1024)))"
    else
        c_skip "$(t 'disk space unknown' 'espaco em disco desconhecido')"
    fi

    # --- existing install ---
    if [ -d "$INSTALL_DIR" ] && [ "$DO_UNINSTALL" = "0" ]; then
        c_warn "$(t "Existing installation found:" "Instalacao existente encontrada:") $INSTALL_DIR"
        if [ "$DRY_RUN" = "1" ]; then
            c_skip "$(t '[dry-run] would move it to' '[dry-run] seria movido para') $INSTALL_DIR.prev"
            return 0
        fi
        if confirm "$(t 'Overwrite it?' 'Sobrescrever?')"; then
            step "$(t 'Backing up to' 'Fazendo backup em') $INSTALL_DIR.prev"
            rm -rf "$INSTALL_DIR.prev"
            mv "$INSTALL_DIR" "$INSTALL_DIR.prev"
            ok "$(t 'Previous install saved to' 'Instalacao anterior salva em') $INSTALL_DIR.prev"
        else
            die "$(t 'Aborted by user' 'Cancelado pelo usuario')"
        fi
    fi
}

# ============================================================================
#  BUNDLE FETCH
# ============================================================================
resolve_dist_url() {
    case "$ZELTH_CHANNEL" in
        nightly)
            DIST_URL="https://github.com/${ZELTH_REPO}/releases/download/nightly"
            ;;
        beta)
            DIST_URL="https://github.com/${ZELTH_REPO}/releases/download/beta"
            ;;
        stable|"")
            DIST_URL="https://github.com/${ZELTH_REPO}/releases/latest/download"
            ;;
        *)
            DIST_URL="$ZELTH_CHANNEL"
            ;;
    esac
    BUNDLE_URL="$DIST_URL/$BUNDLE_NAME"
    MANIFEST_URL="$DIST_URL/manifest.json"
}

json_get() { # json_get <file> <key>
    if have_cmd python3; then
        python3 - "$1" "$2" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
v=d
for part in sys.argv[2].split('.'):
    if isinstance(v,dict) and part in v: v=v[part]
    else: sys.exit(1)
print(v)
PY
    else
        grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
            | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
    fi
}

fetch_bundle() {
    section "$(t 'BUNDLE' 'PACOTE')"

    TMPDIR_Z="$(mktemp -d -t zelth-XXXXXX)"
    [ "$DRY_RUN" = "1" ] || mkdir -p "$CACHE_DIR"

    # ---- local source mode ----
    if [ -n "$SRC_DIR" ]; then
        SRC_DIR="$(cd "$SRC_DIR" 2>/dev/null && pwd)" || die "$(t 'Bad --from path' 'Caminho --from invalido'): $SRC_DIR"
        [ -f "$SRC_DIR/package.json" ] || die "$(t 'No package.json in' 'Sem package.json em') $SRC_DIR"
        step "$(t 'Using local source:' 'Usando fonte local:') $SRC_DIR"
        ok "$(t 'No download needed' 'Sem download necessario')"
        return 0
    fi

    resolve_dist_url

    # ---- manifest (optional) ----
    step "$(t 'Reading manifest' 'Lendo manifesto')..."
    local mf="$TMPDIR_Z/manifest.json"
    if fetch "$MANIFEST_URL" "$mf" 2>/dev/null; then
        local mv bn ea lx
        mv="$(json_get "$mf" version || true)"
        lx="$(json_get "$mf" linux || true)"
        bn="$(json_get "$mf" bundle || true)"
        ea="$(json_get "$mf" electron || true)"
        [ -n "$mv" ] && ZELTH_VERSION="$mv" && have "version $mv"
        # prefer the linux-specific build, fall back to the combined bundle
        [ -n "$lx" ] && bn="$lx"
        [ -n "$bn" ] && BUNDLE_NAME="$bn" && BUNDLE_URL="$DIST_URL/$bn" && have "bundle $bn"
        [ -n "$ea" ] && [ "$DO_ELECTRON" = "1" ] && ELECTRON_VERSION="$ea" && have "electron $ea"
    else
        c_skip "manifest.json $(t 'not available, using defaults' 'indisponivel, usando padroes')"
    fi

    if [ "$DRY_RUN" = "1" ]; then
        c_skip "[dry-run] would download $BUNDLE_URL"
        c_skip "[dry-run] would verify against $DIST_URL/SHA256SUMS"
        FETCHED_TARBALL=""
        return 0
    fi

    # ---- fetch (prefer the linux build, fall back to the combined bundle) ----
    local cand tarball
    for cand in "$BUNDLE_NAME" "zelth-latest.tar.gz"; do
        [ -n "$cand" ] || continue
        if [ "$cand" != "$BUNDLE_NAME" ] && [ "$BUNDLE_NAME" != "zelth-latest.tar.gz" ]; then
            c_skip "$(t 'trying fallback' 'tentando alternativa') $cand"
        fi
        tarball="$CACHE_DIR/$cand"
        if [ -f "$tarball" ] && [ "$KEEP_CACHE" = "1" ]; then
            c_info "$(t 'Cached bundle found:' 'Pacote em cache:') $tarball"
        elif [ "$KEEP_CACHE" = "1" ] || [ ! -f "$tarball" ]; then
            step "$(t 'Downloading' 'Baixando') $cand ..."
            if fetch "$DIST_URL/$cand" "$tarball.part"; then
                mv -f "$tarball.part" "$tarball"
            else
                rm -f "$tarball.part"
                [ -f "$tarball" ] || continue
            fi
        fi
        if [ -f "$tarball" ]; then
            BUNDLE_NAME="$cand"
            BUNDLE_URL="$DIST_URL/$cand"
            ok "$(t 'Bundle ready' 'Pacote pronto') $cand ($(human_size "$(wc -c < "$tarball")"))"
            break
        fi
    done
    [ -n "${tarball:-}" ] && [ -f "$tarball" ] || die "$(t 'Download failed' 'Download falhou'): $BUNDLE_URL"
    FETCHED_TARBALL="$tarball"

    # ---- checksum ----
    if [ "$DO_VERIFY" = "1" ]; then
        step "$(t 'Verifying checksum' 'Verificando checksum')..."
        local sums="$TMPDIR_Z/SHA256SUMS" want got
        if fetch "$DIST_URL/SHA256SUMS" "$sums" 2>/dev/null; then
            want="$(grep -F " $BUNDLE_NAME" "$sums" 2>/dev/null | head -1 | awk '{print $1}')"
            [ -z "$want" ] && want="$(grep -F "$BUNDLE_NAME" "$sums" 2>/dev/null | head -1 | awk '{print $1}')"
        fi
        if [ -n "$want" ]; then
            got="$(sha256_of "$FETCHED_TARBALL")"
            if [ "$want" != "$got" ]; then
                rm -f "$FETCHED_TARBALL"
                die "$(t 'Checksum mismatch - bundle corrupted' 'Checksum divergente - pacote corrompido')"
            fi
            ok "sha256 ${C_MUTED}${got:0:16}...${C_RESET}"
        else
            c_warn "$(t 'No checksum published for this bundle' 'Nenhum checksum publicado para este pacote')"
        fi
    else
        c_skip "$(t 'checksum verification disabled' 'verificacao de checksum desativada')"
    fi
}

# ============================================================================
#  STAGE FILES
# ============================================================================
tar_is_safe() { # guard against absolute paths and ../ traversal
    local listing
    listing="$(tar -tzf "$1" 2>/dev/null)" || return 1
    printf '%s\n' "$listing" | grep -qE '^/|(^|/)\.\.(/|$)' && return 1
    return 0
}

stage_files() {
    section "$(t 'INSTALLING FILES' 'INSTALANDO ARQUIVOS')"
    if [ "$DRY_RUN" = "1" ]; then
        if [ -n "$SRC_DIR" ]; then
            c_skip "[dry-run] would copy $(find "$SRC_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ') files + game data"
        else
            c_skip "[dry-run] would extract $BUNDLE_NAME into $INSTALL_DIR"
        fi
        c_skip "[dry-run] nothing written"
        return 0
    fi
    local stage="$TMPDIR_Z/stage"
    mkdir -p "$stage"

    if [ -z "$SRC_DIR" ] && [ -z "$FETCHED_TARBALL" ]; then
        c_skip "[dry-run] no bundle to extract"
        return 0
    fi

    if [ -n "$SRC_DIR" ]; then
        step "$(t 'Staging from' 'Preparando de') $SRC_DIR"
        # copy everything except heavy/generated dirs
        if have_cmd rsync; then
            rsync -a $RSYNC_PROGRESS \
                --exclude 'node_modules' \
                --exclude '.git' \
                --exclude 'installer/' \
                --exclude 'meteor-verify/' \
                --exclude 'tools/' \
                --exclude '*.backup*' \
                "$SRC_DIR/" "$stage/" \
            || die "$(t 'Failed to stage the local source' 'Falha ao preparar a fonte local')"
        else
            ( cd "$SRC_DIR" && tar -cf - \
                --exclude='./node_modules' --exclude='./.git' \
                --exclude='./installer' --exclude='./meteor-verify' --exclude='./tools' . ) \
            | ( cd "$stage" && tar -xf - )
        fi
    else
        step "$(t 'Extracting' 'Extraindo') $BUNDLE_NAME ..."
        tar_is_safe "$FETCHED_TARBALL" || die "$(t 'Unsafe tar entries in bundle' 'Entradas tar inseguras no pacote')"
        tar -xzf "$FETCHED_TARBALL" -C "$stage" || die "$(t 'Extraction failed' 'Falha ao extrair')"
    fi

    # the bundle may contain a single top-level directory
    local inner
    inner="$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -1)"
    if [ -n "$inner" ] && [ ! -f "$stage/package.json" ] && [ -f "$inner/package.json" ]; then
        step "$(t 'Normalising bundle layout' 'Normalizando layout do pacote')"
        rm -rf "$TMPDIR_Z/flat"; mkdir -p "$TMPDIR_Z/flat"
        cp -a "$inner/." "$TMPDIR_Z/flat/"
        stage="$TMPDIR_Z/flat"
    fi

    [ -f "$stage/package.json" ] || die "$(t 'Bundle has no package.json' 'Pacote sem package.json')"

    # ---- copy the app ----
    step "$(t 'Copying launcher to' 'Copiando launcher para') $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    if have_cmd rsync; then
        rsync -a $RSYNC_PROGRESS --exclude 'node_modules' "$stage/" "$INSTALL_DIR/" \
            || die "$(t 'Failed to copy files into' 'Falha ao copiar arquivos para') $INSTALL_DIR"
    else
        ( cd "$stage" && tar -cf - --exclude='./node_modules' . ) | ( mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR" && tar -xf - )
    fi
    ok "$(t 'Launcher files installed' 'Arquivos do launcher instalados')"

    # ---- report what came with the bundle ----
    local n
    n="$(find "$INSTALL_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    have "$n $(t 'launcher files' 'arquivos do launcher')"
    if [ -d "$INSTALL_DIR/game/versions" ]; then
        local vs
        vs="$(find "$INSTALL_DIR/game/versions" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | tr '\n' ' ')"
        have "$(t 'Game versions:' 'Versoes do jogo:') $vs"
    else
        c_skip "$(t 'No game data in this bundle' 'Sem dados de jogo neste pacote')"
    fi
    [ -d "$INSTALL_DIR/game/runtime" ] && have "$(t 'Bundled Java runtime' 'Runtime Java incluido')"

    # ---- executable bits ----
    chmod +x "$INSTALL_DIR/zelth" "$INSTALL_DIR/zelth.bin" "$INSTALL_DIR/uninstall.sh" 2>/dev/null

    restore_saves
    return 0
}

# ============================================================================
#  SAVES  (the bundle ships empty saves/ dirs -- never clobber real worlds)
# ============================================================================
restore_saves() {
    local prev="$INSTALL_DIR.prev"
    [ "$DO_SAVES" = "1" ] || return 0
    [ -d "$prev/game/versions" ] || return 0

    if [ "$DRY_RUN" = "1" ]; then
        c_skip "[dry-run] would carry over $(t 'game saves from' 'salvamentos de') $prev"
        return 0
    fi

    local restored=0 vdir old new
    for vdir in "$prev"/game/versions/*/; do
        [ -d "$vdir" ] || continue
        local vd; vd="$(basename "$vdir")"
        old="$vdir/saves"
        [ -d "$old" ] || continue
        # nothing to carry over if the old saves dir is empty
        [ -n "$(ls -A "$old" 2>/dev/null)" ] || continue
        new="$INSTALL_DIR/game/versions/$vd/saves"
        mkdir -p "$new" || continue
        # real worlds win over the bundle's empty stubs
        rm -rf "${new:?}"/*
        if cp -a "$old/." "$new/" 2>/dev/null; then
            restored=$((restored+1))
            c_skip "$(t 'carried over saves for' 'salvamentos preservados para') $vd"
        else
            warn "$(t 'Could not carry over saves for' 'Nao foi possivel preservar salvamentos de') $vd -- copies remain in $prev"
        fi
    done
    [ "$restored" -gt 0 ] && have "$restored $(t 'version(s) with saves kept' 'versao(oes) com salvamentos mantidos')"
    return 0
}

# ============================================================================
#  ELECTRON  (no npm, no sudo)
# ============================================================================
electron_arch_dir() { [ "$ELECTRON_ARCH" = "arm64" ] && echo "electron-v${ELECTRON_VERSION}-linux-arm64.zip" || echo "electron-v${ELECTRON_VERSION}-linux-x64.zip"; }

install_electron() {
    section "$(t 'ELECTRON RUNTIME' 'RUNTIME ELECTRON')"

    if [ "$DO_ELECTRON" = "0" ]; then
        c_skip "$(t 'skipped (--no-electron)' 'ignorado (--no-electron)')"
        return 0
    fi

    local nm="$INSTALL_DIR/node_modules"
    local bin="$nm/.bin/electron"
    local dist="$nm/electron/dist"

    # already good?
    if [ -x "$dist/electron" ]; then
        local v
        v="$("$dist/electron" --version 2>/dev/null || echo "?")"
        if [ "$v" = "$ELECTRON_VERSION" ]; then
            have "electron $v $(t '(already installed)' '(ja instalado)')"
            return 0
        else
            c_warn "$(t "electron $v present, want $ELECTRON_VERSION - reinstalling" "electron $v presente, quer $ELECTRON_VERSION - reinstalando")"
        fi
    fi

    if [ "$DRY_RUN" = "1" ]; then
        c_skip "[dry-run] would install electron $ELECTRON_VERSION ($(electron_arch_dir))"
        return 0
    fi

    local asset; asset="$(electron_arch_dir)"
    local url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/${asset}"
    local zip="$TMPDIR_Z/electron.zip"

    # --- 1. npm (only if node+npm already exist) ---
    if have_cmd node && have_cmd npm; then
        step "$(t 'npm found - using it' 'npm encontrado - usando') (node $(node -v 2>/dev/null))"
        if ( cd "$INSTALL_DIR" && npm install --no-audit --no-fund --loglevel=error electron@"$ELECTRON_VERSION" ) >/dev/null 2>&1 \
           && [ -x "$dist/electron" ]; then
            ok "electron $("$dist/electron" --version 2>/dev/null) $(t 'via npm' 'via npm')"
            return 0
        fi
        c_warn "$(t 'npm install failed, falling back to prebuilt binary' 'npm install falhou, usando binario pre-compilado')"
    fi

    # --- 2. prebuilt zip (works everywhere, no npm) ---
    step "$(t 'Downloading Electron' 'Baixando Electron') $ELECTRON_VERSION $(t 'for' 'para') linux-$ELECTRON_ARCH ..."
    if ! fetch "$url" "$zip"; then
        die "$(t 'Could not download Electron from' 'Nao foi possivel baixar Electron de') $url"
    fi
    have "$(t 'Downloaded' 'Baixado') $(human_size "$(wc -c < "$zip")")"

    rm -rf "$dist"; mkdir -p "$dist"
    if have_cmd unzip; then
        unzip -q -o "$zip" -d "$dist" || die "$(t 'unzip failed' 'unzip falhou')"
    else
        # busybox / minimal systems: python zipfile
        have_cmd python3 || die "$(t 'Need unzip or python3 to extract Electron' 'Precisa de unzip ou python3 para extrair o Electron')"
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$dist" \
            || die "$(t 'Extraction failed' 'Falha ao extrair')"
    fi
    [ -x "$dist/electron" ] || chmod +x "$dist/electron" 2>/dev/null
    [ -x "$dist/electron" ] || die "$(t 'Electron binary missing after extraction' 'Binario do Electron ausente apos extrair')"

    # minimal package.json so node resolution never breaks
    cat > "$nm/electron/package.json" <<EOF
{
  "name": "electron",
  "version": "$ELECTRON_VERSION",
  "main": "index.js",
  "private": true
}
EOF
    printf 'module.exports = require("path").join(__dirname, "dist", "electron");\n' > "$nm/electron/index.js"

    # the launcher shims call node_modules/.bin/electron
    mkdir -p "$nm/.bin"
    cat > "$bin" <<EOF
#!/usr/bin/env bash
# Zelth - Electron shim (generated by install.sh)
DIST="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../electron/dist" && pwd)"
exec "\$DIST/electron" "\$@"
EOF
    chmod +x "$bin"

    ok "electron $("$dist/electron" --version 2>/dev/null) $(t 'installed (prebuilt, no npm)' 'instalado (pre-compilado, sem npm)')"
}

# ============================================================================
#  UNINSTALL
# ============================================================================
uninstall() {
    section "$(t 'UNINSTALL' 'DESINSTALAR')"
    local targets=(
        "$INSTALL_DIR"
        "$INSTALL_DIR.prev"
        "$HOME/.local/bin/zelth"
        "$HOME/.local/share/applications/zelth.desktop"
        "$HOME/.local/share/applications/Zelth.desktop"
        "$HOME/Desktop/Zelth.desktop"
        "$HOME/.local/share/icons/hicolor/512x512/apps/zelth.png"
        "$HOME/.local/share/icons/hicolor/256x256/apps/zelth.png"
        "$HOME/.local/share/icons/hicolor/128x128/apps/zelth.png"
        "$HOME/.cache/zelth"
        "$HOME/.cache/electron"
    )
    for f in "${targets[@]}"; do
        # -e is false for a dangling symlink, so check -L too
        if [ -e "$f" ] || [ -L "$f" ]; then
            rm -rf "$f" 2>/dev/null && ok "$(t 'removed' 'removido') $f" || warn "$(t 'could not remove' 'nao foi possivel remover') $f"
        else
            c_skip "$(t 'absent' 'ausente') $f"
        fi
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null
    printf '\n'
    c_green "$(t 'Zelth removed.' 'Zelth removido.')"
    printf '\n'
}

# ============================================================================
#  UNINSTALLER SCRIPT (written into the install dir)
# ============================================================================
write_uninstaller() {
    [ "$DRY_RUN" = "1" ] && return 0
    cat > "$INSTALL_DIR/uninstall.sh" <<EOF
#!/usr/bin/env bash
# Zelth Launcher - uninstaller
set -uo pipefail
INSTALL_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
echo "Removing Zelth from \$INSTALL_DIR ..."
rm -rf "\$INSTALL_DIR" "\$INSTALL_DIR.prev"
rm -f "\$HOME/.local/bin/zelth" \\
      "\$HOME/.local/share/applications/zelth.desktop" \\
      "\$HOME/Desktop/Zelth.desktop" \\
      "\$HOME/.local/share/icons/hicolor/512x512/apps/zelth.png" \\
      "\$HOME/.local/share/icons/hicolor/256x256/apps/zelth.png" \\
      "\$HOME/.local/share/icons/hicolor/128x128/apps/zelth.png"
rm -rf "\$HOME/.cache/zelth" "\$HOME/.cache/electron"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "\$HOME/.local/share/applications" 2>/dev/null
echo "Done. Game saves in \$INSTALL_DIR/game were removed too - back them up first if you care."
EOF
    chmod +x "$INSTALL_DIR/uninstall.sh"
    ok "$(t 'Uninstaller written' 'Desinstalador escrito'): $INSTALL_DIR/uninstall.sh"
}

# ============================================================================
#  DESKTOP INTEGRATION
# ============================================================================
install_desktop() {
    section "$(t 'DESKTOP INTEGRATION' 'INTEGRACAO COM AREA DE TRABALHO')"

    if [ "$DO_DESKTOP" = "0" ]; then
        c_skip "$(t 'skipped (--no-desktop)' 'ignorado (--no-desktop)')"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        c_skip "[dry-run] would write zelth.desktop + icons"
        return 0
    fi

    local appdir="$HOME/.local/share/applications"
    local icondir="$HOME/.local/share/icons/hicolor"
    mkdir -p "$appdir" "$icondir/512x512/apps" "$icondir/256x256/apps" "$icondir/128x128/apps"

    # ---- icon ----
    local icon_ok=0
    if [ -f "$INSTALL_DIR/zelth.png" ]; then
        for sz in 512x512 256x256 128x128; do
            cp -f "$INSTALL_DIR/zelth.png" "$icondir/$sz/apps/zelth.png" 2>/dev/null
        done
        ok "$(t 'Icon installed' 'Icone instalado') ($icondir/512x512/apps/zelth.png)"
        icon_ok=1
    else
        c_skip "$(t 'no zelth.png in the bundle, using fallback icon' 'sem zelth.png no pacote, usando icone padrao')"
    fi
    [ "$icon_ok" = "1" ] && ICON_LINE="zelth" || ICON_LINE="applications-games"

    # ---- desktop entry ----
    local dfile="$appdir/zelth.desktop"
    cat > "$dfile" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Zelth
GenericName=Minecraft Launcher
Comment=Zelth - Zelth Launcher v$ZELTH_VERSION
Exec=$INSTALL_DIR/zelth --no-sandbox %U
Path=$INSTALL_DIR
Icon=$ICON_LINE
Terminal=false
Categories=Game;Utility;
Keywords=minecraft;zelth;fabric;meteor;launcher;
StartupNotify=true
StartupWMClass=zelth
MimeType=x-scheme-handler/zelth;
EOF
    chmod +x "$INSTALL_DIR/zelth" 2>/dev/null
    ok "$(t 'Desktop entry written' 'Entrada da area de trabalho escrita'): $dfile"

    # ---- user desktop shortcut ----
    local udir="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
    if [ -d "$udir" ]; then
        cp -f "$dfile" "$udir/Zelth.desktop" 2>/dev/null && \
            chmod +x "$udir/Zelth.desktop" 2>/dev/null && \
            ok "$(t 'Shortcut added to' 'Atalho adicionado em') $udir"
    fi

    # ---- refresh caches ----
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$appdir" >/dev/null 2>&1 && c_skip "update-desktop-database ok"
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t "$icondir" >/dev/null 2>&1 && c_skip "gtk-update-icon-cache ok"
    fi
}

# ============================================================================
#  CLI SHIM
# ============================================================================
install_cli() {
    section "$(t 'COMMAND' 'COMANDO')"
    if [ "$DO_CLI" = "0" ]; then
        c_skip "$(t 'skipped (--no-cli)' 'ignorado (--no-cli)')"
        return 0
    fi
    local bindir="$HOME/.local/bin"
    if [ "$DRY_RUN" = "1" ]; then
        c_skip "[dry-run] would link $bindir/zelth"
        return 0
    fi
    mkdir -p "$bindir"
    ln -sf "$INSTALL_DIR/zelth" "$bindir/zelth"
    ok "zelth ${C_MUTED}$bindir/zelth${C_RESET}"
    if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$bindir"; then
        c_warn "$(t "$bindir is not in your PATH" "$bindir nao esta no seu PATH")"
        c_muted "$(t 'add this to ~/.bashrc:' 'adicione no ~/.bashrc:')"
        printf '%s\n' "$C_TEAL    export PATH=\"\$HOME/.local/bin:\$PATH\"${C_RESET}"
    fi
}

# ============================================================================
#  VERIFY
# ============================================================================
verify() {
    section "$(t 'VERIFY' 'VERIFICAR')"
    if [ "$DRY_RUN" = "1" ]; then
        c_skip "$(t 'skipped (dry run)' 'ignorado (dry run)')"
        return 0
    fi
    local bad=0

    local f
    for f in package.json main.js index.html styles.css renderer.js preload.js launcher.js; do
        if [ -f "$INSTALL_DIR/$f" ]; then
            c_skip "$f"
        else
            fail "missing $f"
            bad=1
        fi
    done
    [ "$bad" = "0" ] && have "$(t 'all launcher files present' 'todos os arquivos do launcher presentes')"

    if [ "$DO_ELECTRON" = "1" ]; then
        if [ -x "$INSTALL_DIR/node_modules/electron/dist/electron" ]; then
            have "electron $("$INSTALL_DIR/node_modules/electron/dist/electron" --version 2>/dev/null)"
        else
            warn "$(t 'electron not installed - the launcher will not start' 'electron nao instalado - o launcher nao vai abrir')"
        fi
    fi

    if [ -x "$INSTALL_DIR/game/runtime/java-runtime-delta/linux/java-runtime-delta/bin/java" ]; then
        have "java $("$INSTALL_DIR/game/runtime/java-runtime-delta/linux/java-runtime-delta/bin/java" -version 2>&1 | head -1 | tr -d '"' | awk '{print $3}')"
    else
        c_skip "$(t 'bundled java not found (system java will be used)' 'java incluido nao encontrado (java do sistema sera usado)')"
    fi

    local nv
    nv="$(find "$INSTALL_DIR/game/versions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    [ "$nv" != "0" ] && have "$nv $(t 'game version(s) ready' 'versao(oes) de jogo pronta(s)')"

    if [ -f "$INSTALL_DIR/zelth-meteor-config.nbt" ]; then
        c_skip "Meteor config master present"
    fi
}

# ============================================================================
#  SUMMARY
# ============================================================================
summary() {
    printf '\n'
    rule
    printf '%s%s %s %sv%s%s\n\n' \
        "$C_GREEN" "$G_OK" \
        "${C_BOLD}${C_GREEN}$(t 'Zelth is ready.' 'Zelth esta pronto.')${C_RESET}" \
        "$C_GOLD" "$ZELTH_VERSION" "$C_RESET"

    printf '%s%s  %s%s\n' "$C_MOON" "$G_ARROW" "$C_RESET" "$(t 'Play' 'Jogar')"
    printf "    %szelth%s\n" "$C_TEAL" "$C_RESET"
    printf "    %sor%s %s%s/zelth%s\n" "$C_MUTED" "$C_RESET" "$C_TEXT" "$INSTALL_DIR" "$C_RESET"
    printf '\n'
    printf '%s%s  %s%s\n' "$C_MOON" "$G_ARROW" "$C_RESET" "$(t 'Or find it in your app menu' 'Ou encontre no menu de aplicativos')"
    printf '    %sZelth%s\n' "$C_TEXT" "$C_RESET"
    printf '\n'
    printf '%s%s  %s%s\n' "$C_MOON" "$G_ARROW" "$C_RESET" "$(t 'Remove it later with' 'Para remover depois')"
    printf "    %s%s/uninstall.sh%s\n" "$C_TEXT" "$INSTALL_DIR" "$C_RESET"
    printf '\n'

    if [ "$IMMUTABLE" = "1" ]; then
        c_teal "$(t 'Immutable distro: everything lives in your home directory, no system packages were touched.' 'Distro imutavel: tudo fica no seu home, nenhum pacote do sistema foi tocado.')"
        printf '\n'
    fi
    printf '%s%s %s%s%s\n' "$C_MOON" "$G_MOON" "$C_MUTED" "$(t 'moonlight, load fast.' 'lua, carrega rapido.')" "$C_RESET"
    printf '\n'
}

# ============================================================================
#  LAUNCH
# ============================================================================
launch_app() {
    if [ "$DO_LAUNCH" = "0" ]; then
        c_skip "$(t 'not starting the launcher (--no-launch)' 'nao iniciando o launcher (--no-launch)')"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        c_skip "[dry-run] would launch $INSTALL_DIR/zelth"
        return 0
    fi
    local start="$INSTALL_DIR/zelth"
    if [ ! -x "$start" ]; then
        warn "$(t 'Start script not found:' 'Script de inicio nao encontrado:') $start"
        return 0
    fi
    step "$(t 'Launching Zelth' 'Iniciando Zelth') ..."
    if ( cd "$INSTALL_DIR" && setsid "$start" >/dev/null 2>&1 & ) 2>/dev/null; then
        ok "$(t 'started in the background' 'iniciado em segundo plano')"
    else
        ( cd "$INSTALL_DIR" && nohup "$start" >/dev/null 2>&1 & ) 2>/dev/null \
            && ok "$(t 'started in the background' 'iniciado em segundo plano')" \
            || warn "$(t 'could not start it - run' 'nao foi possivel iniciar - execute') zelth"
    fi
}

# ============================================================================
#  MAIN
# ============================================================================
main() {
    parse_args "$@"

    [ "$DO_HELP" = "1" ]    && { usage; exit 0; }
    [ "$SHOW_VERSION" = "1" ] && { printf 'zelth-installer %s (channel %s, electron %s)\n' "$ZELTH_VERSION" "$ZELTH_CHANNEL" "$ELECTRON_VERSION"; exit 0; }

    if [ "$DO_UNINSTALL" = "1" ]; then
        banner
        uninstall
        exit 0
    fi

    banner
    preflight
    fetch_bundle
    stage_files
    install_electron
    write_uninstaller
    install_desktop
    install_cli
    verify
    summary
    launch_app
    cleanup
    exit 0
}

main "$@"

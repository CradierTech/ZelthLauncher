#!/usr/bin/env bash
# ============================================================================
#  Zelth one-shot publisher
#  Pushes the repo, creates/updates the GitHub release, uploads every asset in
#  ASSET_DIR, then waits for the CDN and verifies each one is really served.
#
#  Usage:  bash publish.sh [tag]      (default v3.1.0)
#  Needs:  curl, git, python3, a fine-grained token (Contents: write + Releases)
# ============================================================================
set -uo pipefail

OWNER="CradierTech"
REPO="ZelthLauncher"
TAG="${1:-v3.1.0}"
NAME="Zelth ${TAG#v}"
REPO_DIR="/home/cradier/Downloads/Zelth"
ASSET_DIR="/tmp/opencode/zelth-build"
API="https://api.github.com"
SLEEP_BETWEEN=3

g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; d=$'\033[2m'; x=$'\033[0m'
step(){ printf '%s==>%s %s\n' "$g" "$x" "$*"; }
ok()  { printf '  %sok%s    %s\n' "$g" "$x" "$*"; }
bad() { printf '  %sFAIL%s  %s\n' "$r" "$x" "$*"; }
die() { printf '%serror:%s %s\n' "$r" "$x" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
for c in curl git python3; do have "$c" || die "missing dependency: $c"; done

TOK="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOK" ]; then
    step "no GITHUB_TOKEN in env - reading it now (input hidden)"
    printf 'Paste your github_pat_... token: '
    read -rs TOK; printf '\n'
fi
[ -n "$TOK" ] || die "empty token"

AUTH=(-H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# ---- token ----------------------------------------------------------------
step "validating token"
LOGIN="$(curl -fsS "${AUTH[@]}" "$API/user" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("login",""))' 2>/dev/null)"
[ -n "$LOGIN" ] || die "token rejected (401)"
ok "authenticated as $LOGIN"

# ---- assets ---------------------------------------------------------------
step "assets in $ASSET_DIR"
shopt -s nullglob
FILES=("$ASSET_DIR"/*)
shopt -u nullglob
[ "${#FILES[@]}" -gt 0 ] || die "no assets found in $ASSET_DIR"
for f in "${FILES[@]}"; do
    printf '        %-30s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done

# ---- push -----------------------------------------------------------------
step "pushing source to $OWNER/$REPO"
ASKPASS="$(mktemp)"; trap 'rm -f "$ASKPASS"' EXIT
cat > "$ASKPASS" <<EOF
#!/usr/bin/env bash
case "\$1" in
    *sername*) echo "$LOGIN" ;;
    *assword*) echo "$TOK" ;;
esac
EOF
chmod +x "$ASKPASS"
cd "$REPO_DIR" || die "no repo at $REPO_DIR"
git remote set-url origin "https://github.com/$OWNER/$REPO.git"
if GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git push -u origin main 2>&1 | sed 's/^/  /'; then
    ok "main pushed ($(git rev-parse --short HEAD))"
else
    bad "push reported a problem above"
fi

# ---- release --------------------------------------------------------------
step "release $TAG"
REL="$(curl -fsS "${AUTH[@]}" "$API/repos/$OWNER/$REPO/releases/tags/$TAG" 2>/dev/null || true)"
RID="$(printf '%s' "$REL" | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(d.get("id") or "")
except Exception: print("")' 2>/dev/null)"

if [ -n "$RID" ]; then
    ok "release $TAG exists (id $RID)"
    # make sure it is not a draft, or /latest/ will not resolve
    if printf '%s' "$REL" | grep -q '"draft": true'; then
        step "publishing draft"
        curl -fsS -X PATCH "${AUTH[@]}" -H "Content-Type: application/json" \
             -d '{"draft":false,"prerelease":false}' \
             "$API/repos/$OWNER/$REPO/releases/$RID" >/dev/null && ok "draft -> published"
    fi
else
    BODY="$(TAG="$TAG" NAME="$NAME" OWNER="$OWNER" REPO="$REPO" python3 -c '
import json, os
print(json.dumps({
    "tag_name": os.environ["TAG"],
    "name": os.environ["NAME"],
    "body": ("One-shot installer for the Zelth launcher.\n\n"
             "Linux:   curl -fsSL https://raw.githubusercontent.com/{o}/{r}/main/installer/install.sh | bash\n"
             "Windows: irm https://raw.githubusercontent.com/{o}/{r}/main/installer/install.ps1 | iex\n").format(o=os.environ["OWNER"], r=os.environ["REPO"]),
    "draft": False, "prerelease": False,
}))')"
    CREATED="$(curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" -d "$BODY" "$API/repos/$OWNER/$REPO/releases" 2>&1)"
    RID="$(printf '%s' "$CREATED" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
    [ -n "$RID" ] || die "release creation failed: $CREATED"
    ok "release created (id $RID)"
fi

# ---- upload ---------------------------------------------------------------
step "uploading assets"
upload_one() {
    local f="$1" n; n="$(basename "$f")"
    local ex
    ex="$(curl -fsS "${AUTH[@]}" "$API/repos/$OWNER/$REPO/releases/$RID/assets" 2>/dev/null | NAME="$n" python3 -c '
import json, os, sys
try: a = json.load(sys.stdin)
except Exception: sys.exit(0)
for x in a:
    if x.get("name") == os.environ["NAME"]: print(x["id"])' 2>/dev/null)"
    if [ -n "$ex" ]; then
        curl -fsS -X DELETE "${AUTH[@]}" "$API/repos/$OWNER/$REPO/releases/assets/$ex" >/dev/null 2>&1 \
            && printf '        replaced existing %s\n' "$n"
    fi
    local out
    out="$(curl -fsS --progress-bar -X POST "${AUTH[@]}" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@$f" \
            "https://uploads.github.com/repos/$OWNER/$REPO/releases/$RID/assets?name=$n" 2>&1)"
    if printf '%s' "$out" | grep -q '"id"'; then
        ok "$n uploaded"
    else
        bad "$n upload problem: $(printf '%s' "$out" | head -c 200)"
    fi
}
for f in "${FILES[@]}"; do upload_one "$f"; done

# ---- verify (with CDN lag tolerance) --------------------------------------
step "verifying (CDN can take a minute)"
for attempt in 1 2 3 4 5; do
    sleep "$SLEEP_BETWEEN"
    allgood=1
    for f in "${FILES[@]}"; do
        n="$(basename "$f")"
        want="$(wc -c < "$f")"
        got="$(curl -fsSIL "https://github.com/$OWNER/$REPO/releases/download/$TAG/$n" 2>/dev/null \
              | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')"
        if [ "${got:-0}" = "$want" ]; then
            ok "$n served ($want bytes)"
        else
            bad "$n not serving yet (have ${got:-0}, want $want)"
            allgood=0
        fi
    done
    if [ "$allgood" = "1" ]; then break; fi
    [ "$attempt" != "5" ] && printf '        retrying in %ss ...\n' "$((SLEEP_BETWEEN*3))" && sleep $((SLEEP_BETWEEN*3))
done

RAW="https://raw.githubusercontent.com/$OWNER/$REPO/main/installer/install.sh"
if curl -fsSL "$RAW" 2>/dev/null | head -c 40 | grep -q 'Zelth'; then
    ok "install.sh reachable on raw.githubusercontent"
else
    bad "install.sh NOT reachable"
fi

printf '\nDONE  %s\n\n' "$TAG"
printf 'Linux:   curl -fsSL %s | bash\n' "$RAW"
printf 'Windows: irm %s | iex\n' "${RAW/install.sh/install.ps1}"

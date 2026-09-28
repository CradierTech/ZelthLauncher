# Zelth Installer

One-shot `curl | bash` installer for the Zelth launcher.

```bash
curl -fsSL https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/install.sh | bash
```

The user needs **nothing** preinstalled: no Node.js, no npm, no Electron, no
Java, no root. Everything lands in `$HOME`.

---

## What it does

| Stage | Detail |
| --- | --- |
| **Pre-flight** | bash version, CPU arch (x86_64 / aarch64), distro + immutable detection, required tools, network, free disk, existing-install guard |
| **Bundle** | reads `manifest.json`, downloads the tarball, verifies `SHA256SUMS` (cached in `~/.cache/zelth`) |
| **Files** | extracts into `~/.local/share/zelth`, with tar path-traversal guard |
| **Electron** | downloads the official prebuilt binary — **no npm, no sudo**. Falls back to `npm install` only if a Node is already present and the prebuilt fetch fails |
| **Desktop** | `.desktop` entry, 3 icon sizes, `update-desktop-database`, `gtk-update-icon-cache` |
| **CLI** | `~/.local/bin/zelth` symlink |
| **Uninstall** | `uninstall.sh` written into the install dir |
| **Verify** | confirms every launcher file, the Electron binary, the bundled Java, and the game versions |

Works on immutable distros (SteamOS, Bazzite, Silverblue) because it installs
**zero system packages** — it only writes to `$HOME`.

Bilingual: English / Português, auto-detected from `LANG`, overridable with `--lang`.

---

## Publish contract

The installer expects three files side by side in your release/assets directory.
All three are optional except the bundle.

### 1. `zelth-latest.tar.gz` — required

A gzipped tar of the launcher directory. Layout may be flat or wrapped in one
top-level directory (the installer normalises both):

```
package.json
main.js
index.html
styles.css
renderer.js
preload.js
launcher.js
zelth            (executable start script)
zelth.png
zelth-meteor-config.nbt
zelth-meteor-theme.nbt
game/            (optional: libraries, runtime, versions)
```

Do **not** include `node_modules` — the installer excludes it and fetches
Electron itself.

To produce it, from the launcher source dir:

```bash
tar -czf zelth-latest.tar.gz \
    --exclude=node_modules \
    --exclude=installer \
    --exclude=tools \
    --exclude=meteor-verify \
    --exclude='*.backup*' \
    .
sha256sum zelth-latest.tar.gz > SHA256SUMS
```

### 2. `SHA256SUMS` — strongly recommended

```
<sha256>  zelth-latest.tar.gz
```

If the bundle's hash does not match, the installer deletes the download and
aborts without installing anything. Use `--no-verify` to bypass.

### 3. `manifest.json` — optional

```json
{
  "version": "3.0.0",
  "bundle": "zelth-latest.tar.gz",
  "electron": "33.4.11",
  "channel": "stable"
}
```

Only `version`, `bundle` and `electron` are read. When present they override the
compiled-in defaults, so you can ship a new build without editing the script.

---

## Channels

`--channel` maps to a release download URL:

| Channel | URL |
| --- | --- |
| `stable` (default) | `github.com/<repo>/releases/latest/download` |
| `beta` | `github.com/<repo>/releases/download/beta` |
| `nightly` | `github.com/<repo>/releases/download/nightly` |
| anything else | treated as a literal base URL (handy for testing) |

```bash
# beta
curl -fsSL https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/install.sh | bash -s -- --channel beta

# straight off a build server
curl -fsSL https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/install.sh | bash -s -- --channel https://builds.example.com/zelth
```

---

## Options

```
--from <dir>          install from a local folder, no download
--dir <path>          install location           (default ~/.local/share/zelth)
--uninstall           remove everything, including game saves
--channel <name>      stable | beta | nightly | literal URL
--repo <owner/name>   source repository
--bundle <file>       bundle tarball name
--electron-version    pin Electron instead of using the manifest
--no-electron         skip the Electron runtime
--no-desktop          skip .desktop + icon registration
--no-cli              skip the ~/.local/bin/zelth symlink
--no-verify           skip checksum verification
--no-cache            re-download even if cached
--lang <en|pt>        force UI language
--force               overwrite an existing install without prompting
--dry-run             print the plan, write nothing
-h, --help            full help
-v, --version         installer version
```

Overridable via env: `ZELTH_VERSION` `ZELTH_CHANNEL` `ZELTH_REPO` `ZELTH_DIR`
`ZELTH_BUNDLE` `ELECTRON_VERSION` `NO_COLOR` `NO_UNICODE`.

---

## Safety behaviour

- An existing install is moved to `<dir>.prev`, never deleted in place.
- Tar entries are checked for absolute paths and `../` before extraction.
- A checksum mismatch aborts before anything is written.
- `--dry-run` is genuinely side-effect free (asserted by the test suite).
- Every destructive step prints what it touched.

---

## Files here

| File | Purpose |
| --- | --- |
| `install.sh` | the installer — this is the only file you need to publish to `raw.githubusercontent.com` |
| `selftest.sh` | 29-assertion regression suite; builds a fake bundle, serves it on localhost, runs everything against a throwaway `$HOME` |
| `check_printf.py` | static check that no `printf` format string has a mismatched argument count (bash silently recycles the format when there are extra args) |

```bash
bash selftest.sh          # run the suite
```

---

## Updating an existing install

Re-run the same command. The installer pulls the new bundle, moves the old
install to `~/.local/share/zelth.prev`, and writes a fresh `uninstall.sh`.

If you want to keep your game data, the bundle's `game/` dir is replaced on
every install, so back up `game/versions/*/saves` first — or point `--dir` at a
fresh location and copy the saves across yourself.

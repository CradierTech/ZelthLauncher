const fs = require("fs");
const path = require("path");
const net = require("net");
const { spawn } = require("child_process");

const isWin = process.platform === "win32";
const OS_NAME = isWin ? "windows" : "linux";
const PLAT_DIR = isWin ? "windows" : "linux";
const JAVA_BIN = isWin ? "java.exe" : "java";

const HOME = isWin
    ? (process.env.APPDATA || path.join(process.env.USERPROFILE || ".", "AppData", "Roaming"))
    : (process.env.HOME || ".");
const APP_DIR = __dirname;
const REAL_MCDIR = path.join(HOME, ".minecraft");
const BUNDLED_MCDIR = path.join(APP_DIR, "game");
const MCDIR = (fs.existsSync(path.join(REAL_MCDIR, "versions"))
    ? REAL_MCDIR
    : (fs.existsSync(path.join(BUNDLED_MCDIR, "versions")) ? BUNDLED_MCDIR : REAL_MCDIR));
const LIBS_DIR = path.join(MCDIR, "libraries");
const ASSETS_DIR = path.join(MCDIR, "assets");
const RUNTIME_DIR = path.join(MCDIR, "runtime");
const VERSIONS_DIR = path.join(MCDIR, "versions");
const PROFILES_JSON = path.join(MCDIR, "TlauncherProfiles.json");

const ZELTH_PACK_NAME = "Zelth fbf7d94d.zip";
const ZELTH_PACK = "file/" + ZELTH_PACK_NAME;
const ZELTH_PACK_MASTER = path.join(__dirname, ".zelthpack");
const ZELTH_DECOYS = [
    "Zelth 0c548a0a.zip",
    "Zelth 2d894760.zip",
    "Zelth 44d51359.zip",
    "Zelth 6cd68cd9.zip",
    "Zelth 9b9400e0.zip",
    "Zelth af0de137.zip",
];
const ZELTH_DECOY_ZIP = Buffer.from("UEsDBBQAAAAIAC1GLF0ADzgsTQAAAGQAAAALAAAAcGFjay5tY21ldGGrVipITM5WsqpWSkktTi7KLCjJzM9TslKKSs0pyVCoMM81KrAsTFQwKTdNNSuyKFHSAauPT8svyk0sUbIyN9VRys3MQ+UnViDxa2u5AFBLAQIUAxQAAAAIAC1GLF0ADzgsTQAAAGQAAAALAAAAAAAAAAAAAACkgQAAAABwYWNrLm1jbWV0YVBLBQYAAAAAAQABADkAAAB2AAAAAAA=", "base64");

const DISCORD_CLIENT_ID = "1548234017059635210";

let discSock = null;
let discBuf = Buffer.alloc(0);
let discReady = false;
let discPending = null;
let discConnecting = false;
let discRetries = 0;
let discTimer = null;

function discLog(msg) {
    try { gameCallbacks.onLog(msg); } catch (_e) {}
}

function discFrame(op, obj) {
    const payload = Buffer.from(JSON.stringify(obj), "utf8");
    const head = Buffer.alloc(8);
    head.writeUInt32LE(op, 0);
    head.writeUInt32LE(payload.length, 4);
    return Buffer.concat([head, payload]);
}

function discSend(op, obj) {
    if (discSock && discReady) {
        try { discSock.write(discFrame(op, obj)); } catch (_e) {}
    }
}

function discConnect() {
    if (discConnecting || discSock) return;
    discConnecting = true;
    const paths = [];
    for (let i = 0; i < 10; i++) {
        if (isWin) paths.push("\\\\.\\pipe\\discord-ipc-" + i);
        else paths.push((process.env.XDG_RUNTIME_DIR || "/tmp") + "/discord-ipc-" + i);
    }
    let idx = 0;
    let failed = false;
    const tryNext = () => {
        if (idx >= paths.length) {
            discConnecting = failed = false;
            return;
        }
        const p = paths[idx++];
        const s = net.connect(p);
        s.setTimeout(2000, () => s.destroy());
        s.once("error", () => { failed = true; tryNext(); });
        s.once("connect", () => {
            s.setTimeout(0);
            discSock = s;
            discBuf = Buffer.alloc(0);
            s.on("data", d => {
                discBuf = Buffer.concat([discBuf, d]);
                while (discBuf.length >= 8) {
                    const op = discBuf.readUInt32LE(0);
                    const len = discBuf.readUInt32LE(4);
                    if (discBuf.length < 8 + len) break;
                    const payload = discBuf.toString("utf8", 8, 8 + len);
                    discBuf = discBuf.slice(8 + len);
                    let j = null;
                    try { j = JSON.parse(payload); } catch (_e) {}
                    if (!j) continue;
                    if (j.evt === "READY" || (j.cmd === "READY")) {
                        discReady = true;
                        discRetries = 0;
                        discLog("Discord Rich Presence connected");
                        if (discPending) discSend(1, discPending);
                    } else if (j.evt === "ERROR") {
                        discReady = false;
                    }
                }
            });
            s.on("close", () => { discSock = null; discReady = false; discConnecting = false; });
            s.on("error", () => {});
            const hs = {
                v: 1,
                client_id: DISCORD_CLIENT_ID,
                pid: process.pid,
            };
            try { s.write(discFrame(0, hs)); } catch (_e) {}
        });
    };
    tryNext();
    if (failed && discPending && discRetries < 12) {
        discRetries++;
        if (discTimer) clearTimeout(discTimer);
        discTimer = setTimeout(() => { discConnecting = false; discConnect(); }, 5000);
    }
}

function discSetPresence(activity) {
    if (!/^\d+$/.test(DISCORD_CLIENT_ID)) return;
    const msg = {
        cmd: "SET_ACTIVITY",
        args: { pid: process.pid, activity: activity || null },
        nonce: "zc-" + Date.now(),
    };
    discPending = msg;
    if (discSock && discReady) discSend(1, msg);
    else discConnect();
}

function rpcPlaying(versionName) {
    discSetPresence({
        details: versionName,
        state: "Playing ZelthClient",
        startTimestamp: Date.now(),
        largeImageKey: "zelth",
        instance: true,
        buttons: [{ label: "Join the server", url: "https://dsc.gg/crssd" }],
    });
}

function rpcMenu() {
    discSetPresence({
        details: "ZelthClient",
        state: "In the launcher",
        startTimestamp: Date.now(),
        largeImageKey: "zelth",
        instance: true,
        buttons: [{ label: "Join the server", url: "https://dsc.gg/crssd" }],
    });
}

function rpcStop() {
    discSetPresence(null);
}

function enableZelthPack(gameDir) {
    try {
        const packsDir = path.join(gameDir, "resourcepacks");
        fs.mkdirSync(packsDir, { recursive: true });
        const packZip = path.join(packsDir, ZELTH_PACK_NAME);
        if (!fs.existsSync(packZip) && fs.existsSync(ZELTH_PACK_MASTER)) {
            fs.copyFileSync(ZELTH_PACK_MASTER, packZip);
        }
        if (!fs.existsSync(packZip)) return;
        for (const name of ZELTH_DECOYS) {
            const p = path.join(packsDir, name);
            if (!fs.existsSync(p)) fs.writeFileSync(p, ZELTH_DECOY_ZIP);
        }
        const optionsPath = path.join(gameDir, "options.txt");
        let options = fs.existsSync(optionsPath) ? fs.readFileSync(optionsPath, "utf8") : "";
        const desiredLine = "resourcePacks:[" +
            [ZELTH_PACK, ...ZELTH_DECOYS.map(n => "file/" + n)].map(s => `"${s}"`).join(",") +
            "]";
        if (options.indexOf(desiredLine) === -1) {
            options = options.replace(/resourcePacks:\[[^\]]*\]/, desiredLine);
            if (options.indexOf("resourcePacks:[") === -1) {
                options += "\n" + desiredLine;
            }
            options = options.replace(/incompatibleResourcePacks:\[[^\]]*\]/, "incompatibleResourcePacks:[]");
            fs.writeFileSync(optionsPath, options);
        }
        const blurLine = "menuBackgroundBlurriness:2";
        if (!options.split("\n").some(l => l === blurLine)) {
            options = options.replace(/menuBackgroundBlurriness:\d+/, blurLine);
            if (!/menuBackgroundBlurriness:\d+/.test(options)) options += "\n" + blurLine;
            fs.writeFileSync(optionsPath, options);
        }
    } catch (_err) {
        // never block a launch over the resource pack
    }
}

// ============================================================
//  METEOR
// ============================================================

// Meteor rewrites its own files when the game exits, and two of ours cannot survive
// a round trip:
//
//   gui/themes/Meteor.nbt - ColorSetting.load() paints the SettingColor in place,
//     and value/defaultValue are the same object, so Setting.wasChanged() is
//     always false and GuiThemes.save() writes back an empty "settings" compound.
//     Next launch would then come up in stock Meteor blue.
//   config.nbt - fine as-is, but only if it exists with the title-screen toggles
//     in it; a fresh gameDir would bring the Meteor credits/splashes back.
//
// So: keep a master copy next to this file and put it back whenever the game has
// dropped it. Plain NBT stores keys as raw UTF-8, so a substring check is enough
// to tell "has our values" from "Meteor emptied it".
const ZELTH_METEOR_FILES = [
    {
        master: "zelth-meteor-theme.nbt",
        dest: ["meteor-client", "gui", "themes", "Meteor.nbt"],
        markers: ["accent-color", "starscript-accessed-objects-color"],
    },
    {
        master: "zelth-meteor-config.nbt",
        dest: ["meteor-client", "config.nbt"],
        markers: ["title-screen-credits", "title-screen-splashes"],
    },
];

function enableZelthMeteor(gameDir) {
    try {
        const modsDir = path.join(gameDir, "mods");
        if (!fs.existsSync(modsDir)) return;
        const hasMeteor = fs.readdirSync(modsDir).some(f => f.startsWith("meteor-client"));
        if (!hasMeteor) return;

        for (const file of ZELTH_METEOR_FILES) {
            const master = path.join(__dirname, file.master);
            if (!fs.existsSync(master)) continue;
            const dest = path.join(gameDir, ...file.dest);
            let restore = !fs.existsSync(dest);
            if (!restore) {
                const current = fs.readFileSync(dest);
                restore = !file.markers.every(m => current.includes(Buffer.from(m)));
            }
            if (!restore) continue;
            fs.mkdirSync(path.dirname(dest), { recursive: true });
            fs.copyFileSync(master, dest);
        }
    } catch (_err) {
        // never block a launch over Meteor's config
    }
}

// ============================================================
//  VERSIONS
// ============================================================

function getVersions() {
    if (!fs.existsSync(VERSIONS_DIR)) return [];
    return fs.readdirSync(VERSIONS_DIR).filter(name => {
        const dir = path.join(VERSIONS_DIR, name);
        if (!fs.statSync(dir).isDirectory()) return false;
        const json = fs.existsSync(path.join(dir, name + ".json"));
        const jar = fs.existsSync(path.join(dir, name + ".jar"));
        return json && jar;
    });
}

function getVersionMeta(versionName) {
    const dir = path.join(VERSIONS_DIR, versionName);
    const jsonPath = path.join(dir, versionName + ".json");
    if (!fs.existsSync(jsonPath)) return null;
    return JSON.parse(fs.readFileSync(jsonPath, "utf-8"));
}

// ============================================================
//  ACCOUNT
// ============================================================

function getAccount() {
    if (!fs.existsSync(PROFILES_JSON)) return null;
    const data = JSON.parse(fs.readFileSync(PROFILES_JSON, "utf-8"));
    const selected = data.selectedAccountUUID
        ? data.accounts?.[data.selectedAccountUUID]
        : Object.values(data.accounts || {})[0];
    return selected || null;
}

// ============================================================
//  RULES
// ============================================================

function isAllowed(rules) {
    if (!rules || rules.length === 0) return true;
    let lastAction = null;
    for (const rule of rules) {
        let matches = true;
        if (rule.os) {
            if (rule.os.name) matches = matches && rule.os.name === OS_NAME;
            if (rule.os.arch) matches = matches && rule.os.arch === "x86_64";
        }
        if (matches) lastAction = rule.action;
    }
    return lastAction === "allow";
}

// ============================================================
//  CLASSPATH
// ============================================================

function isCurrentOsNative(classifier) {
    if (!classifier) return true;
    if (!classifier.startsWith("natives-")) return true;
    return classifier === "natives-" + OS_NAME;
}

function buildClasspath(meta) {
    const cp = [];
    const libs = meta.libraries || [];

    for (const lib of libs) {
        if (!isAllowed(lib.rules)) continue;

        const name = lib.name;
        const parts = name.split(":");
        let group, artifact, version, classifier;

        if (parts.length === 4) {
            group = parts[0]; artifact = parts[1];
            version = parts[2]; classifier = parts[3];
        } else if (parts.length === 3) {
            group = parts[0]; artifact = parts[1];
            version = parts[2]; classifier = null;
        } else {
            continue;
        }

        if (!isCurrentOsNative(classifier)) continue;

        const groupPath = group.split(".").join("/");
        const fileName = classifier
            ? `${artifact}-${version}-${classifier}.jar`
            : `${artifact}-${version}.jar`;
        const fullPath = path.join(LIBS_DIR, groupPath, artifact, version, fileName);

        if (fs.existsSync(fullPath)) cp.push(fullPath);
    }

    const verDir = path.join(VERSIONS_DIR, meta.id);
    const verJar = path.join(verDir, meta.id + ".jar");
    if (fs.existsSync(verJar)) cp.push(verJar);

    return cp;
}

// ============================================================
//  JAVA RUNTIME
// ============================================================

function findRuntime(component) {
    if (!component) return null;
    const base = path.join(RUNTIME_DIR, component);
    if (!fs.existsSync(base)) return null;

    const exact = path.join(base, PLAT_DIR, component, "bin", JAVA_BIN);
    if (fs.existsSync(exact)) return exact;

    let dirs;
    try { dirs = fs.readdirSync(base); } catch { return null; }
    for (const d of dirs) {
        if (d.toLowerCase().includes(PLAT_DIR)) {
            const cand = path.join(base, d, component, "bin", JAVA_BIN);
            if (fs.existsSync(cand)) return cand;
        }
    }
    return null;
}

function resolveJava(meta) {
    const component = meta.javaVersion?.component;
    const requested = meta.javaVersion?.majorVersion
        || meta.javaVersion?.major_version
        || (component ? 17 : 17);

    if (component) {
        const rt = findRuntime(component);
        if (rt) return rt;
    }

    if (requested >= 21) {
        const rt = findRuntime("java-runtime-delta");
        if (rt) return rt;
    }
    if (requested >= 17) {
        const rt = findRuntime("java-runtime-gamma");
        if (rt) return rt;
    }
    if (requested >= 8) {
        const rt = findRuntime("java-runtime-epsilon");
        if (rt) return rt;
    }

    return isWin ? JAVA_BIN : "java";
}

// ============================================================
//  ARGUMENT BUILDING
// ============================================================

function substitute(str, vars) {
    return str.replace(/\$\{([^}]+)\}/g, (m, key) => vars[key] !== undefined ? vars[key] : m);
}

function resolveArgs(entries, vars) {
    const result = [];
    if (!entries) return result;
    for (const entry of entries) {
        if (typeof entry === "string") {
            result.push(substitute(entry, vars));
            continue;
        }
        if (!isAllowed(entry.rules)) continue;
        const raw = entry.value !== undefined ? entry.value : entry.values;
        const vals = Array.isArray(raw) ? raw : [raw];
        for (const v of vals) {
            result.push(substitute(v, vars));
        }
    }
    return result;
}

function stripUnsupportedArgs(args) {
    const QUICKPLAY = ["--quickPlayPath", "--quickPlaySingleplayer", "--quickPlayMultiplayer", "--quickPlayRealms"];
    const out = [];
    for (let i = 0; i < args.length; i++) {
        if (QUICKPLAY.includes(args[i])) { i++; continue; }
        if (args[i] === "--demo") continue;
        out.push(args[i]);
    }
    return out;
}

// ============================================================
//  BUILD FULL COMMAND
// ============================================================

function buildCommand(versionName, opts) {
    opts = opts || {};
    const meta = getVersionMeta(versionName);
    if (!meta) throw new Error("Version not found: " + versionName);

    const account = getAccount();
    const javaPath = resolveJava(meta);
    const cp = buildClasspath(meta);
    const verDir = path.join(VERSIONS_DIR, versionName);

    const nativesDir = path.join(verDir, "natives");
    const gameDir = verDir;
    const uuid = opts.uuid || account?.uuid || "00000000-0000-0000-0000-000000000000";
    const username = opts.username || account?.username || "Player";

    const assetIndexId = meta.assets || "0";

    const vars = {
        natives_directory: nativesDir,
        launcher_name: "zelth",
        launcher_version: "1.0.0",
        classpath: cp.join(path.delimiter),
        version_name: versionName,
        game_directory: gameDir,
        assets_root: ASSETS_DIR,
        assets_index_name: assetIndexId,
        auth_player_name: username,
        auth_uuid: uuid,
        auth_access_token: "0",
        user_type: "tlauncher",
        auth_session: "0",
        client_id: "zelth",
        clientid: "00000000-0000-0000-0000-000000000000",
        auth_xuid: "",
        user_properties: "{}",
        version_type: "zelth",
        resolution_width: "",
        resolution_height: "",
        quickPlayPath: "",
        quickPlaySingleplayer: "",
        quickPlayMultiplayer: "",
        quickPlayRealms: "",
    };

    const jvmArgs = resolveArgs(meta.arguments?.jvm, vars);
    let gameArgs = stripUnsupportedArgs(resolveArgs(meta.arguments?.game, vars));

    const mainClass = meta.mainClass || "net.minecraft.client.main.Main";

    const rawJvm = meta.arguments?.jvm || [];
    const hasCp = rawJvm.some(e =>
        typeof e === "string" ? e.includes("classpath") : JSON.stringify(e).includes("classpath")
    );

    const args = [...jvmArgs];
    if (!hasCp) args.push("-cp", cp.join(path.delimiter));
    args.push(mainClass, ...gameArgs);

    enableZelthMeteor(gameDir);

    return {
        java: javaPath,
        args: args,
        cwd: gameDir,
        username: username,
        version: versionName,
    };
}

// ============================================================
//  LAUNCHER PROCESS
// ============================================================

let gameProcess = null;
let gameCallbacks = { onLog: () => {}, onStatus: () => {}, onExit: () => {} };

function launch(versionName, opts) {
    opts = opts || {};
    if (gameProcess) {
        killGame();
    }

    gameCallbacks = {
        onLog: opts.onLog || (() => {}),
        onStatus: opts.onStatus || (() => {}),
        onExit: opts.onExit || (() => {}),
    };

    try {
        const cmd = buildCommand(versionName, opts);
        enableZelthPack(cmd.cwd);
        gameCallbacks.onStatus("launching");
        gameCallbacks.onLog(`Launching ${cmd.version} with ${cmd.username}...`);
        gameCallbacks.onLog(`Java: ${cmd.java}`);

        gameProcess = spawn(cmd.java, cmd.args, {
            cwd: cmd.cwd,
            stdio: ["pipe", "pipe", "pipe"],
            windowsHide: true,
            env: { ...process.env, HOME: HOME },
        });
        rpcPlaying(versionName);

        gameProcess.stdout.on("data", d => {
            gameCallbacks.onLog(d.toString().trim());
        });

        gameProcess.stderr.on("data", d => {
            gameCallbacks.onLog(d.toString().trim());
        });

        gameProcess.on("error", err => {
            gameCallbacks.onLog("ERROR: " + err.message);
            gameCallbacks.onStatus("error");
            gameProcess = null;
        });

        gameProcess.on("exit", code => {
            const msg = code === 0 ? "Minecraft exited" : `Minecraft exited with code ${code}`;
            gameCallbacks.onLog(msg);
            gameCallbacks.onStatus(code === 0 ? "exit" : "error");
            gameProcess = null;
            rpcMenu();
            gameCallbacks.onExit(code);
        });

        return { pid: gameProcess.pid, version: versionName };
    } catch (err) {
        gameCallbacks.onLog("ERROR: " + err.message);
        gameCallbacks.onStatus("error");
        throw err;
    }
}

function killGame() {
    if (gameProcess) {
        if (isWin) {
            try { spawn("taskkill", ["/pid", String(gameProcess.pid), "/T", "/F"], { windowsHide: true }); }
            catch (_e) { /* ignore */ }
            gameProcess = null;
        } else {
            gameProcess.kill("SIGTERM");
            setTimeout(() => {
                if (gameProcess) gameProcess.kill("SIGKILL");
            }, 3000);
            gameProcess = null;
        }
    }
}

function isRunning() {
    return gameProcess !== null;
}

module.exports = {
    getVersions,
    getVersionMeta,
    getAccount,
    buildCommand,
    launch,
    killGame,
    isRunning,
    rpcPlaying,
    rpcMenu,
    rpcStop,
    discSetPresence,
};
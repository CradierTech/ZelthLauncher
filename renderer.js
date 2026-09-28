const THEMES = {
    "Aero": {
        background: "#0b0f26",
        panel: "rgba(22,18,62,0.75)",
        panel2: "rgba(255,255,255,0.06)",
        button: "rgba(255,255,255,0.07)",
        hover: "rgba(124,168,255,0.18)",
        text: "#F2F8EE",
        muted: "rgba(242,248,238,0.55)",
        accent: "#7ec8f7"
    },
    "Dark": {
        background: "#0d0d12",
        panel: "rgba(26,26,32,0.80)",
        panel2: "rgba(255,255,255,0.06)",
        button: "rgba(255,255,255,0.07)",
        hover: "rgba(255,255,255,0.14)",
        text: "#ffffff",
        muted: "rgba(255,255,255,0.55)",
        accent: "#8da4bd"
    },
    "Light": {
        background: "#eef0f6",
        panel: "rgba(255,255,255,0.85)",
        panel2: "rgba(0,0,0,0.04)",
        button: "rgba(0,0,0,0.05)",
        hover: "rgba(0,0,0,0.09)",
        text: "#15161c",
        muted: "rgba(20,22,32,0.6)",
        accent: "#2563eb"
    },
    "Purple": {
        background: "#120b1e",
        panel: "rgba(35,20,60,0.80)",
        panel2: "rgba(255,255,255,0.06)",
        button: "rgba(255,255,255,0.07)",
        hover: "rgba(192,132,252,0.20)",
        text: "#ffffff",
        muted: "rgba(255,255,255,0.55)",
        accent: "#a855f7"
    },
    "MC": {
        background: "#0b0f26",
        panel: "rgba(0,0,0,0.45)",
        panel2: "rgba(255,255,255,0.15)",
        button: "rgba(255,255,255,0.10)",
        hover: "rgba(255,255,255,0.20)",
        text: "#ffffff",
        muted: "rgba(255,255,255,0.6)",
        accent: "#9adcff"
    }
};

const THEME_LAYOUTS = {
    "Aero": "aero",
    "Dark": "aero",
    "Light": "aero",
    "Purple": "aero",
    "MC": "mc"
};

const THEME_NAMES = Object.keys(THEMES);
let currentTheme = "Aero";
let selectedVersion = null;

function applyTheme(name) {
    const t = THEMES[name];
    const root = document.documentElement;

    root.style.setProperty("--background", t.background);
    root.style.setProperty("--panel", t.panel);
    root.style.setProperty("--panel2", t.panel2);
    root.style.setProperty("--button", t.button);
    root.style.setProperty("--hover", t.hover);
    root.style.setProperty("--text", t.text);
    root.style.setProperty("--muted", t.muted);
    root.style.setProperty("--accent", t.accent);

    document.body.className = `theme-${THEME_LAYOUTS[name] || "aero"}`;
}

function showIntro() {
    document.getElementById("intro").classList.remove("hidden");
    document.getElementById("main").classList.add("hidden");
}

function showMain() {
    const intro = document.getElementById("intro");
    intro.classList.add("fade-out");
    const main = document.getElementById("main");
    main.classList.remove("hidden");
    requestAnimationFrame(() => main.classList.add("fade-in"));
}

// ==================== SETTINGS ====================

function buildThemeList() {
    const list = document.getElementById("themeList");
    list.innerHTML = "";

    THEME_NAMES.forEach(name => {
        const btn = document.createElement("button");
        btn.className = "theme-option";
        btn.dataset.theme = name;

        const t = THEMES[name];
        const swatch = document.createElement("span");
        swatch.className = "theme-swatch";
        swatch.style.background = name === "MC"
            ? "linear-gradient(135deg, #2a3f86, #7fb3f5, #9adcff)"
            : t.accent;

        const label = document.createElement("span");
        label.className = "theme-option-label";
        label.textContent = name;

        btn.appendChild(swatch);
        btn.appendChild(label);

        btn.addEventListener("click", () => {
            currentTheme = name;
            applyTheme(currentTheme);
            updateThemeList();
        });

        list.appendChild(btn);
    });
}

function updateThemeList() {
    document.querySelectorAll(".theme-option").forEach(btn => {
        btn.classList.toggle("active", btn.dataset.theme === currentTheme);
    });
}

function openSettings() {
    buildThemeList();
    updateThemeList();
    document.getElementById("settingsOverlay").classList.remove("hidden");
}

function closeSettings() {
    document.getElementById("settingsOverlay").classList.add("hidden");
}

// ==================== VERSIONS ====================

async function openVersionPicker() {
    const list = document.getElementById("versionList");
    list.innerHTML = '<div class="version-loading">Loading versions...</div>';
    document.getElementById("versionOverlay").classList.remove("hidden");

    try {
        const versions = await window.desktop.listVersions();
        renderVersionList(versions);
    } catch (err) {
        list.innerHTML = `<div class="version-error">${err.message || "Failed to load versions"}</div>`;
    }
}

function closeVersionPicker() {
    document.getElementById("versionOverlay").classList.add("hidden");
}

function renderVersionList(versions) {
    const list = document.getElementById("versionList");
    list.innerHTML = "";

    if (!versions || versions.length === 0) {
        list.innerHTML = '<div class="version-error">No Minecraft versions installed.<br>Install them via TLauncher first.</div>';
        return;
    }

    versions.forEach(v => {
        const type = v.jar.type === "modified" ? "Modified" : (v.jar.type || "Release");
        const btn = document.createElement("button");
        btn.className = "version-option";
        btn.dataset.version = v.name;

        const nameEl = document.createElement("span");
        nameEl.className = "version-name";
        nameEl.textContent = v.name;

        const typeEl = document.createElement("span");
        typeEl.className = "version-type";
        typeEl.textContent = type;

        btn.appendChild(nameEl);
        btn.appendChild(typeEl);

        btn.addEventListener("click", () => {
            document.querySelectorAll(".version-option").forEach(b => b.classList.remove("active"));
            btn.classList.add("active");
            selectedVersion = v.name;
            document.getElementById("accountRow").classList.remove("hidden");
            document.getElementById("chooseBtn").classList.add("hidden");
            document.getElementById("playBtn").classList.remove("hidden");
            closeVersionPicker();
        });

        list.appendChild(btn);
    });
}

// ==================== LAUNCH ====================

function appendLog(line) {
    const box = document.getElementById("logBox");
    const div = document.createElement("div");
    div.textContent = line;
    box.appendChild(div);
    box.scrollTop = box.scrollHeight;
}

function setStatus(text, error) {
    const line = document.getElementById("statusLine");
    line.textContent = text;
    line.classList.toggle("error", !!error);
}

async function handleLaunch() {
    if (!selectedVersion || !window.desktop?.launchGame) return;

    const input = document.getElementById("usernameInput");
    const username = (input.value || "").trim().replace(/[^a-zA-Z0-9_]/g, "") || "Player";

    const status = document.getElementById("launchStatus");
    status.classList.remove("hidden");
    document.getElementById("logBox").innerHTML = "";
    setStatus("Launching...");
    document.getElementById("playBtn").disabled = true;
    input.disabled = true;

    const result = await window.desktop.launchGame(selectedVersion, { username });
    if (!result.success) {
        setStatus(`Launch failed: ${result.error}`, true);
        document.getElementById("playBtn").disabled = false;
        input.disabled = false;
    }

    window.desktop.onLog(line => {
        if (line.trim()) appendLog(line);
    });

    window.desktop.onStatus(statusText => {
        if (statusText === "launching") setStatus("Launching Minecraft...");
        else if (statusText === "exit") {
            setStatus("Minecraft exited.");
            document.getElementById("playBtn").disabled = false;
            document.getElementById("usernameInput").disabled = false;
        } else if (statusText === "error") {
            setStatus("Launch failed.", true);
            document.getElementById("playBtn").disabled = false;
            document.getElementById("usernameInput").disabled = false;
        }
    });
}

// ==================== LOAD ====================

window.addEventListener("DOMContentLoaded", () => {
    applyTheme(currentTheme);
    showIntro();
    setTimeout(showMain, 1800);

    document.getElementById("closeBtn").addEventListener("click", () => {
        if (window.desktop?.close) {
            window.desktop.close();
        }
    });

    document.getElementById("quitBtn").addEventListener("click", () => {
        if (window.desktop?.close) {
            window.desktop.close();
        }
    });

    document.getElementById("settingsBtn").addEventListener("click", openSettings);
    document.getElementById("settingsCloseBtn").addEventListener("click", closeSettings);

    document.getElementById("chooseBtn").addEventListener("click", openVersionPicker);
    document.getElementById("versionCloseBtn").addEventListener("click", closeVersionPicker);
    document.getElementById("playBtn").addEventListener("click", handleLaunch);
});
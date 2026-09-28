const { app, BrowserWindow, ipcMain } = require("electron");
const path = require("path");
const launcher = require("./launcher");

app.disableHardwareAcceleration();

function createWindow() {
    const win = new BrowserWindow({
        width: 1200,
        height: 700,
        frame: false,
        transparent: true,
        resizable: false,
        backgroundColor: "#00000000",
        icon: path.join(__dirname, "zelth.png"),
        webPreferences: {
            preload: path.join(__dirname, "preload.js"),
            contextIsolation: true,
            nodeIntegration: false
        }
    });

    win.loadFile("index.html");
    return win;
}

function sendToRenderer(channel, ...args) {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) win.webContents.send(channel, ...args);
}

app.whenReady().then(() => {
    ipcMain.handle("app-close", () => {
        app.quit();
    });

    ipcMain.handle("get-versions", () => {
        return launcher.getVersions().map(name => ({
            name,
            jar: launcher.getVersionMeta(name) || {}
        }));
    });

    ipcMain.handle("get-account", () => {
        const a = launcher.getAccount();
        return a ? { username: a.username, uuid: a.uuid } : null;
    });

    ipcMain.handle("launch-game", (_e, versionName, opts) => {
        try {
            const result = launcher.launch(versionName, {
                username: opts?.username,
                onLog: line => sendToRenderer("game-log", line),
                onStatus: status => sendToRenderer("game-status", status),
                onExit: code => sendToRenderer("game-exit", code),
            });
            return { success: true, ...result };
        } catch (err) {
            return { success: false, error: err.message };
        }
    });

    ipcMain.handle("close-game", () => {
        launcher.killGame();
        return true;
    });

    ipcMain.handle("game-running", () => {
        return launcher.isRunning();
    });

    createWindow();
    launcher.rpcMenu();

    app.on("activate", () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createWindow();
        }
    });
});

app.on("window-all-closed", () => {
    app.quit();
});

app.on("before-quit", () => {
    launcher.rpcStop();
    launcher.killGame();
});
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld(
    "desktop",
    {
        close: () => ipcRenderer.invoke("app-close"),

        listVersions: () => ipcRenderer.invoke("get-versions"),

        getAccount: () => ipcRenderer.invoke("get-account"),

        launchGame: (version, opts) => ipcRenderer.invoke("launch-game", version, opts),

        closeGame: () => ipcRenderer.invoke("close-game"),

        isGameRunning: () => ipcRenderer.invoke("game-running"),

        onLog: (cb) => {
            ipcRenderer.on("game-log", (_e, line) => cb(line));
        },

        onStatus: (cb) => {
            ipcRenderer.on("game-status", (_e, status) => cb(status));
        },

        onExit: (cb) => {
            ipcRenderer.on("game-exit", (_e, code) => cb(code));
        }
    }
);
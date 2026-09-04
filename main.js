const { app, BrowserWindow, screen, Menu, Tray, nativeImage, protocol, net, ipcMain } = require('electron');
const { buildControlMenu, setDisabledFlag } = require('./lib/control-menu');
const petSettings = require('./lib/settings');
const { WIN_SIZE, WIN_MARGIN, cornerPosition } = require('./lib/window-position');
const path = require('path');
const fs = require('fs');
const {
  isValidSessionId,
  createSessionTracker,
  buildSessionStates,
  EVENT_TO_ANIM,
} = require('./lib/session-tracker');
const { JsonlWatcher } = require('./lib/jsonl-watcher');

let win;
let petVisible = true;
const subAgentWindows = new Map(); // session_id → BrowserWindow
const subAgentCreatedAt = new Map(); // session_id → creation timestamp (ms)
const dummySessionIds = new Set(); // dev-only: protected from sync cleanup
const MAX_SUB_AGENT_WINDOWS = 5;
const SUB_AGENT_BASE_Y_OFFSET = 170; // px from bottom of work area to main pet
const SUB_AGENT_TTL_MS = 10 * 60 * 1000; // 10 min — destroy stale windows if SubagentStop never fired

// --- Character system ---
// Per-character asset maps: canonical name → bundled filename
const BUNDLED_CHARS = {
  orc: {
    'sprite-atlas.png': 'orc-sprite-atlas.png',
    'borders.png':      'orc-borders.png',
    'bg.png':           'bg-pixel.png',
    'dock-icon.png':    'orc-dock-icon.png',
  },
  capybara: {
    'sprite-atlas.png': 'capybara-sprite-atlas.png',
    'borders.png':      'capybara-borders.png',
    'dock-icon.png':    'capybara-dock-icon.png',
  },
  'hello-kitty': {
    'sprite-atlas.png': 'hello-kitty-sprite-atlas.png',
    'borders.png':      'hello-kitty-borders.png',
    'dock-icon.png':    'hello-kitty-dock-icon.png',
  },
};

function parseArgPath(flag) {
  const i = process.argv.indexOf(flag);
  return (i !== -1 && process.argv[i + 1]) ? process.argv[i + 1] : null;
}

const argCharacter = parseArgPath('--character');

function loadPetConfig() {
  try {
    return JSON.parse(fs.readFileSync(
      path.join(app.getPath('userData'), 'peon-pet-config.json'), 'utf8'
    ));
  } catch { return {}; }
}

const MIN_PET_SIZE = 120;
const MAX_PET_SIZE = 420;

function savePetConfig(mutate) {
  const cfg = loadPetConfig();
  mutate(cfg);
  try {
    fs.writeFileSync(
      path.join(app.getPath('userData'), 'peon-pet-config.json'),
      JSON.stringify(cfg, null, 2) + '\n', 'utf8'
    );
  } catch { /* best effort */ }
}

function clampSize(n) {
  return Math.max(MIN_PET_SIZE, Math.min(MAX_PET_SIZE, Math.round(n)));
}

function savedPetSize() {
  const n = Number(loadPetConfig().size);
  return Number.isFinite(n) ? clampSize(n) : null;
}

function registerCharacterProtocol() {
  const cfg = loadPetConfig();
  const char = argCharacter || cfg.character || 'orc';
  const assetsDir = path.join(__dirname, 'renderer', 'assets');
  const customCharDir = path.join(app.getPath('userData'), 'characters', char);
  const charMap = BUNDLED_CHARS[char] || {};

  protocol.handle('peon-asset', (request) => {
    const filename = new URL(request.url).hostname;
    // 1. User-installed character dir
    if (fs.existsSync(path.join(customCharDir, filename))) {
      return net.fetch('file://' + path.join(customCharDir, filename));
    }
    // 2. Bundled map: char-specific → orc fallback → filename as-is
    const mapped = charMap[filename] || BUNDLED_CHARS.orc[filename] || filename;
    return net.fetch('file://' + path.join(assetsDir, mapped));
  });

  return { char, assetsDir, customCharDir };
}

const tracker = createSessionTracker();
const sessionCwds = new Map();  // session_id → cwd string
const remoteSessionIds = new Set();
const remoteLastEvents = new Map();  // session_id → last event string
const SESSION_PRUNE_MS = 10 * 60 * 1000;  // 10min — prune cold sessions
const HOT_MS  = 30 * 1000;       // 30s  — actively working right now
const WARM_MS = 2 * 60 * 1000;   // 2min — session open but idle

async function readRemoteState(baseUrl) {
  try {
    const res = await net.fetch(`${baseUrl}/state`, { signal: AbortSignal.timeout(150) });
    if (!res.ok) return null;
    return res.json();
  } catch {
    return null;
  }
}

function repositionSubAgentWindows() {
  const { height } = screen.getPrimaryDisplay().workAreaSize;
  let i = 0;
  for (const [, subWin] of subAgentWindows) {
    if (!subWin.isDestroyed()) {
      const mainY = height - SUB_AGENT_BASE_Y_OFFSET;
      subWin.setPosition(20, mainY - (i + 1) * 100);
      i++;
    }
  }
}

function createSubAgentWindow(sessionId) {
  if (subAgentWindows.size >= MAX_SUB_AGENT_WINDOWS) return;
  if (subAgentWindows.has(sessionId)) return;

  const { height } = screen.getPrimaryDisplay().workAreaSize;
  const idx = subAgentWindows.size;

  const subWin = new BrowserWindow({
    width: 100,
    height: 100,
    x: 20,
    y: (height - SUB_AGENT_BASE_Y_OFFSET) - (idx + 1) * 100,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    focusable: false,
    hasShadow: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  subWin.setIgnoreMouseEvents(true);

  subWin.loadFile('renderer/index.html');

  subWin.webContents.once('did-finish-load', () => {
    subWin.webContents.send('peon-config', { size: 100, subAgent: true });
    subWin.webContents.send('peon-event', { anim: 'waking', event: 'SessionStart' });
    startMouseTrackingForWindow(subWin);
  });

  // Don't quit app when sub-agent window closes
  subWin.on('closed', () => {
    subAgentWindows.delete(sessionId);
    subAgentCreatedAt.delete(sessionId);
    repositionSubAgentWindows();
  });

  if (!petVisible) subWin.hide();

  subAgentWindows.set(sessionId, subWin);
  subAgentCreatedAt.set(sessionId, Date.now());
}

function destroySubAgentWindow(sessionId) {
  const subWin = subAgentWindows.get(sessionId);
  if (subWin && !subWin.isDestroyed()) {
    subWin.destroy();
  }
  subAgentWindows.delete(sessionId);
  subAgentCreatedAt.delete(sessionId);
  repositionSubAgentWindows();
}

function handleSessionEvent({ sessionId, event, cwd, timestamp }) {
  if (!isValidSessionId(sessionId)) return;

  const now = Date.now();

  // SessionCwd: just update the display name, no tracker change
  if (event === 'SessionCwd') {
    if (cwd) {
      sessionCwds.set(sessionId, cwd);
      sendSessionUpdate(now);
    }
    return;
  }

  if (event === 'SessionEnd') {
    tracker.remove(sessionId);
    sessionCwds.delete(sessionId);
  } else if (event === 'SessionSeen') {
    // File existed at startup: register with actual file mtime, no animation, no dedup
    tracker.update(sessionId, timestamp || now);
    if (cwd) sessionCwds.set(sessionId, cwd);
  } else {
    if (event === 'SessionStart') {
      // Deduplicate /resume: if exactly one session was seen <5s ago, replace it
      const existing = tracker.entries();
      const isNew = !existing.some(([id]) => id === sessionId);
      if (isNew && existing.length === 1) {
        const [oldId, oldTime] = existing[0];
        if ((now - oldTime) < 5000) tracker.remove(oldId);
      }
    }
    tracker.update(sessionId, now);
    if (cwd) sessionCwds.set(sessionId, cwd);
  }

  tracker.prune(now - SESSION_PRUNE_MS);
  for (const id of sessionCwds.keys()) {
    if (!tracker.entries().some(([sid]) => sid === id)) sessionCwds.delete(id);
  }

  sendSessionUpdate(now);

  const anim = EVENT_TO_ANIM[event];
  if (anim && win && !win.isDestroyed()) {
    win.webContents.send('peon-event', { anim, event });
  }
}

function sendSessionUpdate(now) {
  if (!win || win.isDestroyed()) return;
  const sessions = buildSessionStates(tracker.entries(), now, HOT_MS, WARM_MS, 10);
  win.webContents.send('session-update', {
    sessions: sessions.map(s => ({
      ...s,
      cwd: sessionCwds.get(s.id) || null,
      name: sessionCwds.get(s.id) ? path.basename(sessionCwds.get(s.id)) : null,
    })),
  });
}

function syncRemoteSessionsToTracker(state) {
  if (!state || !state.sessions) return;
  const now = Date.now();
  const incoming = state.sessions;

  for (const [sid, entry] of Object.entries(incoming)) {
    if (!isValidSessionId(sid)) continue;
    tracker.update(sid, entry.timestamp * 1000);  // relay uses Unix seconds
    if (entry.cwd) sessionCwds.set(sid, entry.cwd);
    remoteSessionIds.add(sid);
    const anim = EVENT_TO_ANIM[entry.event];
    if (anim && entry.event !== remoteLastEvents.get(sid)) {
      remoteLastEvents.set(sid, entry.event);
      if (win && !win.isDestroyed()) win.webContents.send('peon-event', { anim, event: entry.event });
    }
  }

  for (const sid of [...remoteSessionIds]) {
    if (!incoming[sid]) {
      tracker.remove(sid);
      sessionCwds.delete(sid);
      remoteSessionIds.delete(sid);
      remoteLastEvents.delete(sid);
    }
  }

  sendSessionUpdate(now);
}

function startPolling() {
  const cfg = loadPetConfig();
  const remoteUrl = cfg.remoteUrl || 'http://127.0.0.1:19998';

  const watcher = new JsonlWatcher();

  watcher.on('session-event', handleSessionEvent);
  watcher.on('subagent-event', ({ parentToolId, event }) => {
    if (event === 'SubagentStart') createSubAgentWindow(parentToolId);
    if (event === 'SubagentStop')  destroySubAgentWindow(parentToolId);
  });

  watcher.start();

  // Heartbeat: refresh session hot/warm status so the pet correctly decays.
  // Sessions with pending tools are kept hot so the pet stays awake during long tool runs.
  // Also runs the TTL sweep for sub-agent windows whose SubagentStop never fired.
  setInterval(() => {
    const now = Date.now();
    const expired = [...subAgentCreatedAt.entries()]
      .filter(([sid, createdAt]) => now - createdAt > SUB_AGENT_TTL_MS && !dummySessionIds.has(sid))
      .map(([sid]) => sid);
    for (const sid of expired) destroySubAgentWindow(sid);

    if (tracker.entries().length === 0) return;
    for (const sessionId of watcher.getActiveSessionIds()) {
      tracker.update(sessionId, now);
    }
    sendSessionUpdate(now);
  }, 5000);

  // Remote relay sync (less frequent, not time-critical)
  setInterval(async () => {
    syncRemoteSessionsToTracker(await readRemoteState(remoteUrl));
  }, 5000);
}

// --- Drag state ---
let isDragging = false;
let dragOffsetX = 0;
let dragOffsetY = 0;
let ignoringMouse = true;  // tracks last setIgnoreMouseEvents value

ipcMain.on('drag-start', () => {
  if (!win || win.isDestroyed()) return;
  isDragging = true;
  const { x: cx, y: cy } = screen.getCursorScreenPoint();
  const [wx, wy] = win.getPosition();
  dragOffsetX = cx - wx;
  dragOffsetY = cy - wy;
  if (ignoringMouse) {
    win.setIgnoreMouseEvents(false);
    ignoringMouse = false;
  }
});

ipcMain.on('drag-stop', () => {
  isDragging = false;
});

// Corner resize: the grabbed corner follows the cursor and the opposite one
// stays pinned, which is what makes a corner-docked widget feel right.
let isResizing = false;
let resizeAnchorX = 0;
let resizeAnchorY = 0;
let anchorIsLeft = true;
let anchorIsTop = true;

let resizeStartSize = WIN_SIZE;
let signX = 1;
let signY = 1;

ipcMain.on('resize-start', (_e, corner) => {
  if (!win || win.isDestroyed()) return;
  const [wx, wy] = win.getPosition();
  const [ww, wh] = win.getSize();
  anchorIsLeft = corner === 'tr' || corner === 'br';   // grabbed right -> anchor left
  anchorIsTop  = corner === 'bl' || corner === 'br';   // grabbed bottom -> anchor top
  resizeAnchorX = anchorIsLeft ? wx : wx + ww;
  resizeAnchorY = anchorIsTop  ? wy : wy + wh;
  // Moving away from the anchor grows the window
  signX = anchorIsLeft ? 1 : -1;
  signY = anchorIsTop ? 1 : -1;
  resizeStartSize = ww;
  isResizing = true;
  if (ignoringMouse) {
    win.setIgnoreMouseEvents(false);
    ignoringMouse = false;
  }
});

// Deltas are CSS pixels from the renderer, the same unit as window bounds, so
// no screen-coordinate conversion is needed.
ipcMain.on('resize-move', (_e, { dx, dy }) => {
  if (!isResizing || !win || win.isDestroyed()) return;
  const size = clampSize(resizeStartSize + Math.max(dx * signX, dy * signY));
  const nx = anchorIsLeft ? resizeAnchorX : resizeAnchorX - size;
  const ny = anchorIsTop  ? resizeAnchorY : resizeAnchorY - size;
  const [cw] = win.getSize();
  const [px, py] = win.getPosition();
  if (size === cw && nx === px && ny === py) return;
  win.setBounds({ x: nx, y: ny, width: size, height: size });
  win.webContents.send('pet-resize', { size });
});

ipcMain.on('resize-stop', () => {
  if (!isResizing) return;
  isResizing = false;
  if (win && !win.isDestroyed()) {
    const [w] = win.getSize();
    savePetConfig(cfg => { cfg.size = clampSize(w); });
    refreshMenus();
  }
});

// Used by the tray menu presets; keeps the window anchored where it already is.
function applyPetSize(size) {
  if (!win || win.isDestroyed()) return;
  const next = clampSize(size);
  const [wx, wy] = win.getPosition();
  win.setBounds({ x: wx, y: wy, width: next, height: next });
  win.webContents.send('pet-resize', { size: next });
  savePetConfig(cfg => { cfg.size = next; });
  refreshMenus();
}

// Poll cursor position to enable mouse events only when hovering the window.
// This lets the renderer receive mousemove for tooltips while keeping click-through.
// During drag, moves the window to follow the cursor.
function startMouseTrackingForWindow(targetWin) {
  const intervalId = setInterval(() => {
    if (!targetWin || targetWin.isDestroyed()) {
      clearInterval(intervalId);
      return;
    }
    const { x: cx, y: cy } = screen.getCursorScreenPoint();

    // Resizing is driven by renderer pointermove, not by this poll
    if (targetWin === win && isResizing) return;

    if (targetWin === win && isDragging) {
      const nx = cx - dragOffsetX;
      const ny = cy - dragOffsetY;
      const [wx, wy] = targetWin.getPosition();
      if (nx !== wx || ny !== wy) targetWin.setPosition(nx, ny);
      return;
    }

    const [wx, wy] = targetWin.getPosition();
    const [ww, wh] = targetWin.getSize();
    const inside = cx >= wx && cx <= wx + ww && cy >= wy && cy <= wy + wh;
    if (targetWin === win) {
      if (inside !== !ignoringMouse) {
        targetWin.setIgnoreMouseEvents(!inside);
        ignoringMouse = !inside;
      }
    } else {
      targetWin.setIgnoreMouseEvents(!inside);
    }
  }, 50);
}

let tray = null;
let trayIconPath = null;

function togglePetVisibility() {
  if (!win || win.isDestroyed()) return;
  if (petVisible) {
    win.hide();
    for (const [, subWin] of subAgentWindows) {
      if (!subWin.isDestroyed()) subWin.hide();
    }
  } else {
    win.show();
    for (const [, subWin] of subAgentWindows) {
      if (!subWin.isDestroyed()) subWin.show();
    }
  }
  petVisible = !petVisible;
  refreshMenus();
}

// "Salir" means off until re-enabled, otherwise the watch agent would just
// bring the orc back within its next tick.
function quitForGood() {
  setDisabledFlag(true);          // legacy flag, still honoured by the watcher
  petSettings.writeMode('off');
  app.quit();
}

function buildDockMenu() {
  const [w] = win && !win.isDestroyed() ? win.getSize() : [WIN_SIZE];
  return buildControlMenu({
    petVisible,
    togglePet: togglePetVisibility,
    refresh: refreshMenus,
    quitApp: quitForGood,
    petSize: w,
    setPetSize: applyPetSize,
    openSettings,
  });
}

function refreshMenus() {
  // A Menu instance is not shared between the dock and the tray on purpose:
  // each surface owns its own, so state changes cannot cross-invalidate them.
  if (process.platform === 'darwin' && app.dock) app.dock.setMenu(buildDockMenu());
  if (tray && !tray.isDestroyed()) {
    tray.setContextMenu(buildDockMenu());
    tray.setToolTip('Peon Pet');
  }
}

let settingsWin = null;

function openSettings() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    return;
  }
  settingsWin = new BrowserWindow({
    width: 460,
    height: 660,
    title: 'Ajustes de Peon Pet',
    resizable: false,
    minimizable: false,
    maximizable: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'settings-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  settingsWin.loadFile('renderer/settings.html');
  settingsWin.webContents.on('console-message', (_e, lvl, msg) => console.log('[settings]', msg));
  settingsWin.webContents.on('did-fail-load', (_e, code, desc) => console.log('[settings] FALLO', code, desc));
  settingsWin.webContents.on('did-finish-load', () => console.log('[settings] cargada OK'));
  settingsWin.once('ready-to-show', () => settingsWin.show());
  settingsWin.on('closed', () => { settingsWin = null; });
}

ipcMain.handle('settings:get', () => {
  const [w] = win && !win.isDestroyed() ? win.getSize() : [WIN_SIZE];
  return petSettings.getState({ size: w, petVisible });
});

ipcMain.handle('settings:set', async (_e, patch) => {
  await petSettings.applyPatch(patch, {
    setPetSize: applyPetSize,
    setPetVisible: (visible) => { if (visible !== petVisible) togglePetVisibility(); },
  });
  refreshMenus();
});

ipcMain.on('settings:close', () => {
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.close();
});

function createTray(iconPath) {
  if (tray) return;
  trayIconPath = iconPath;
  let img = nativeImage.createFromPath(iconPath);
  if (!img.isEmpty()) img = img.resize({ width: 18, height: 18 });
  tray = new Tray(img);
  tray.setToolTip('Peon Pet');
  refreshMenus();
  console.log(`[peon-pet] tray listo (icono ${img.isEmpty() ? 'VACIO' : img.getSize().width + 'px'})`);
}


function createWindow() {
  const { width, height } = screen.getPrimaryDisplay().workAreaSize;
  const cfg = loadPetConfig();
  const { x, y } = cornerPosition(cfg.corner, width, height);

  const petSize = savedPetSize() || WIN_SIZE;

  win = new BrowserWindow({
    width: petSize,
    height: petSize,
    x,
    y,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    focusable: false,
    hasShadow: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.setIgnoreMouseEvents(true);

  win.loadFile('renderer/index.html');

  if (process.platform === 'darwin') {
    const cfg = loadPetConfig();
    const char = argCharacter || cfg.character || 'orc';
    const assetsDir = path.join(__dirname, 'renderer', 'assets');
    const customIcon = path.join(app.getPath('userData'), 'characters', char, 'dock-icon.png');
    const charMap = BUNDLED_CHARS[char] || {};
    const iconFile = charMap['dock-icon.png'] || BUNDLED_CHARS.orc['dock-icon.png'];
    const iconPath = fs.existsSync(customIcon) ? customIcon : path.join(assetsDir, iconFile);
    app.dock.setIcon(iconPath);
    createTray(iconPath);
    refreshMenus();
  }

  if (process.argv.includes('--dev')) {
    win.webContents.openDevTools({ mode: 'detach' });
  }

  // Reset drag if renderer reloads or crashes
  win.webContents.on('did-finish-load', () => { isDragging = false; });

  // Clean up sub-agent windows when main window closes
  win.on('closed', () => {
    for (const subWin of subAgentWindows.values()) {
      if (!subWin.isDestroyed()) subWin.destroy();
    }
    subAgentWindows.clear();
  });

  // Start polling once window is ready
  win.webContents.once('did-finish-load', () => {
    if (petSize !== WIN_SIZE) win.webContents.send('pet-resize', { size: petSize });
    console.log(`[peon-pet] ventana ${petSize}px (guardado: ${savedPetSize() ?? 'ninguno'})`);
    startPolling();
    startMouseTrackingForWindow(win);

    // Dev-only: spawn dummy sub-agents for visual testing
    if (process.argv.includes('--spawn-test')) {
      const dummyIds = ['dummy-1', 'dummy-2', 'dummy-3'];
      for (const id of dummyIds) {
        dummySessionIds.add(id);
        createSubAgentWindow(id);
      }
      setTimeout(() => {
        for (const id of dummyIds) {
          dummySessionIds.delete(id);
          destroySubAgentWindow(id);
        }
      }, 3000);
    }
  });
}

app.setName('Peon Pet');

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.whenReady().then(() => {
    setDisabledFlag(false);
    if (petSettings.readMode() === 'off') petSettings.writeMode('follow');
    registerCharacterProtocol();
    createWindow();
  });
  app.on('window-all-closed', () => app.quit());
}

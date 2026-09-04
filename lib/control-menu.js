// Control menu for the tray icon and the dock icon.
//
// peon-ping keeps all of its state in plain files, so the menu reads them
// directly to render the current state and shells out to the `peon` CLI to
// change it. That keeps this file a thin view over peon-ping instead of a
// second source of truth.
const { Menu, shell } = require('electron');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const PEON_DIR = path.join(HOME, '.claude', 'hooks', 'peon-ping');
const CONFIG_PATH = path.join(PEON_DIR, 'config.json');
const PAUSED_FILE = path.join(PEON_DIR, '.paused');
const PACKS_DIR = path.join(HOME, '.openpeon', 'packs');
const DISABLED_FLAG = path.join(HOME, '.openpeon', 'pet-disabled');

// launchd gives the app a bare PATH, so the CLI has to be found by absolute path
const PEON_CANDIDATES = [
  '/opt/homebrew/bin/peon',
  '/usr/local/bin/peon',
  path.join(HOME, '.local', 'bin', 'peon'),
];

function peonBin() {
  return PEON_CANDIDATES.find(p => fs.existsSync(p)) || null;
}

function runPeon(args, done) {
  const bin = peonBin();
  if (!bin) return done && done(new Error('peon CLI not found'));
  execFile(bin, args, { timeout: 10000 }, err => done && done(err));
}

function readConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch {
    return {};
  }
}

// Only the keys we own are rewritten; everything else is preserved as-is.
function writeConfig(mutate) {
  const cfg = readConfig();
  mutate(cfg);
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
}

function isPaused() {
  return fs.existsSync(PAUSED_FILE);
}

function installedPacks() {
  try {
    return fs.readdirSync(PACKS_DIR).filter(name =>
      fs.existsSync(path.join(PACKS_DIR, name, 'openpeon.json'))
    );
  } catch {
    return [];
  }
}

function packLabel(name) {
  try {
    const m = JSON.parse(fs.readFileSync(path.join(PACKS_DIR, name, 'openpeon.json'), 'utf8'));
    return m.display_name || name;
  } catch {
    return name;
  }
}

// Curated presets rather than all ~37 packs: a menu is for choosing, not browsing.
const VOICE_PRESETS = [
  'campesino_es',
  'peasant_es',
  'peon_es',
  'peasant',
  'peon',
  'glados',
  'tf2_engineer',
  'sopranos',
  'sc_kerrigan',
  'duke_nukem',
];

const EVENT_LABELS = [
  ['task.complete', 'Terminé'],
  ['input.required', 'Te necesito'],
  ['task.error', 'Se rompió'],
  ['resource.limit', 'Sin nafta'],
  ['session.start', 'Al abrir sesión'],
  ['task.acknowledge', 'Al arrancar tarea'],
  ['user.spam', 'Si te apuro'],
];

const VOLUMES = [0.25, 0.5, 0.75, 1.0];

const SIZES = [
  [140, 'Pequeño'],
  [200, 'Mediano'],
  [280, 'Grande'],
  [360, 'Enorme'],
];

/**
 * @param {object} ctx
 * @param {boolean} ctx.petVisible
 * @param {() => void} ctx.togglePet   show/hide the orc
 * @param {() => void} ctx.refresh     rebuild both menus after a state change
 * @param {() => void} ctx.quitApp     quit, staying off until re-enabled
 * @param {number} ctx.petSize         current window size in px
 * @param {(n: number) => void} ctx.setPetSize
 */
function buildControlMenu(ctx) {
  const cfg = readConfig();
  const paused = isPaused();
  const active = cfg.default_pack;
  const installed = new Set(installedPacks());
  const categories = cfg.categories || {};
  const after = err => { if (!err) ctx.refresh(); };

  const voiceItems = VOICE_PRESETS.filter(p => installed.has(p)).map(name => ({
    label: packLabel(name),
    type: 'radio',
    checked: name === active,
    click() { runPeon(['packs', 'use', name], after); },
  }));

  // An active pack outside the preset list still deserves to show as selected
  if (active && !VOICE_PRESETS.includes(active) && installed.has(active)) {
    voiceItems.unshift({ label: packLabel(active), type: 'radio', checked: true, click() {} });
  }

  const volumeItems = VOLUMES.map(v => ({
    label: `${Math.round(v * 100)}%`,
    type: 'radio',
    checked: Math.abs((cfg.volume ?? 0.5) - v) < 0.01,
    click() { runPeon(['volume', String(v)], after); },
  }));

  const sizeItems = SIZES.map(([px, label]) => ({
    label: `${label} (${px}px)`,
    type: 'radio',
    checked: ctx.petSize === px,
    click() { ctx.setPetSize(px); },
  }));
  // A size set by dragging a corner rarely lands on a preset
  if (!SIZES.some(([px]) => px === ctx.petSize)) {
    sizeItems.push({ type: 'separator' });
    sizeItems.push({ label: `A medida (${ctx.petSize}px)`, type: 'radio', checked: true, click() {} });
  }

  const eventItems = EVENT_LABELS.map(([key, label]) => ({
    label,
    type: 'checkbox',
    checked: categories[key] === true,
    click() {
      writeConfig(c => {
        c.categories = c.categories || {};
        c.categories[key] = !c.categories[key];
      });
      ctx.refresh();
    },
  }));

  return Menu.buildFromTemplate([
    { label: active ? packLabel(active) : 'peon-ping', enabled: false },
    { label: paused ? '⏸  Sonidos en pausa' : '▶  Sonidos activos', enabled: false },
    { type: 'separator' },
    {
      label: paused ? 'Reanudar sonidos' : 'Pausar sonidos',
      accelerator: 'Command+P',
      click() { runPeon([paused ? 'resume' : 'pause'], after); },
    },
    {
      label: 'Probar sonido',
      click() { runPeon(['preview', 'task.complete'], null); },
    },
    { type: 'separator' },
    { label: 'Voz', submenu: voiceItems.length ? voiceItems : [{ label: 'sin packs', enabled: false }] },
    { label: 'Volumen', submenu: volumeItems },
    { label: 'Avisos', submenu: eventItems },
    { label: 'Tamaño', submenu: sizeItems },
    { type: 'separator' },
    { label: ctx.petVisible ? 'Ocultar orco' : 'Mostrar orco', click() { ctx.togglePet(); } },
    {
      label: 'Ajustes…',
      accelerator: 'Command+,',
      click() { ctx.openSettings(); },
    },
    {
      label: 'Abrir configuración…',
      click() { shell.openPath(CONFIG_PATH); },
    },
    { type: 'separator' },
    {
      label: 'Salir (queda apagado)',
      click() { ctx.quitApp(); },
    },
  ]);
}

function setDisabledFlag(on) {
  try {
    if (on) fs.writeFileSync(DISABLED_FLAG, 'set by the tray menu\n', 'utf8');
    else fs.rmSync(DISABLED_FLAG, { force: true });
  } catch { /* best effort */ }
}

module.exports = { buildControlMenu, setDisabledFlag, DISABLED_FLAG };

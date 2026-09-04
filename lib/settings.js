// State layer behind the settings window.
//
// Everything here is derived from files that already exist — peon-ping's
// config, the pet's own config and the two launch agents — so the settings
// window is a view, never a second source of truth.
'use strict';

const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const PEON_DIR = path.join(HOME, '.claude', 'hooks', 'peon-ping');
const PEON_CONFIG = path.join(PEON_DIR, 'config.json');
const PAUSED_FILE = path.join(PEON_DIR, '.paused');
const PACKS_DIR = path.join(HOME, '.openpeon', 'packs');
const MODE_FILE = path.join(HOME, '.openpeon', 'pet-mode');
const WATCH_PLIST = path.join(HOME, 'Library', 'LaunchAgents', 'com.peonpet.watch.plist');

const MODES = ['follow', 'always', 'off'];
const DEFAULT_MODE = 'follow';

function readJson(p, fallback = {}) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return fallback; }
}

function writeJson(p, obj) {
  fs.writeFileSync(p, JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

function readMode() {
  try {
    const v = fs.readFileSync(MODE_FILE, 'utf8').trim();
    return MODES.includes(v) ? v : DEFAULT_MODE;
  } catch { return DEFAULT_MODE; }
}

function writeMode(mode) {
  if (!MODES.includes(mode)) return;
  fs.mkdirSync(path.dirname(MODE_FILE), { recursive: true });
  fs.writeFileSync(MODE_FILE, mode + '\n', 'utf8');
}

function readInterval() {
  try {
    const xml = fs.readFileSync(WATCH_PLIST, 'utf8');
    const m = xml.match(/<key>StartInterval<\/key>\s*<integer>(\d+)<\/integer>/);
    return m ? Number(m[1]) : 10;
  } catch { return 10; }
}

function writeInterval(seconds) {
  const n = Math.max(2, Math.min(300, Math.round(Number(seconds) || 10)));
  try {
    const xml = fs.readFileSync(WATCH_PLIST, 'utf8');
    const next = xml.replace(
      /(<key>StartInterval<\/key>\s*<integer>)\d+(<\/integer>)/,
      `$1${n}$2`
    );
    if (next === xml) return;
    fs.writeFileSync(WATCH_PLIST, next, 'utf8');
    // launchd only re-reads the plist on reload
    execFile('/bin/launchctl', ['unload', WATCH_PLIST], () => {
      execFile('/bin/launchctl', ['load', '-w', WATCH_PLIST], () => {});
    });
  } catch { /* best effort */ }
}

function watchAgentLoaded(done) {
  execFile('/bin/launchctl', ['print', `gui/${process.getuid()}/com.peonpet.watch`],
    err => done(!err));
}

function setWatchAgent(enabled, done) {
  const args = enabled ? ['load', '-w', WATCH_PLIST] : ['unload', '-w', WATCH_PLIST];
  execFile('/bin/launchctl', args, () => done && done());
}

function installedPacks() {
  try {
    return fs.readdirSync(PACKS_DIR)
      .filter(n => fs.existsSync(path.join(PACKS_DIR, n, 'openpeon.json')))
      .map(n => ({
        name: n,
        label: readJson(path.join(PACKS_DIR, n, 'openpeon.json')).display_name || n,
      }))
      .sort((a, b) => a.label.localeCompare(b.label));
  } catch { return []; }
}

const PEON_CANDIDATES = [
  '/opt/homebrew/bin/peon',
  '/usr/local/bin/peon',
  path.join(HOME, '.local', 'bin', 'peon'),
];

function runPeon(args, done) {
  const bin = PEON_CANDIDATES.find(p => fs.existsSync(p));
  if (!bin) return done && done();
  execFile(bin, args, { timeout: 10000 }, () => done && done());
}

function getState(extra = {}) {
  const cfg = readJson(PEON_CONFIG);
  return new Promise(resolve => {
    watchAgentLoaded(loaded => {
      resolve({
        mode: readMode(),
        startAtLogin: loaded,
        interval: readInterval(),
        paused: fs.existsSync(PAUSED_FILE),
        volume: cfg.volume ?? 0.5,
        pack: cfg.default_pack || '',
        packs: installedPacks(),
        categories: cfg.categories || {},
        desktopNotifications: cfg.desktop_notifications !== false,
        ...extra,
      });
    });
  });
}

// Each key is applied independently so a partial patch is always valid.
function applyPatch(patch, hooks = {}) {
  return new Promise(resolve => {
    const pending = [];

    if (patch.mode !== undefined) writeMode(patch.mode);
    if (patch.interval !== undefined) writeInterval(patch.interval);
    if (patch.size !== undefined && hooks.setPetSize) hooks.setPetSize(patch.size);
    if (patch.petVisible !== undefined && hooks.setPetVisible) hooks.setPetVisible(patch.petVisible);

    if (patch.startAtLogin !== undefined) {
      pending.push(new Promise(r => setWatchAgent(patch.startAtLogin, r)));
    }
    if (patch.paused !== undefined) {
      pending.push(new Promise(r => runPeon([patch.paused ? 'pause' : 'resume'], r)));
    }
    if (patch.volume !== undefined) {
      pending.push(new Promise(r => runPeon(['volume', String(patch.volume)], r)));
    }
    if (patch.pack !== undefined) {
      pending.push(new Promise(r => runPeon(['packs', 'use', patch.pack], r)));
    }
    if (patch.preview) {
      pending.push(new Promise(r => runPeon(['preview', patch.preview], r)));
    }

    if (patch.categories !== undefined || patch.desktopNotifications !== undefined) {
      const cfg = readJson(PEON_CONFIG);
      if (patch.categories !== undefined) {
        cfg.categories = { ...(cfg.categories || {}), ...patch.categories };
      }
      if (patch.desktopNotifications !== undefined) {
        cfg.desktop_notifications = !!patch.desktopNotifications;
      }
      writeJson(PEON_CONFIG, cfg);
    }

    Promise.all(pending).then(() => resolve());
  });
}

module.exports = { getState, applyPatch, readMode, writeMode, MODE_FILE, MODES };

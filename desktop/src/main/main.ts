// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Electron entry point: window, tray, secure storage (Windows DPAPI via safeStorage),
// and a sender-validated IPC surface for the sandboxed renderer.

import { app, BrowserWindow, clipboard, dialog, ipcMain, Menu, nativeImage, nativeTheme, powerSaveBlocker, safeStorage, session, shell, Tray, type IpcMainInvokeEvent } from 'electron';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Home } from './home';
import { createCaptureAdapter } from './capture';
import { stopOnRendererLoss } from './sync';
import { audioSupportFor } from './audio-capture';
import { LINUX_PROFILE_DIR, linuxCaptureSwitches, linuxRevalidatesSources, linuxSecretsAvailable, linuxSessionType } from './linux-platform';
import { HomeStorage, type SecretStore } from './storage';
import { BACKUP_LIMIT } from './backup';
import { FLOOR_IMAGE_LIMIT, FloorPlanStore } from './floor-plans';
import { isLight } from '../shared/devices';
import { roomPower } from '../shared/library';
import type { BluetoothOp } from '../shared/types';
import { LumaError, message, power } from '../core/model';

const demo = process.argv.includes('--demo');
const LINKS = {
  repo: 'https://github.com/designxdevelop/luma',
  issues: 'https://github.com/designxdevelop/luma/issues',
  apikey: 'https://developer.govee.com/reference/apply-you-govee-api-key',
  'lan-guide': 'https://app-h5.govee.com/user-manual/wlan-guide',
} as const;

// Demo is fully isolated: a throwaway profile, so no user data, cookies or caches persist,
// and the credential store, LAN sockets and the webhook listener are never created.
let demoProfile: string | undefined;
// Connected mode runs on Windows and Linux, each with its own profile folder so it can
// never share a data directory with the macOS Luma app (both are named "Luma").
const linux = process.platform === 'linux';
// 'prevent-app-suspension' keeps the system from idle sleep (screen may still turn off); it can't stop a lid close or manual sleep.
let awakeBlocker: number | undefined;
function keepAwake(on: boolean): void {
  if (on && awakeBlocker === undefined) awakeBlocker = powerSaveBlocker.start('prevent-app-suspension');
  if (!on && awakeBlocker !== undefined) { powerSaveBlocker.stop(awakeBlocker); awakeBlocker = undefined; }
}
const unsupported = !demo && process.platform !== 'win32' && !linux;
const linuxSession = linux ? linuxSessionType(process.env) : 'unknown';
/** Removes throwaway profiles left by demo processes that were killed before cleanup. */
function sweepStaleProfiles(): void {
  for (const name of readdirSync(tmpdir())) {
    const pid = Number(/^luma-(?:demo|refused)-(\d+)-/.exec(name)?.[1]);
    if (!pid || pid === process.pid) continue;
    try { process.kill(pid, 0); continue; } catch { /* owner is gone */ }
    try { rmSync(join(tmpdir(), name), { recursive: true, force: true }); } catch { /* best effort */ }
  }
}
if (demo || unsupported) sweepStaleProfiles();
if (demo) {
  demoProfile = mkdtempSync(join(tmpdir(), `luma-demo-${process.pid}-`));
  app.setPath('userData', demoProfile);
  app.setPath('sessionData', demoProfile);
} else if (unsupported) {
  // Even the refusal dialog must not let Chromium create/touch the default "Luma" profile.
  const scratch = mkdtempSync(join(tmpdir(), `luma-refused-${process.pid}-`));
  app.setPath('userData', scratch);
  app.setPath('sessionData', scratch);
  demoProfile = scratch;
} else {
  app.setPath('userData', join(app.getPath('appData'), linux ? LINUX_PROFILE_DIR : 'LumaWindows'));
  // Bluetooth lights: the advertisement (encryption flag, Pact) is read with watchAdvertisements, still behind a Blink flag.
  app.commandLine.appendSwitch('enable-blink-features', 'WebBluetoothWatchAdvertisements,WebBluetoothScanning');
  if (linux) {
    // Capture switches are merged into any existing value (appendSwitch would replace it). Never --no-sandbox.
    for (const [name, value] of linuxCaptureSwitches(linuxSession)) {
      const existing = app.commandLine.getSwitchValue(name);
      const merged = value && existing ? [...new Set([...existing.split(','), ...value.split(',')])].join(',') : value ?? existing;
      app.commandLine.appendSwitch(name, merged || undefined);
    }
  }
}

/** DPAPI (Windows) or a real keyring (Linux: libsecret/KWallet, never basic_text). Never falls back to plaintext. */
class SafeSecretStore implements SecretStore {
  private readonly folder = join(app.getPath('userData'), 'secrets');
  get available(): boolean {
    if (process.platform === 'win32') return safeStorage.isEncryptionAvailable();
    if (linux) return linuxSecretsAvailable(safeStorage.isEncryptionAvailable(), safeStorage.getSelectedStorageBackend());
    return false;
  }
  private path(name: string) {
    if (!/^[a-z-]{1,32}$/.test(name)) throw new LumaError('Invalid secret name.');
    return join(this.folder, `${name}.bin`);
  }
  read(name: string): string | undefined {
    if (!this.available) return undefined;
    const file = this.path(name);
    if (!existsSync(file) || statSync(file).size > 64 * 1024) return undefined;
    try { return safeStorage.decryptString(readFileSync(file)); }
    catch { throw new LumaError('A saved secret could not be decrypted on this Windows account. Enter it again.'); }
  }
  write(name: string, value: string): void {
    if (!this.available) throw new LumaError('Secure storage is unavailable; nothing was saved.');
    mkdirSync(this.folder, { recursive: true, mode: 0o700 });
    writeFileSync(this.path(name), safeStorage.encryptString(value), { mode: 0o600 });
  }
  delete(name: string): void {
    const file = this.path(name);
    if (existsSync(file)) unlinkSync(file);
  }
}

let home: Home;
let capture: ReturnType<typeof createCaptureAdapter>;
/** Real screen capture: connected mode on Windows or Linux. Demo always uses synthetic frames. */
const captureReal = !demo && (process.platform === 'win32' || linux);
/** Audio Sync always captures real audio (demo too: only the lights are simulated). */
const audioSupport = audioSupportFor(process.platform);
let window: BrowserWindow | undefined;
let tray: Tray | undefined;
let quitting = false;
let pendingNavigation: { deviceID?: string; tab?: string } | undefined;
let trayHintShown = false;
const rendererURL = () => pathToFileURL(join(__dirname, '..', 'ui', 'renderer', 'index.html')).toString();

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1200, height: 800, minWidth: 720, minHeight: 520,
    show: false, autoHideMenuBar: true, title: demo ? 'Luma (Demo)' : 'Luma',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#17161a' : '#f6f5f3',
    icon: join(__dirname, '..', '..', 'assets', 'icon.png'),
    webPreferences: {
      preload: join(__dirname, 'preload.js'),
      contextIsolation: true, sandbox: true, nodeIntegration: false, webSecurity: true, spellcheck: false,
    },
  });
  win.removeMenu();
  win.once('ready-to-show', () => win.show());
  win.webContents.on('did-finish-load', () => flushNavigation());
  win.on('close', (event) => {
    if (quitting) return;
    event.preventDefault();
    win.hide();
    if (!trayHintShown && process.platform === 'win32' && tray) {
      trayHintShown = true;
      tray.displayBalloon({ title: 'Luma is still running', content: 'Schedules and the webhook server keep working. Quit from the tray icon.' });
    }
  });
  win.on('closed', () => { if (window === win) window = undefined; });
  // Web Bluetooth's chooser: main lists Govee lights as they advertise; the person picks one on the Bluetooth page.
  win.webContents.on('select-bluetooth-device', (event, devices, callback) => { event.preventDefault(); home.bluetooth.found(devices, callback); });
  // A hidden or minimized window pauses Screen Sync rather than sampling in the background.
  // Audio Sync keeps running from the tray (music plays with Luma closed); the tray shows it.
  win.on('hide', () => { if (home.sync.kind !== 'audio') home.sync.pause(); });
  win.on('minimize', () => { if (home.sync.kind !== 'audio') home.sync.pause(); });
  // Reload, navigation, crash or hang orphans the session (even paused): revoke and stop, no restore.
  stopOnRendererLoss(win.webContents, () => { capture.revoke(); void home.sync.stop('The Luma window reloaded or stopped responding.'); });
  void win.loadURL(rendererURL());
  return win;
}

/** Stores the destination first, then shows the window, so a cold restore still lands there. */
function openWindow(target?: { deviceID?: string; tab?: string }): void {
  if (target) pendingNavigation = target;
  if (!window) { window = createWindow(); return; }
  if (window.isMinimized()) window.restore();
  window.show();
  window.focus();
  if (!window.webContents.isLoading()) flushNavigation();
}

function flushNavigation(): void {
  if (!window || !pendingNavigation) return;
  window.webContents.send('luma:navigate', pendingNavigation);
  pendingNavigation = undefined;
}

/** PNG re-encode (drops EXIF/GPS), at most 4096 px on the long side, like the native rasterizer. */
function encodeFloorImage(data: Buffer): Buffer | undefined {
  const image = nativeImage.createFromBuffer(data);
  if (image.isEmpty()) return undefined;
  const { width, height } = image.getSize();
  const scale = Math.min(1, 4096 / Math.max(width, height));
  return (scale < 1 ? image.resize({ width: Math.round(width * scale), height: Math.round(height * scale), quality: 'best' }) : image).toPNG();
}

function buildTray(): void {
  if (!tray) {
    const icon = nativeImage.createFromPath(join(__dirname, '..', '..', 'assets', 'tray.png'));
    tray = new Tray(icon.isEmpty() ? nativeImage.createEmpty() : icon.resize({ width: 16, height: 16 }));
    tray.on('click', () => openWindow());
  }
  const syncLabel = home.sync.kind === 'audio' ? 'Audio Sync' : 'Screen Sync';
  tray.setToolTip(`${demo ? 'Luma (Demo)' : 'Luma'}${home.sync.active ? ` · ${syncLabel} ${home.sync.phase === 'paused' ? 'paused' : 'live'}` : ''}`);
  const snapshot = home.snapshot();
  const rooms = [...new Set(snapshot.devices.map((d) => d.room))].sort();
  const lights = snapshot.devices.filter(isLight);
  const powerRooms = roomPower(snapshot.devices);
  const run = (fn: () => unknown) => () => { try { void Promise.resolve(fn()).catch((e) => home.log(message(e), true)); } catch (e) { home.log(message(e), true); } };
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: lights.length ? `${demo ? 'Luma (Demo)' : 'Luma'} · ${lights.filter((d) => d.power === true).length} of ${lights.length} lights on` : 'Luma · No lights yet', enabled: false },
    { label: 'Open Luma', click: () => openWindow() },
    { type: 'separator' },
    { label: 'All lights on', enabled: snapshot.devices.length > 0, click: run(() => home.quickAction(home.roomDeviceIDs(), power(true))) },
    { label: 'All lights off', enabled: snapshot.devices.length > 0, click: run(() => home.quickAction(home.roomDeviceIDs(), power(false))) },
    // Per-room On/Off, as in the Mac menu bar: lights with a power switch only.
    ...(powerRooms.length > 1 ? [
      { type: 'separator' as const },
      ...powerRooms.map(({ room, ids, on }) => ({
        label: `${room} · ${on} of ${ids.length} on`, enabled: ids.length > 0,
        submenu: [
          { label: 'Turn on', click: run(() => home.quickAction(ids, power(true))) },
          { label: 'Turn off', click: run(() => home.quickAction(ids, power(false))) },
        ],
      })),
    ] : []),
    {
      label: 'Lights', enabled: snapshot.devices.length > 0,
      submenu: rooms.map((room) => ({
        label: room,
        submenu: snapshot.devices.filter((d) => d.room === room).map((d) => ({ label: d.name, click: () => openWindow({ deviceID: d.id }) })),
      })),
    },
    {
      label: 'Run scene', enabled: snapshot.scenes.length > 0 && !snapshot.runningSceneID,
      submenu: snapshot.scenes.map((s) => ({ label: s.name, click: run(() => home.runSavedScene(s.id)) })),
    },
    { label: 'Stop scene', enabled: !!snapshot.runningSceneID, click: run(() => home.stopScene()) },
    ...(home.sync.active ? [
      { type: 'separator' as const },
      { label: `${syncLabel}: ${snapshot.sync.phase === 'paused' ? 'paused' : 'live'}`, enabled: false },
      { label: `Pause ${syncLabel}`, enabled: snapshot.sync.phase === 'running' || snapshot.sync.phase === 'starting', click: run(() => home.sync.pause()) },
      { label: `Stop ${syncLabel}`, enabled: snapshot.sync.phase !== 'stopping', click: run(() => { capture.revoke(); return home.sync.stop('Stopped from the tray.', true); }) },
    ] : []),
    { type: 'separator' },
    { label: 'Settings', click: () => openWindow({ tab: 'settings' }) },
    { label: 'About', click: () => openWindow({ tab: 'about' }) },
    { label: 'Quit Luma', click: () => { quitting = true; app.quit(); } },
  ]));
}

/** Rejects IPC from anything other than our own top-level renderer document. */
function trusted(event: IpcMainInvokeEvent): boolean {
  return !!window && event.sender === window.webContents && event.senderFrame?.url === rendererURL();
}

const str = (v: unknown, max = 256): string => {
  if (typeof v !== 'string' || v.length > max) throw new LumaError('Invalid request.');
  return v;
};

function registerIPC(): void {
  const handle = (channel: string, fn: (...args: unknown[]) => unknown) => {
    ipcMain.handle(`luma:${channel}`, async (event, ...args) => {
      if (!trusted(event)) throw new Error('Untrusted sender.');
      try { return await fn(...args); }
      catch (error) { throw new Error(message(error)); } // only the message crosses the bridge
    });
  };
  handle('snapshot', () => home.snapshot());
  handle('scheduleSync', async (action, arg) => {
    const sync = home.scheduleSync;
    switch (action) {
      case 'runHere': return sync.becomeRunner();
      case 'pair': return sync.pair(str(arg, 256));
      case 'off': return sync.turnOff();
      case 'syncNow': return sync.syncNow();
      case 'takeOver': return sync.takeOver(false);
      case 'forceTakeOver': return sync.takeOver(true);
      case 'keepAwake': return sync.setKeepAwake(arg === true);
      case 'rotate': return sync.rotatePairing();
      case 'dismiss': return sync.dismissNotices();
      case 'copyCode': { const code = sync.view().runner?.pairingCodes.find((c) => c === arg); if (!code) throw new LumaError('Pairing code not found.'); clipboard.writeText(code); return; }
      default: throw new LumaError('Unknown schedule sync action.');
    }
  });
  handle('setAppearance', (value) => { home.setAppearance(value); nativeTheme.themeSource = home.snapshot().appearance; });
  handle('setSyncAssignments', (value) => home.setSyncAssignments(value));
  handle('clearActivity', () => home.clearActivity());
  handle('copyDeviceID', (id) => { const device = home.snapshot().devices.find(d => d.id === str(id)); if (!device) throw new LumaError('Device not found.'); clipboard.writeText(device.id); });
  handle('exploreDemo', () => { if (demo) return; app.releaseSingleInstanceLock(); app.relaunch({ args: [...process.argv.slice(1), '--demo'] }); quitting = true; app.quit(); });
  handle('control', (id, command) => home.control(str(id), command as never));
  handle('refresh', (id) => home.refresh(str(id)));
  handle('connect', (key) => home.connect(str(key, 512)));
  handle('reconnect', () => home.reconnect());
  handle('disconnect', () => home.disconnect());
  handle('discover', () => home.discover());
  handle('loadEffects', (id, diy) => home.loadEffects(str(id), diy === true));
  handle('assignRoom', (id, room) => home.assignRoom(str(id), str(room)));
  handle('renameDevice', (id, name) => home.renameDevice(str(id), str(name)));
  handle('saveScene', (scene) => { home.saveScene(scene); });
  handle('deleteScene', (id) => home.deleteScene(str(id)));
  handle('captureScene', (name, icon, ids) => home.captureScene(str(name), str(icon, 32), Array.isArray(ids) ? ids.slice(0, 200).map((i) => str(i)) : []));
  handle('validateSceneJSON', (text) => home.validateSceneJSON(str(text, 256 * 1024)));
  handle('runScene', (id) => home.runSavedScene(str(id)));
  handle('stopScene', () => home.stopScene());
  handle('saveSchedule', (schedule) => home.saveSchedule(schedule));
  handle('deleteSchedule', (id) => home.deleteSchedule(str(id)));
  handle('setWebhookConfig', (port, allowLAN) => home.setWebhookConfig(port, allowLAN));
  handle('startWebhook', () => home.startWebhook());
  handle('stopWebhook', () => home.stopWebhook());
  handle('rotateToken', () => home.rotateToken());
  handle('copyToken', () => home.copyToken());
  handle('copyFingerprint', () => { const fingerprint = home.snapshot().webhook.fingerprint; if (!fingerprint) throw new LumaError('Start the server first.'); clipboard.writeText(fingerprint); });
  handle('copySpkiPin', () => { const pin = home.snapshot().webhook.spkiPin; if (!pin) throw new LumaError('Start the server first.'); clipboard.writeText(pin); });
  handle('exportCertificate', async () => { const cert = home.webhookCertificate(); const result = await dialog.showSaveDialog(window!, { defaultPath: 'luma.pem', filters: [{ name: 'PEM certificate', extensions: ['pem'] }] }); if (!result.canceled && result.filePath) writeFileSync(result.filePath, cert); });
  handle('dismissNotice', () => home.dismissNotice());
  handle('syncSources', () => capture.list());
  handle('syncStart', (key, lights) => capture.start(key, lights));
  handle('syncFrame', (token, generation, seq, grid) => home.sync.frame(token, generation, seq, grid));
  handle('syncPause', () => home.sync.pause());
  handle('syncResume', (token) => home.sync.resume(token));
  handle('syncStop', () => { capture.revoke(); return home.sync.stop('Stopped.', true); });
  handle('syncEnded', (token, reason) => {
    // Only the live session's renderer may end it; reason text is ours, chosen from a fixed set.
    if (!home.sync.ownsToken(token)) return;
    capture.revoke();
    const reasons: Record<string, string> = home.sync.kind === 'audio'
      ? { ended: 'The audio device or capture ended.', denied: 'Audio capture was not allowed or is unavailable.', 'no-audio': 'No computer audio track was provided. Choose Default input and route your output to it.', worker: 'Audio analysis stopped.', hidden: 'The window was hidden.' }
      : { ended: 'The shared screen or window closed.', muted: 'Capture was interrupted (locked, hidden or unavailable source).', denied: 'Screen capture was not allowed.', worker: 'Frame analysis stopped responding.', hidden: 'The window was hidden.' };
    return home.sync.stop(reasons[str(reason, 16)] ?? 'Capture stopped.');
  });
  handle('syncSettings', (settings) => home.setSyncSettings(settings));
  handle('audioStart', (source, lights, options) => capture.startAudio(source, lights, options));
  handle('audioLevels', (token, generation, seq, levels) => home.sync.levels(token, generation, seq, levels));
  handle('audioOptions', (options) => home.sync.setAudio(options));
  handle('openExternal', (key) => {
    const url = LINKS[str(key) as keyof typeof LINKS];
    if (!url) throw new LumaError('Unknown link.');
    return shell.openExternal(url);
  });
  handle('exportScene', async (id) => {
    const { name, json } = home.exportScene(str(id));
    const result = await dialog.showSaveDialog(window!, { defaultPath: `${name.replace(/[^\w -]+/g, '').trim() || 'scene'}.luma-scene.json`, filters: [{ name: 'Luma scene', extensions: ['json'] }] });
    if (!result.canceled && result.filePath) { writeFileSync(result.filePath, json); home.log(`Exported ${name}.`); }
  });
  handle('goveeSignIn', (email, password, code) => home.goveeSignIn(str(email), str(password, 256), code === undefined ? undefined : str(code, 16)));
  handle('goveeImport', () => home.goveeImport());
  handle('goveeApplyRooms', (ids) => home.goveeApplyRooms(Array.isArray(ids) ? ids.slice(0, 1000).map((i) => str(i)) : []));
  handle('goveeSignOut', () => home.goveeSignOut());
  const pickImage = async (): Promise<Buffer | undefined> => {
    const result = await dialog.showOpenDialog(window!, { properties: ['openFile'], filters: [{ name: 'Floor plan image', extensions: ['png', 'jpg', 'jpeg'] }] });
    const file = result.filePaths[0];
    if (result.canceled || !file) return undefined;
    if (statSync(file).size > FLOOR_IMAGE_LIMIT) throw new LumaError('Choose an image smaller than 20 MB.');
    return readFileSync(file);
  };
  handle('floorPlanAdd', async () => { const image = await pickImage(); return image ? home.floorPlan((f) => f.add(image)) : undefined; });
  handle('floorPlanReplace', async (id) => { const image = await pickImage(); if (image) home.floorPlan((f) => f.replace(str(id, 64), image)); });
  handle('floorPlanRename', (id, name) => home.floorPlan((f) => f.rename(str(id, 64), str(name, 256))));
  handle('floorPlanDelete', (id) => home.floorPlan((f) => f.delete(str(id, 64))));
  handle('floorPlanPlace', (id, deviceID, x, y) => home.floorPlanPlace(str(id, 64), str(deviceID), x, y));
  handle('floorPlanRemovePin', (id, deviceID) => home.floorPlan((f) => f.removePin(str(id, 64), str(deviceID))));
  handle('floorPlanImage', (id) => { const png = home.floorPlan((f) => f.image(str(id, 64))); return png ? `data:image/png;base64,${png.toString('base64')}` : undefined; });
  handle('saveDreamViewDraft', (id, draft) => home.saveDreamViewDraft(str(id), draft));
  handle('bluetooth', async (op, arg) => {
    if (op !== 'capture') return home.bluetooth.handle(str(op, 16) as BluetoothOp, arg);
    const result = await dialog.showOpenDialog(window!, { properties: ['openFile'], filters: [{ name: 'Bluetooth capture', extensions: ['txt', 'log'] }, { name: 'All files', extensions: ['*'] }] });
    const file = result.filePaths[0];
    if (result.canceled || !file) return;
    if (statSync(file).size > 16 * 1024 * 1024) throw new LumaError('That capture is too large.');
    return home.bluetooth.handle('capture', readFileSync(file, 'utf8'));
  });
  handle('roomAction', (room, action) => home.roomAction(str(room, 160), action));
  handle('controlBatch', (id, commands) => home.controlBatch(str(id), commands));
  handle('restoreBeforeScene', () => { home.restoreBeforeScene(); });
  handle('doorbell', (action, arg, arg2) => home.doorbell.command(action, arg, arg2));
  handle('copyCompatibilityReport', () => { clipboard.writeText(home.compatibilityReport()); home.log('Compatibility report copied. It lists models and features only: no names, IDs or addresses.'); });
  handle('exportBackup', async () => {
    const json = home.exportBackup();
    const result = await dialog.showSaveDialog(window!, { defaultPath: `Luma home ${new Date().toISOString().slice(0, 10)}.luma-backup.json`, filters: [{ name: 'Luma home backup', extensions: ['json'] }] });
    if (!result.canceled && result.filePath) { writeFileSync(result.filePath, json, { mode: 0o600 }); home.log('Exported a home backup (scenes, schedules, names and rooms; no keys or tokens).'); }
  });
  handle('importBackup', async () => {
    const result = await dialog.showOpenDialog(window!, { properties: ['openFile'], filters: [{ name: 'Luma home backup', extensions: ['json'] }] });
    const file = result.filePaths[0];
    if (result.canceled || !file) return undefined;
    if (statSync(file).size > BACKUP_LIMIT) throw new LumaError('That backup is too large.');
    return home.restoreBackup(readFileSync(file, 'utf8'));
  });
  handle('importScene', async () => {
    const result = await dialog.showOpenDialog(window!, { properties: ['openFile'], filters: [{ name: 'Luma scene', extensions: ['json'] }] });
    const file = result.filePaths[0];
    if (result.canceled || !file) return undefined;
    if (statSync(file).size > 256 * 1024) throw new LumaError('That file is too large to be a scene.');
    return home.importScene(readFileSync(file, 'utf8'));
  });
}

function hardenSessions(): void {
  session.defaultSession.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  // Only our own renderer may use Web Bluetooth (Bluetooth lights); everything else stays denied.
  const ours = (wc: Electron.WebContents | null) => !!window && wc === window.webContents && wc.getURL() === rendererURL();
  session.defaultSession.setPermissionCheckHandler((wc, permission) => (permission as string) === 'bluetooth' && ours(wc));
  app.on('web-contents-created', (_event, contents) => {
    contents.on('will-navigate', (event) => event.preventDefault());
    contents.on('will-attach-webview', (event) => event.preventDefault());
    contents.setWindowOpenHandler(() => ({ action: 'deny' }));
  });
}

if (unsupported) {
  // Refuse before any profile, storage or credential store is created.
  app.whenReady().then(() => {
    dialog.showErrorBox('Luma', 'Connected mode runs on Windows and Linux. Use --demo to try the interface on this system.');
    try { rmSync(demoProfile!, { recursive: true, force: true }); } catch { /* best effort */ }
    app.exit(1);
  });
} else if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => openWindow());
  app.whenReady().then(() => {
    hardenSessions();
    home = new Home({
      demo,
      version: app.getVersion(),
      storage: demo ? undefined : new HomeStorage(app.getPath('userData')),
      secrets: demo ? undefined : new SafeSecretStore(),
      copyToClipboard: (text) => clipboard.writeText(text),
      captureSupported: captureReal,
      syncOptions: { audioSupport },
      scheduleSyncOptions: { keepAwake },
      postToRenderer: (channel, payload) => { if (window && !window.isDestroyed()) window.webContents.send(channel, payload); },
      floorPlans: new FloorPlanStore(demo ? undefined : join(app.getPath('userData'), 'floor-plans'), encodeFloorImage),
    });
    nativeTheme.themeSource = home.snapshot().appearance;
    capture = createCaptureAdapter({ real: captureReal, revalidate: !linux || linuxRevalidatesSources(linuxSession), sync: home.sync, window: () => window, rendererURL, audioSupport });
    registerIPC();
    let queued = false;
    home.subscribe(() => {
      if (queued) return;
      queued = true;
      setTimeout(() => {
        queued = false;
        if (window && !window.isDestroyed()) {
          // A live Audio Sync session must keep analyzing while the window is hidden in the tray.
          window.webContents.setBackgroundThrottling(!(home.sync.active && home.sync.kind === 'audio'));
          window.webContents.send('luma:snapshot-changed', home.snapshot());
        }
        buildTray();
      }, 50);
    });
    buildTray();
    openWindow();
    // Reconnect with the saved encrypted key; the webhook server always starts off.
    if (!demo && home.hasSavedHome && home.snapshot().hasSavedKey) void home.reconnect().catch(() => {});
    // Lights can change IP between launches (updates, router restarts), so rescan every launch.
    if (!demo && home.hasSavedHome) void home.discover().catch(() => {});
    // The schedule runner's LAN server starts with the app when this computer runs shared schedules.
    void home.scheduleSync.start();
  });
  // A terminated demo/run still cleans up its throwaway profile through before-quit.
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { quitting = true; app.quit(); });
  app.on('window-all-closed', () => { /* keep running in the tray */ });
  let shuttingDown = false;
  app.on('before-quit', (event) => {
    quitting = true;
    if (!home) return;
    event.preventDefault();
    if (shuttingDown) return;
    shuttingDown = true;
    capture?.dispose();
    void home.shutdown().finally(() => {
      if (demoProfile) { try { rmSync(demoProfile, { recursive: true, force: true }); } catch { /* best effort */ } }
      app.exit(0);
    });
  });
}

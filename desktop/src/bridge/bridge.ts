// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Luma Bridge: the desktop Home (scenes, schedules, Govee LAN/cloud transport, webhook API) and its
// schedule-sync runner, hosted in a plain Node process with no window. It speaks only the existing
// schedule-sync protocol (port 8788, pinned TLS, pairing code) and the existing webhook API, so the
// iPhone, Mac and Windows/Linux apps pair with it unchanged.
//
// One process owns a data folder: an exclusive lock file guards it, the Luma window's own profile is
// refused, and moving the runner between the window and the bridge uses the protocol's hand-off.
// Status for `luma-bridge status` goes to bridge-status.json, built from an explicit field list:
// it never contains tokens, pins or pairing codes.

import { spawn, type ChildProcess } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { homedir, hostname, uptime } from 'node:os';
import { join, resolve } from 'node:path';
import { Home, type HomeOptions } from '../main/home';
import { HomeStorage } from '../main/storage';
import { message } from '../core/model';
import { SECRET_BACKENDS, createSecretStore, describeBackend, type SecretBackend } from './secret-store';

export const CONFIG_FILE = 'bridge.json';
export const STATUS_FILE = 'bridge-status.json';
export const LOCK_FILE = 'bridge.lock';
const HEARTBEAT_MS = 15_000;
const DISCOVERY_MS = 10 * 60_000;

export interface BridgeConfig {
  version: 1;
  secrets: SecretBackend;
  /** LAN discovery and LAN control. Off only for tests or cloud-only homes. */
  lan: boolean;
  /** Start the existing webhook API (port/LAN setting live in home.json). */
  webhook: boolean;
}

type Log = (line: string, isError?: boolean) => void;
const env = process.env;

/** Per-user data folder, separate from every Luma app profile. */
export function defaultDataDir(platform = process.platform, e: Record<string, string | undefined> = env, home = homedir()): string {
  if (e.LUMA_BRIDGE_DATA) return resolve(e.LUMA_BRIDGE_DATA);
  if (platform === 'win32') return join(e.APPDATA ?? join(home, 'AppData', 'Roaming'), 'LumaBridge');
  if (platform === 'darwin') return join(home, 'Library', 'Application Support', 'LumaBridge');
  return join(e.XDG_CONFIG_HOME || join(home, '.config'), 'luma-bridge');
}

/** The Luma window (Electron) and the Mac app keep their own state; the bridge must never share it. */
export function assertNotAppProfile(dir: string, platform = process.platform, e: Record<string, string | undefined> = env, home = homedir()): void {
  const appData = platform === 'win32' ? (e.APPDATA ?? join(home, 'AppData', 'Roaming')) : platform === 'darwin' ? join(home, 'Library', 'Application Support') : (e.XDG_CONFIG_HOME || join(home, '.config'));
  const profiles = ['LumaWindows', 'LumaLinux', 'Luma', 'luma-desktop'].map((name) => resolve(appData, name).toLowerCase());
  const target = resolve(dir).toLowerCase();
  // Chromium writes these into every Electron profile.
  const electron = ['Local State', 'Preferences', 'SingletonLock'].some((f) => existsSync(join(dir, f)));
  if (profiles.includes(target) || electron || target.includes(`${join('library', 'containers')}`.toLowerCase())) {
    throw new Error(`${dir} belongs to a Luma app. The bridge keeps its own data folder; to move schedules, pair the bridge with the app and run "luma-bridge take-over" (or pair the app with the bridge).`);
  }
}

export function prepareDataDir(dir: string): void {
  assertNotAppProfile(dir);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (process.platform !== 'win32') chmodSync(dir, 0o700);
}

// ---------- lock ----------

interface LockInfo { pid: number; startedAt: number; host: string }

export function readLock(dir: string): LockInfo | undefined {
  try { return JSON.parse(readFileSync(join(dir, LOCK_FILE), 'utf8')) as LockInfo; } catch { return undefined; }
}

/** A lock is live only if its process exists and was started after this boot (PIDs repeat across reboots, e.g. on a Pi). */
export function lockIsLive(lock: LockInfo | undefined, now = Date.now()): boolean {
  // Our own PID in an old lock is a previous run (in a container the bridge is often PID 1 every time).
  if (!lock || !Number.isInteger(lock.pid) || lock.pid <= 0 || lock.pid === process.pid) return false;
  // ponytail: the data folder is local; host names change (macOS per network, containers per run), so they aren't compared.
  if (typeof lock.startedAt !== 'number' || lock.startedAt < now - uptime() * 1000 - 60_000) return false;
  try { process.kill(lock.pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code === 'EPERM'; }
}

/** Exclusive ownership of a data folder. Returns the release function. */
export function acquireLock(dir: string): () => void {
  const file = join(dir, LOCK_FILE);
  const mine: LockInfo = { pid: process.pid, startedAt: Date.now(), host: hostname() };
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      writeFileSync(file, JSON.stringify(mine), { mode: 0o600, flag: 'wx' });
      return () => { if (readLock(dir)?.pid === process.pid) { try { unlinkSync(file); } catch { /* already gone */ } } };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
      const held = readLock(dir);
      if (lockIsLive(held)) throw new Error(`Luma Bridge is already running for ${dir} (pid ${held!.pid}). Stop it first (for example: systemctl --user stop luma-bridge).`);
      try { unlinkSync(file); } catch { /* raced with another starter; retry once */ }
    }
  }
  throw new Error(`Could not lock ${dir}.`);
}

// ---------- config ----------

export function readConfig(dir: string): BridgeConfig | undefined {
  const file = join(dir, CONFIG_FILE);
  if (!existsSync(file)) return undefined;
  const v = JSON.parse(readFileSync(file, 'utf8')) as Partial<BridgeConfig>;
  if (v.version !== 1 || !SECRET_BACKENDS.includes(v.secrets as SecretBackend)) throw new Error(`${file} is damaged. It was left untouched.`);
  return { version: 1, secrets: v.secrets!, lan: v.lan !== false, webhook: v.webhook === true };
}

export function writeConfig(dir: string, config: BridgeConfig): void {
  writeAtomic(join(dir, CONFIG_FILE), JSON.stringify(config, null, 2));
}

function writeAtomic(file: string, data: string): void {
  const temp = `${file}.${randomUUID()}.tmp`;
  try { writeFileSync(temp, data, { mode: 0o600, flag: 'wx' }); renameSync(temp, file); }
  finally { if (existsSync(temp)) unlinkSync(temp); }
}

// ---------- home ----------

const bridgePlatform = () => (process.platform === 'win32' ? 'windows' : process.platform === 'darwin' ? 'macos' : 'linux');

/**
 * Opens the folder's Home with the configured secret store. The caller must hold the lock.
 * Fails closed: unavailable or unreadable secret storage, or an unreadable home.json, throws.
 */
export function openHome(dir: string, config: BridgeConfig, version: string, extra: Partial<HomeOptions> = {}): Home {
  const secrets = createSecretStore(config.secrets, dir);
  if (!secrets.available) throw new Error(`Secure storage (${describeBackend(config.secrets)}) is not available, so the bridge will not run. See docs/LOCAL-BRIDGE.md.`);
  try { secrets.read('schedule-sync-token'); }
  catch (error) { throw new Error(`Secure storage (${describeBackend(config.secrets)}) could not be read: ${message(error)}`); }
  const home = new Home({
    demo: false, version, storage: new HomeStorage(dir), secrets, ...extra,
    scheduleSyncOptions: { platform: bridgePlatform(), ...extra.scheduleSyncOptions },
  });
  if (!home.snapshot().canSave) { void home.shutdown(); throw new Error(`${join(dir, 'home.json')} could not be read. It was left untouched; the bridge will not run until it is fixed or moved away.`); }
  return home;
}

// ---------- doorbell (present when the doorbell alert patch is applied) ----------

/** Structural view of the optional DoorbellController on Home, so this file builds with or without it. */
export interface DoorbellLike {
  view(): { config?: { enabled?: boolean; relayURL?: string }; phase?: string; status?: string; relayState?: string; relayTokenSaved?: boolean };
  command(action: unknown, arg?: unknown, arg2?: unknown): Promise<void>;
}
export const doorbellOf = (home: Home): DoorbellLike | undefined => (home as unknown as { doorbell?: DoorbellLike }).doorbell;

// ---------- status ----------

export interface BridgeStatus {
  version: 1; pid: number; startedAt: number; updatedAt: number; stoppedAt?: number; appVersion: string; secrets: string;
  role: string; mayExecute: boolean; listening: boolean; port: number; deviceName: string; timeZone: string;
  runner?: { status: string; keepAwake: boolean; retiredTo?: string; waitingFor?: string; clients: Array<{ name: string; platform: string; lastSeen: number }>; runs: Array<{ scheduleID: string; occurrence: string; at: number; status: string; detail?: string }> };
  paired?: { runnerName: string; host: string; lastSync?: number; lastError?: string; moved?: string; unsent: number };
  schedules: number; scenes: number;
  lights: { total: number; lan: number; cloudConnected: boolean };
  webhook: { running: boolean; status: string };
  doorbell?: { enabled: boolean; phase?: string; status?: string; relayState?: string };
  warnings: string[];
  recentErrors: Array<{ time: number; message: string }>;
}

/** Allowlisted fields only: pairing codes and tokens in the views are deliberately not copied. */
export function statusRecord(home: Home, config: BridgeConfig, started: number, appVersion: string): BridgeStatus {
  const s = home.snapshot();
  const v = s.scheduleSync;
  const lanLights = s.devices.filter((d) => d.ip).length;
  const warnings: string[] = [...v.notices];
  if (!s.cloudConnected && lanLights === 0) warnings.push('No lights are reachable: add a Govee API key (luma-bridge configure --govee-key) or turn on LAN Control in the Govee app. Scheduled scenes will fail until then.');
  if (/^(UTC|Etc\/|GMT)/.test(v.timeZone)) warnings.push(`This computer's time zone is ${v.timeZone}. Schedule times use it; set the local zone (for example: sudo timedatectl set-timezone America/New_York).`);
  if (v.role === 'paired') warnings.push(`Paired with ${v.paired?.runnerName ?? 'another runner'}: this bridge does not run schedules. Run "luma-bridge take-over" to move them here.`);
  if (v.runner?.retiredTo) warnings.push(`Schedules now run on ${v.runner.retiredTo}. This bridge only tells devices where they went.`);
  if (v.runner?.waitingFor) warnings.push(`Waiting for ${v.runner.waitingFor} to confirm it stopped. Nothing runs here until then.`);
  if (v.role === 'runner' && !home.scheduleSync.listening && !v.runner?.retiredTo) warnings.push(`The schedule sync server is not running: ${v.runner?.status ?? 'unknown'}`);
  const db = doorbellOf(home)?.view();
  return {
    version: 1, pid: process.pid, startedAt: started, updatedAt: Date.now(), appVersion, secrets: config.secrets,
    role: v.role, mayExecute: v.mayExecute, listening: home.scheduleSync.listening, port: home.scheduleSync.port, deviceName: v.deviceName, timeZone: v.timeZone,
    ...(v.runner ? { runner: { status: v.runner.status, keepAwake: v.runner.keepAwake, ...(v.runner.retiredTo ? { retiredTo: v.runner.retiredTo } : {}), ...(v.runner.waitingFor ? { waitingFor: v.runner.waitingFor } : {}),
      clients: v.runner.clients.map((c) => ({ name: c.name, platform: c.platform, lastSeen: c.lastSeen })),
      runs: v.runner.runs.map((r) => ({ scheduleID: r.scheduleID, occurrence: r.occurrence, at: r.at, status: r.status, ...(r.detail ? { detail: r.detail } : {}) })) } } : {}),
    ...(v.paired ? { paired: { runnerName: v.paired.runnerName, host: v.paired.host, lastSync: v.paired.lastSync, lastError: v.paired.lastError, moved: v.paired.moved, unsent: v.paired.unsent } } : {}),
    schedules: s.schedules.length, scenes: s.scenes.length,
    lights: { total: s.devices.length, lan: lanLights, cloudConnected: s.cloudConnected },
    webhook: { running: s.webhook.running, status: s.webhook.status },
    ...(db ? { doorbell: { enabled: db.config?.enabled === true, phase: db.phase, status: db.status, relayState: db.relayState } } : {}),
    warnings,
    recentErrors: s.activity.filter((a) => a.isError).slice(0, 10).map((a) => ({ time: a.time, message: a.message })),
  };
}

export type BridgeState = { state: 'running'; status?: BridgeStatus } | { state: 'stale'; status?: BridgeStatus; pid: number } | { state: 'stopped'; status?: BridgeStatus };

/** What `luma-bridge status` reports: running (lock live and heartbeat fresh), stale (lock live, no heartbeat), or stopped. */
export function readState(dir: string, now = Date.now()): BridgeState {
  let status: BridgeStatus | undefined;
  try { status = JSON.parse(readFileSync(join(dir, STATUS_FILE), 'utf8')) as BridgeStatus; } catch { /* never started */ }
  const lock = readLock(dir);
  if (!lockIsLive(lock)) return { state: 'stopped', status };
  if (status && status.pid === lock!.pid && !status.stoppedAt && now - status.updatedAt < HEARTBEAT_MS * 4) return { state: 'running', status };
  return { state: 'stale', status, pid: lock!.pid };
}

// ---------- keep awake ----------

/** Helpers die with the bridge: caffeinate -w and tail --pid both watch this process. */
export function keepAwakeHelper(log: Log): (on: boolean) => void {
  let child: ChildProcess | undefined;
  return (on) => {
    if (!on) { child?.kill(); child = undefined; return; }
    if (child) return;
    const pid = String(process.pid);
    const cmd: [string, string[]] | undefined = process.platform === 'darwin' ? ['/usr/bin/caffeinate', ['-i', '-w', pid]]
      : process.platform === 'linux' ? ['systemd-inhibit', ['--what=idle:sleep', '--who=Luma Bridge', '--why=Running shared schedules', '--mode=block', 'tail', `--pid=${pid}`, '-f', '/dev/null']]
        : undefined;
    if (!cmd) { log('Keep awake is not available in the bridge on Windows. Set the power plan to never sleep instead.', true); return; }
    const proc = spawn(cmd[0], cmd[1], { stdio: 'ignore' });
    child = proc;
    proc.on('error', (error) => { log(`Keep awake failed: ${error.message}`, true); if (child === proc) child = undefined; });
    proc.on('exit', (code) => { if (child === proc) { child = undefined; if (code) log(`Keep awake stopped (exit ${code}). Sleep may interrupt schedules.`, true); } });
  };
}

// ---------- daemon ----------

export interface BridgeRuntime {
  readonly home: Home;
  readonly dataDir: string;
  status(): BridgeStatus;
  stop(): Promise<void>;
}

export interface StartOptions {
  dataDir: string;
  version: string;
  log?: Log;
  /** Tests: Home overrides (clock, transports). */
  homeOptions?: Partial<HomeOptions>;
}

/**
 * Runs the bridge until stop(). Throws (after releasing the lock) when it must not run:
 * not set up, secret storage unavailable, unreadable state, or a runner that cannot listen.
 */
export async function startBridge(options: StartOptions): Promise<BridgeRuntime> {
  const { dataDir, version } = options;
  const log: Log = options.log ?? ((line, isError) => (isError ? process.stderr : process.stdout).write(`${new Date().toISOString()} ${isError ? 'error' : 'info '} ${line}\n`));
  prepareDataDir(dataDir);
  const release = acquireLock(dataDir);
  let home: Home | undefined;
  const timers: NodeJS.Timeout[] = [];
  const awake = keepAwakeHelper(log);
  try {
    const config = readConfig(dataDir);
    if (!config) throw new Error(`Not set up. Run "luma-bridge setup" first (data folder ${dataDir}).`);
    home = openHome(dataDir, config, version, { ...options.homeOptions, scheduleSyncOptions: { keepAwake: awake, ...options.homeOptions?.scheduleSyncOptions } });
    const h = home;
    const sync = h.scheduleSync.view();
    if (sync.role === 'off') throw new Error('This bridge is not sharing schedules. Run "luma-bridge setup" (run them here) or "luma-bridge pair" first.');
    if (sync.role === 'paired' && !sync.paired) throw new Error(`${join(dataDir, 'schedule-sync.json')} could not be read. It was left untouched and nothing runs. Move it away and run setup again.`);
    const started = Date.now();
    let printed = new Set(h.snapshot().activity.map((a) => a.id));
    let pending: NodeJS.Timeout | undefined;
    let stopped = false;
    const writeStatus = (extra: Partial<BridgeStatus> = {}) => {
      try { writeAtomic(join(dataDir, STATUS_FILE), JSON.stringify({ ...statusRecord(h, config, started, version), ...extra }, null, 2)); }
      catch (error) { log(`Could not write ${STATUS_FILE}: ${message(error)}`, true); }
    };
    const flush = () => {
      pending = undefined;
      const activity = h.snapshot().activity;
      for (const a of [...activity].reverse()) if (!printed.has(a.id)) log(a.message, a.isError);
      printed = new Set(activity.map((a) => a.id));
      writeStatus();
    };
    h.subscribe(() => { if (!stopped) pending ??= setTimeout(flush, 200); });

    await h.scheduleSync.start();
    if (sync.role === 'runner' && !sync.runner?.retiredTo && !h.scheduleSync.listening) {
      throw new Error(`The schedule sync server could not start on port ${h.scheduleSync.port}. ${h.scheduleSync.view().runner?.status ?? ''} If a Luma window on this computer runs schedules, hand them over instead of running both (see docs/LOCAL-BRIDGE.md), or choose another port with "luma-bridge configure --port".`);
    }
    if (config.lan) {
      const scan = () => h.discover().catch((error) => log(`LAN discovery failed: ${message(error)}`, true));
      void scan();
      timers.push(setInterval(scan, DISCOVERY_MS));
    }
    if (h.snapshot().hasSavedKey) void h.reconnect().catch(() => undefined); // Home logs the failure
    if (config.webhook) await h.startWebhook().catch(() => undefined); // Home logs the failure; the runner keeps working
    timers.push(setInterval(() => writeStatus(), HEARTBEAT_MS));
    writeStatus();
    if (process.getuid?.() === 0) log('Running as root. Run the bridge as a normal user: it needs no privileges, and root widens what a bug could reach.', true);
    const name = h.scheduleSync.view().deviceName;
    log(`Luma Bridge ${version} running as "${name}" (${sync.role}), data ${dataDir}, secrets ${config.secrets}, port ${h.scheduleSync.port}. Stop with Ctrl+C or your service manager.`);

    let stopping: Promise<void> | undefined;
    return {
      home: h, dataDir,
      status: () => statusRecord(h, config, started, version),
      stop: () => (stopping ??= (async () => {
        stopped = true;
        clearTimeout(pending);
        for (const t of timers) clearInterval(t);
        await h.shutdown();
        awake(false);
        flush();
        writeStatus({ stoppedAt: Date.now(), listening: false });
        release();
        log('Luma Bridge stopped.');
      })()),
    };
  } catch (error) {
    for (const t of timers) clearInterval(t);
    await home?.shutdown().catch(() => undefined);
    awake(false);
    release();
    throw error;
  }
}

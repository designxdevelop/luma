// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Linux session-lock observer for Screen Sync. Electron's powerMonitor 'lock-screen' exists only on
// macOS and Windows, so on Linux we read systemd-logind's Session.LockedHint (read-only):
//   loginctl show-session <XDG_SESSION_ID|self> -p LockedHint --value
// and keep a D-Bus signal subscription (gdbus monitor on org.freedesktop.login1) open so a lock
// change wakes a fresh read at once instead of waiting for the next poll.
//
// Honest limits (nothing here is validated on a real desktop):
// - LockedHint is set by the desktop's screen locker, not by logind. Desktops that never set it
//   report "no" forever, which looks identical to "unlocked". Only GNOME and KDE Plasma are allowed;
//   every other desktop is refused rather than guessed (see linuxLockSupport).
// - gdbus prints its "name is owned by" header BEFORE it subscribes (GLib gdbus-tool.c), so the header is
//   not a subscription acknowledgement. Ready is reported READY_GRACE_MS after it, and a signal that
//   shows a lock before then refuses the attempt. A lock/unlock pair that slips through in that
//   startup window is unprovable here; a fully missed lock/unlock pair can go undetected.
// - Fail closed: an unsupported desktop, a missing/failed/timed-out/garbled read, or a lost
//   subscription is "unavailable" and behaves like a lock (revoke and stop; nothing restarts itself).
// - "Unlocked" is accepted only while the signal subscription is live, and only from a read taken
//   after that subscription was established. A lock that begins and ends between two reads without a
//   signal reaching us can go undetected; polling only catches a lock still set when read.
// Electron-free; commands run through execFile/spawn with fixed argv (no shell).

import { execFile, spawn } from 'node:child_process';
import { LumaError } from '../core/model';

export type LockState = 'unlocked' | 'locked' | 'unavailable';
export type LockSupport = { ok: true; sessionId: string } | { ok: false; reason: string };

const SESSION_ID = /^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,31}$/;
/** Desktops known to call logind SetLockedHint when their screen locker engages. Not validated here. */
const REPORTING_DESKTOPS = new Set(['gnome', 'kde']);

const UNSUPPORTED = 'Screen Sync on Linux needs a GNOME or KDE Plasma session that reports screen lock to systemd-logind, so it can stop when the PC locks. This session cannot be verified. LAN and cloud lights still work.';

/** Pure. Decides whether lock reporting may be trusted for this environment, and which session to read. */
export function linuxLockSupport(env: Record<string, string | undefined>): LockSupport {
  const desktops = (env.XDG_CURRENT_DESKTOP ?? '').toLowerCase().split(':').map((d) => d.trim());
  if (!desktops.some((d) => REPORTING_DESKTOPS.has(d))) return { ok: false, reason: UNSUPPORTED };
  const id = env.XDG_SESSION_ID;
  if (id === undefined || id === '') return { ok: true, sessionId: 'self' };
  // Validated as one bounded argv element that cannot look like an option; an odd value is refused, never passed on.
  return SESSION_ID.test(id) ? { ok: true, sessionId: id } : { ok: false, reason: UNSUPPORTED };
}

export function lockedHintArgs(sessionId: string): string[] {
  return ['show-session', sessionId, '-p', 'LockedHint', '--value'];
}

/** loginctl prints yes/no for a boolean property. Anything else is not an answer. */
export function parseLockedHint(output: string): LockState {
  const v = output.trim().toLowerCase();
  return v === 'no' ? 'unlocked' : v === 'yes' ? 'locked' : 'unavailable';
}

export interface WatchHandlers {
  /** The signal subscription is established. Unlocked reads are only accepted after this. */
  ready(): void;
  /** A lock-related signal arrived: read again now. */
  wake(): void;
  /** Session.Lock or LockedHint=true was seen. Invalidates at once, before any read (a fast Lock/Unlock must not slip past). */
  locked(): void;
  /** The subscription is gone (process exited, or login1 vanished or changed owner). */
  lost(): void;
}

export interface LockMonitorDeps {
  support: LockSupport;
  /** Raw `LockedHint` output for the session. Rejects on any failure or timeout. */
  read: (sessionId: string) => Promise<string>;
  /** Starts the signal subscription; returns its stop function. */
  watch: (handlers: WatchHandlers) => () => void;
  /** One-shot timer; the real one is unref'd so it never keeps the app alive. */
  schedule: (fn: () => void, ms: number) => () => void;
  /** Extra reason to keep observing (an active or paused session). */
  needed?: () => boolean;
  now?: () => number;
  pollMs?: number;
  readyMs?: number;
  /** Keep observing this long after a successful guarded call (offered sources stay usable that long). */
  holdMs?: number;
}

type Listener = (kind: 'locked' | 'unavailable') => void;

export class LinuxLockMonitor {
  private state: LockState | 'unknown' = 'unknown';
  private epoch = 0;
  private seq = 0;
  private applied = 0;
  private busy = 0;
  private holdUntil = 0;
  private polling = false;
  private again = false;
  private armed = false;
  private disposed = false;
  private cancelTick?: () => void;
  private watcher?: { stop: () => void; ready: Promise<boolean>; live: boolean };
  private readonly listeners: Listener[] = [];
  private readonly now: () => number;
  private readonly pollMs: number;
  private readonly readyMs: number;
  private readonly holdMs: number;

  constructor(private readonly deps: LockMonitorDeps) {
    this.now = deps.now ?? Date.now;
    this.pollMs = deps.pollMs ?? 500;
    this.readyMs = deps.readyMs ?? 3000;
    this.holdMs = deps.holdMs ?? 125_000;
  }

  /** Called when the PC locks or lock detection fails. Must be idempotent. */
  onLock(listener: Listener): void { this.listeners.push(listener); }

  /** Trusted only with a live subscription and an unlocked read. */
  get unlocked(): boolean { return !this.disposed && this.state === 'unlocked' && !!this.watcher?.live; }

  /** Subscribes, reads fresh and returns the lock epoch; throws unless unlocked is affirmed. */
  async check(): Promise<number> {
    if (this.disposed) throw this.refusal('unavailable');
    if (!this.deps.support.ok) { this.observe(0, 'unavailable'); throw new LumaError(this.deps.support.reason, 501); }
    if (!(await this.subscribe())) { this.observe(++this.seq, 'unavailable'); throw this.refusal('unavailable'); }
    this.arm();
    await this.readOnce();
    if (!this.unlocked) throw this.refusal(this.state === 'locked' ? 'locked' : 'unavailable');
    return this.epoch;
  }

  /** Throws if a lock or failure was observed since `epoch` (a stale unlocked result must not grant anything). */
  confirm(epoch: number): void {
    if (epoch !== this.epoch) throw this.refusal(this.state === 'unavailable' ? 'unavailable' : 'locked'); // something changed since
    if (!this.unlocked) throw this.refusal(this.state === 'locked' ? 'locked' : 'unavailable');
  }

  /** Runs `run` between an unlocked check and a final confirm; `run` may call confirm earlier, before it grants. */
  async guard<T>(run: (confirm: () => void) => Promise<T>): Promise<T> {
    this.busy++;
    try {
      const epoch = await this.check();
      const confirm = () => this.confirm(epoch);
      const result = await run(confirm);
      confirm();
      this.holdUntil = this.now() + this.holdMs;
      return result;
    } finally { this.busy--; }
  }

  dispose(): void {
    this.disposed = true;
    this.cancelTick?.();
    this.cancelTick = undefined;
    this.dropWatcher();
    this.listeners.length = 0;
  }

  private refusal(kind: 'locked' | 'unavailable'): LumaError {
    return kind === 'locked'
      ? new LumaError('The PC is locked. Unlock it, then choose the screen or window again.', 409)
      : new LumaError('Luma cannot confirm that the screen is unlocked right now, so it will not capture. Try again; if it persists, this desktop may not report screen lock to systemd-logind. LAN and cloud lights still work.', 503);
  }

  private needed(): boolean { return this.busy > 0 || this.now() < this.holdUntil || !!this.deps.needed?.(); }

  /** Starts the signal subscription once; resolves true only after it reported ready. */
  private subscribe(): Promise<boolean> {
    if (this.watcher) return this.watcher.ready;
    let settle!: (ok: boolean) => void;
    const ready = new Promise<boolean>((resolve) => { settle = resolve; });
    const w = { stop: () => {}, ready, live: false };
    this.watcher = w;
    const cancelTimeout = this.deps.schedule(() => settle(false), this.readyMs);
    const stop = this.deps.watch({
      ready: () => { if (this.watcher === w) { w.live = true; settle(true); } },
      wake: () => { if (this.watcher === w && w.live && this.needed()) void this.poll(); },
      locked: () => {
        if (this.watcher !== w) return;
        if (!w.live) { settle(false); return; } // lock seen while still subscribing: refuse this attempt
        this.observe(++this.seq, 'locked'); // any session's lock counts: over-stopping is the safe side
        if (this.needed()) void this.poll();
      },
      lost: () => {
        settle(false);
        if (this.watcher === w) { this.dropWatcher(); this.observe(++this.seq, 'unavailable'); }
      },
    });
    w.stop = stop;
    if (this.watcher !== w) stop(); // it was lost while starting
    void ready.then((ok) => { cancelTimeout(); if (!ok && this.watcher === w) this.dropWatcher(); });
    return ready;
  }

  private dropWatcher(): void {
    const w = this.watcher;
    this.watcher = undefined;
    if (w) { w.live = false; try { w.stop(); } catch { /* already gone */ } }
  }

  private arm(): void {
    if (this.armed || this.disposed) return;
    this.armed = true;
    const next = () => {
      if (this.disposed) return;
      this.cancelTick = this.deps.schedule(() => { if (this.watcher?.live && this.needed()) void this.poll().finally(next); else next(); }, this.pollMs);
    };
    next();
  }

  private async poll(): Promise<void> {
    if (this.polling) { this.again = true; return; }
    this.polling = true;
    try { do { this.again = false; await this.readOnce(); } while (this.again && !this.disposed); }
    finally { this.polling = false; }
  }

  private async readOnce(): Promise<void> {
    const seq = ++this.seq;
    const id = this.deps.support.ok ? this.deps.support.sessionId : 'self';
    let state: LockState;
    try { state = parseLockedHint(await this.deps.read(id)); } catch { state = 'unavailable'; }
    // The subscription may have died while the read was in flight: unlocked is then not trustworthy.
    if (state === 'unlocked' && !this.watcher?.live) state = 'unavailable';
    this.observe(seq, state);
  }

  /** An older locked/unavailable result still counts (fail closed); an older unlocked never overwrites a newer result. */
  private observe(seq: number, next: LockState): void {
    if (this.disposed) return;
    const fresh = seq > this.applied;
    if (fresh) this.applied = seq;
    if (next === 'unlocked' && !fresh) return;
    const before = this.state;
    this.state = next;
    if (next === 'unlocked' || before === next) return;
    this.epoch++;
    this.holdUntil = 0;
    for (const listener of [...this.listeners]) { try { listener(next); } catch { /* a listener must not break the others */ } }
  }
}

const SAFE_ENV = { PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL: 'C' };

function realRead(sessionId: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile('loginctl', lockedHintArgs(sessionId), { timeout: 2000, maxBuffer: 1024, env: SAFE_ENV, encoding: 'utf8', windowsHide: true }, (error, stdout) => {
      if (error) reject(error); else resolve(stdout);
    });
  });
}

export type WatchLine = 'owned' | 'lost' | 'locked' | 'wake' | undefined;

/** Pure classifier for `gdbus monitor` output lines. `owned` is true once login1's owner was announced. */
export function classifyWatchLine(line: string, owned: boolean): WatchLine {
  if (/^The name org\.freedesktop\.login1 is owned by /.test(line)) return owned ? 'lost' : 'owned'; // a new owner is a restart
  if (/^The name org\.freedesktop\.login1 does not have an owner/.test(line)) return 'lost'; // gdbus unsubscribes but keeps running
  if (/\.Session\.Lock \(|'LockedHint': <true>/.test(line)) return 'locked';
  return /lock/i.test(line) ? 'wake' : undefined;
}

const READY_GRACE_MS = 300;

/** `gdbus monitor` prints one line per login1 signal, plus owner announcements. */
function realWatch(handlers: WatchHandlers): () => void {
  const child = spawn('gdbus', ['monitor', '--system', '--dest', 'org.freedesktop.login1'], { stdio: ['ignore', 'pipe', 'ignore'], env: SAFE_ENV, windowsHide: true });
  let pending = '';
  let gone = false;
  let owned = false;
  let grace: NodeJS.Timeout | undefined;
  const stop = () => { gone = true; if (grace) clearTimeout(grace); child.kill('SIGTERM'); };
  const lost = () => { if (!gone) { stop(); handlers.lost(); } };
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk: string) => {
    const lines = (pending + chunk).split('\n');
    pending = (lines.pop() ?? '').slice(-4096); // bounded: a never-ending line cannot grow memory
    for (const line of lines) {
      if (gone) return;
      const kind = classifyWatchLine(line, owned);
      if (kind === 'owned') {
        owned = true;
        grace = setTimeout(() => { if (!gone) handlers.ready(); }, READY_GRACE_MS); // header precedes the subscribe call
        grace.unref();
      } else if (kind === 'lost') lost();
      else if (kind === 'locked') handlers.locked();
      else if (kind === 'wake') handlers.wake();
    }
  });
  child.on('error', lost);
  child.on('exit', lost);
  child.unref();
  (child.stdout as unknown as { unref?: () => void }).unref?.();
  return stop;
}

const realSchedule = (fn: () => void, ms: number) => { const t = setTimeout(fn, ms); t.unref?.(); return () => clearTimeout(t); };

/** Only real connected mode on Linux gets an observer. Demo and every other OS get none, and nothing spawns until first use. */
export function createLinuxLockMonitor(options: { real: boolean; platform: NodeJS.Platform; env: Record<string, string | undefined>; needed?: () => boolean }): LinuxLockMonitor | undefined {
  if (!options.real || options.platform !== 'linux') return undefined;
  return new LinuxLockMonitor({ support: linuxLockSupport(options.env), read: realRead, watch: realWatch, schedule: realSchedule, needed: options.needed });
}

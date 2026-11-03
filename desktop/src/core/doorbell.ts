// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Doorbell alert: snapshot, a slow bounded pulse, then an exact restore. Mirrors the native
// DoorbellAlertEngine. All light I/O goes through `AlertIO`, so tests use a virtual clock.

import type { CapabilityCommand, DoorbellConfig, LightDevice } from '../shared/types';
import { LumaError, brightness, kelvin, power, rgb, supports } from './model';
import { isLight } from '../shared/devices';

export type { DoorbellConfig };

export const defaultDoorbell = (): DoorbellConfig => ({ enabled: false, rooms: [], deviceIDs: [], rgb: 0x2f7bff, durationSeconds: 15, pulseSeconds: 2, brightnessCap: 100, quietBrightnessCap: 20, cooldownSeconds: 20 });
export const MAX_ALERT_LIGHTS = 20;

const isInt = (v: unknown, lo: number, hi: number): v is number => Number.isInteger(v) && (v as number) >= lo && (v as number) <= hi;
const names = (v: unknown, max: number): string[] => {
  if (!Array.isArray(v) || v.length > max || !v.every((s) => typeof s === 'string' && s.length > 0 && s.length <= 160 && !/[\u0000-\u001f]/.test(s))) throw new LumaError('Invalid alert targets.');
  return [...new Set(v as string[])];
};

/** Decodes and validates untrusted settings (renderer IPC or the saved file). */
export function decodeDoorbell(value: unknown): DoorbellConfig {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new LumaError('Invalid doorbell settings.');
  const v = { ...defaultDoorbell(), ...(value as Record<string, unknown>) } as Record<string, unknown>;
  const check = (ok: boolean, text: string) => { if (!ok) throw new LumaError(text); };
  check(typeof v.enabled === 'boolean', 'Invalid doorbell settings.');
  check(isInt(v.rgb, 0, 0xffffff), 'Choose a valid alert color.');
  check(isInt(v.durationSeconds, 5, 60), 'Alert length must be 5–60 seconds.');
  check(typeof v.pulseSeconds === 'number' && v.pulseSeconds >= 2 && v.pulseSeconds <= 6, 'Pulse must be 2–6 seconds per cycle.');
  check(isInt(v.brightnessCap, 10, 100), 'Brightness cap must be 10–100%.');
  check(isInt(v.quietBrightnessCap, 0, 100), 'Quiet-hours brightness must be 0–100%.');
  check(isInt(v.cooldownSeconds, 0, 300), 'Cooldown must be 0–300 seconds.');
  check((v.quietStart === undefined) === (v.quietEnd === undefined), 'Set both quiet-hours times, or neither.');
  if (v.quietStart !== undefined) check(isInt(v.quietStart, 0, 1439) && isInt(v.quietEnd, 0, 1439), 'Quiet hours must be times of day.');
  if (v.relayURL !== undefined) check(typeof v.relayURL === 'string' && validRelay(v.relayURL), 'The relay address must be an https:// URL without a query or password.');
  const rooms = names(v.rooms, 50), deviceIDs = names(v.deviceIDs, 50);
  return {
    enabled: v.enabled as boolean, rooms, deviceIDs, rgb: v.rgb as number, durationSeconds: v.durationSeconds as number, pulseSeconds: v.pulseSeconds as number,
    brightnessCap: v.brightnessCap as number, quietBrightnessCap: v.quietBrightnessCap as number, cooldownSeconds: v.cooldownSeconds as number,
    ...(v.quietStart !== undefined ? { quietStart: v.quietStart as number, quietEnd: v.quietEnd as number } : {}),
    ...(v.relayURL !== undefined ? { relayURL: v.relayURL as string } : {}),
  };
}

function validRelay(text: string): boolean {
  try { const u = new URL(text); return u.protocol === 'https:' && !!u.hostname && !u.search && !u.username && !u.password; } catch { return false; }
}

export interface AlertSnapshot { power: boolean; brightness: number; rgb?: number; kelvin?: number }

/** Color or white, then brightness, then power, so an off lamp keeps no hidden alert color. */
export function restoreCommands(s: AlertSnapshot): CapabilityCommand[] {
  return [...(s.kelvin !== undefined ? [kelvin(s.kelvin)] : s.rgb !== undefined ? [rgb(s.rgb)] : []), brightness(s.brightness), power(s.power)];
}

/** Off lights are compared by power only: many models don't report color while off. */
export function snapshotMatches(s: AlertSnapshot, d: LightDevice): boolean {
  if (d.power !== s.power) return false;
  if (!s.power) return true;
  if (d.brightness !== s.brightness) return false;
  return s.kelvin !== undefined ? d.colorTemperature === s.kelvin : d.rgb === s.rgb;
}

/** Power, brightness, and color or white must all be known; nothing is guessed. */
export function snapshotOf(d: LightDevice): AlertSnapshot {
  if (d.online === false) throw new LumaError('offline');
  if (d.power === undefined) throw new LumaError('power unknown');
  if (!d.brightness) throw new LumaError('brightness unknown');
  if (d.colorTemperature) return { power: d.power, brightness: d.brightness, kelvin: d.colorTemperature };
  if (d.rgb === undefined) throw new LumaError('color unknown');
  return { power: d.power, brightness: d.brightness, rgb: d.rgb };
}

/** Lights in the chosen rooms (now) plus chosen lights; never appliances. */
export function alertTargets(config: DoorbellConfig, devices: LightDevice[]): LightDevice[] {
  return devices.filter((d) => (config.rooms.includes(d.room) || config.deviceIDs.includes(d.id)) && isLight(d)
    && ['powerSwitch', 'brightness', 'colorRgb'].every((i) => supports(d, i))).slice(0, MAX_ALERT_LIGHTS);
}

export function inQuietHours(config: DoorbellConfig, date: Date): boolean {
  const { quietStart: start, quietEnd: end } = config;
  if (start === undefined || end === undefined || start === end) return false;
  const minute = date.getHours() * 60 + date.getMinutes();
  return start < end ? minute >= start && minute < end : minute >= start || minute < end;
}

export type Route = 'lan' | 'cloud';
export interface Candidate { id: string; name: string; route: Route; snapshot?: AlertSnapshot; skip?: string }
export interface AlertIO {
  devices(): LightDevice[];
  /** Fresh-reads each target; returns its snapshot or why it is skipped. */
  prepare(targets: LightDevice[]): Promise<Candidate[]>;
  /** One direct write: no queue, no readback, never saved as reported state. */
  pulse(id: string, command: CapabilityCommand): Promise<void>;
  /** Writes the snapshot back, reads once, and returns whether the light confirmed it. */
  restore(id: string, snapshot: AlertSnapshot): Promise<boolean>;
  log(text: string, isError: boolean): void;
  changed(): void;
}
export type Outcome = 'started' | 'coalesced' | 'cooldown' | 'duplicate' | 'disabled' | 'quiet';
export type Phase = 'idle' | 'starting' | 'flashing' | 'restoring';
export interface AlertClock { now(): number; date(): Date; sleep(ms: number, signal: AbortSignal): Promise<void> }

interface Light { id: string; name: string; route: Route; snapshot: AlertSnapshot; touched: boolean; takenOver: boolean; restored: boolean; failed: boolean }

// ponytail: fixed write budgets. Govee documents 10,000 cloud requests a day; ~10 per device
// per minute is community-reported, so cloud lights hold the color instead of pulsing.
const LAN_GAP = 20, CLOUD_GAP = 350, CLOUD_REUSE = 60_000;

export const realClock: AlertClock = {
  now: () => performance.now(),
  date: () => new Date(),
  sleep: (ms, signal) => new Promise((resolve, reject) => {
    if (signal.aborted) { reject(new LumaError('stopped')); return; }
    const timer = setTimeout(() => { signal.removeEventListener('abort', onAbort); resolve(); }, ms);
    const onAbort = () => { clearTimeout(timer); reject(new LumaError('stopped')); };
    signal.addEventListener('abort', onAbort, { once: true });
  }),
};

export class DoorbellEngine {
  config: DoorbellConfig = defaultDoorbell();
  phase: Phase = 'idle';
  status = 'Ready';
  private lights: Light[] = [];
  private takenOver = new Set<string>();
  private seen = new Map<string, number>();
  private cloudUsed = new Map<string, number>();
  private cooldownUntil = -Infinity;
  private stopRequested = false;
  private flash = new AbortController();
  private abandoned = false;
  private runner?: Promise<void>;

  constructor(private readonly io: AlertIO, private readonly clock: AlertClock = realClock) {}

  /** Repeated rings coalesce into the running alert; replays of the same event are ignored. */
  trigger(eventID: string): Outcome {
    if (!this.config.enabled) return 'disabled';
    const t = this.clock.now();
    for (const [id, at] of this.seen) if (t - at >= 600_000) this.seen.delete(id);
    if (this.seen.has(eventID)) return 'duplicate';
    if (this.seen.size >= 256) this.seen.delete(this.seen.keys().next().value!);
    this.seen.set(eventID, t);
    if (this.phase !== 'idle') return 'coalesced';
    if (t < this.cooldownUntil) return 'cooldown';
    const cap = inQuietHours(this.config, this.clock.date()) ? Math.min(this.config.quietBrightnessCap, this.config.brightnessCap) : this.config.brightnessCap;
    if (cap <= 0) { this.status = 'Rang during quiet hours; lights left alone.'; return 'quiet'; }
    this.phase = 'starting'; this.stopRequested = false; this.abandoned = false; this.takenOver.clear(); this.lights = [];
    this.flash = new AbortController();
    this.status = 'Ringing…';
    this.runner = this.run(cap);
    this.io.changed();
    return 'started';
  }

  stop(): void {
    if (this.phase === 'idle') return;
    this.stopRequested = true;
    this.flash.abort();
  }

  /** A manual change, scene, schedule or webhook took this light: it is not restored. */
  yield(id: string): void {
    if (this.phase === 'idle') return;
    this.takenOver.add(id);
    const light = this.lights.find((l) => l.id === id);
    if (light) light.takenOver = true;
  }

  isAlerting(id: string): boolean { return this.phase !== 'idle' && this.lights.some((l) => l.id === id && !l.takenOver && !l.failed); }

  /** For app shutdown: the restores still owed, for the caller to send at once. Ends the alert. */
  takePendingRestores(): Array<{ id: string; route: Route; snapshot: AlertSnapshot }> {
    const owed = this.lights.filter((l) => l.touched && !l.takenOver && !l.restored).map(({ id, route, snapshot }) => ({ id, route, snapshot }));
    this.abandoned = true; this.flash.abort();
    this.lights = []; this.phase = 'idle';
    return owed;
  }

  settle(): Promise<void> { return this.runner ?? Promise.resolve(); }

  private async run(cap: number): Promise<void> {
    const t0 = this.clock.now();
    const candidates = await this.io.prepare(alertTargets(this.config, this.io.devices()));
    const skipped: string[] = [];
    for (const c of candidates) {
      if (!c.snapshot) { skipped.push(`${c.name} (${c.skip ?? 'skipped'})`); continue; }
      const used = this.cloudUsed.get(c.id);
      if (c.route === 'cloud' && used !== undefined && t0 - used < CLOUD_REUSE) { skipped.push(`${c.name} (cloud limit: alerted under a minute ago)`); continue; }
      this.lights.push({ id: c.id, name: c.name, route: c.route, snapshot: c.snapshot, touched: false, takenOver: this.takenOver.has(c.id), restored: false, failed: false });
    }
    if (skipped.length) this.io.log(`Doorbell alert skipped ${skipped.join(', ')}.`, false);
    if (this.abandoned) return;
    if (!this.lights.length || this.stopRequested) { this.finish(this.lights.length ? 'Stopped before flashing.' : 'Rang, but no light could be alerted safely.'); return; }
    for (const l of this.lights) if (l.route === 'cloud') this.cloudUsed.set(l.id, t0);
    this.phase = 'flashing'; this.io.changed();
    await this.pulse(cap);
    if (this.abandoned) return; // shutdown took the restores
    this.phase = 'restoring'; this.io.changed();
    let confirmed = 0;
    const unconfirmed: string[] = [], failed: string[] = [];
    for (const l of this.lights) {
      if (!l.touched || l.takenOver) continue;
      try { if (await this.io.restore(l.id, l.snapshot)) confirmed++; else unconfirmed.push(l.name); }
      catch (error) { failed.push(`${l.name}: ${error instanceof Error ? error.message : String(error)}`); }
      l.restored = true;
      await this.clock.sleep(l.route === 'cloud' ? 1000 : LAN_GAP, new AbortController().signal);
    }
    const flashed = this.lights.filter((l) => l.touched).length, taken = this.lights.filter((l) => l.takenOver).length;
    let summary = `Flashed ${flashed} light${flashed === 1 ? '' : 's'}; restored ${confirmed}`;
    if (unconfirmed.length) summary += `; sent but not confirmed: ${unconfirmed.join(', ')}`;
    if (taken) summary += `; ${taken} left as changed during the alert`;
    if (failed.length) summary += `; couldn't restore ${failed.join('; ')}`;
    this.finish(`${summary}.`, failed.length > 0);
  }

  private finish(summary: string, isError = false): void {
    this.status = summary;
    this.io.log(`Doorbell alert: ${summary}`, isError);
    this.cooldownUntil = this.clock.now() + this.config.cooldownSeconds * 1000;
    this.lights = []; this.phase = 'idle';
    this.io.changed();
  }

  private async pulse(cap: number): Promise<void> {
    const signal = this.flash.signal;
    const high = cap, low = Math.max(1, Math.round(cap * 0.2));
    const end = this.clock.now() + this.config.durationSeconds * 1000;
    for (const l of this.lights) {
      for (const c of [...(l.snapshot.power ? [] : [power(true)]), rgb(this.config.rgb), brightness(high)]) if (!(await this.write(l, c))) break;
      if (signal.aborted) return;
    }
    let bright = true;
    while (this.clock.now() < end && this.lights.some((l) => !l.takenOver && !l.failed)) {
      try { await this.clock.sleep(this.config.pulseSeconds * 500, signal); } catch { return; }
      if (this.clock.now() >= end) return;
      bright = !bright;
      // Cloud lights hold the alert color: pulsing them would exceed Govee's per-device limits.
      for (const l of this.lights) {
        if (l.route !== 'lan' || l.takenOver || l.failed) continue;
        await this.write(l, brightness(bright ? high : low));
        if (signal.aborted) return;
      }
    }
  }

  private async write(l: Light, command: CapabilityCommand): Promise<boolean> {
    if (l.takenOver || l.failed || this.flash.signal.aborted) return false;
    l.touched = true;
    try { await this.io.pulse(l.id, command); }
    catch (error) {
      l.failed = true;
      this.io.log(`Doorbell alert: ${l.name} stopped flashing: ${error instanceof Error ? error.message : String(error)}`, true);
      return false;
    }
    await this.clock.sleep(l.route === 'cloud' ? CLOUD_GAP : LAN_GAP, this.flash.signal).catch(() => {});
    return true;
  }
}

// ---------- Alexa relay client (outbound HTTPS long poll) ----------

export interface RelayEvent { id: string; type: 'activate' | 'deactivate'; issuedAt: number }
type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal }) => Promise<{ status: number; json(): Promise<unknown> }>;

/** Events older (or newer) than 60 s are ignored, so a waking PC never flashes for an old ring. */
export const RELAY_FRESHNESS = 60;

export class RelayClient {
  readonly base: string;
  constructor(base: string, private readonly token: string, private readonly fetcher: Fetch = fetch as unknown as Fetch) {
    if (!validRelay(base)) throw new LumaError('The relay address must be an https:// URL.');
    if (!/^[\x21-\x7e]{32,}$/.test(token)) throw new LumaError('Paste the relay token you set when you deployed it.');
    this.base = base.replace(/\/$/, '');
  }

  async next(wait: boolean, signal: AbortSignal, now = Date.now()): Promise<RelayEvent[]> {
    const res = await this.call('hub/next', { wait }, signal, 40_000);
    if (res.status === 204) return [];
    const body = await res.json() as { events?: unknown };
    const events = Array.isArray(body.events) ? body.events : [];
    return events.filter((e): e is RelayEvent => !!e && typeof e === 'object' && typeof e.id === 'string' && e.id.length > 0 && e.id.length <= 200
      && (e.type === 'activate' || e.type === 'deactivate') && typeof e.issuedAt === 'number' && Math.abs(now / 1000 - e.issuedAt) <= RELAY_FRESHNESS);
  }

  async pairingCode(): Promise<{ code: string; expiresAt: number }> {
    const body = await (await this.call('hub/pairing-code', {})).json() as { code?: unknown; expiresAt?: unknown };
    if (typeof body.code !== 'string' || typeof body.expiresAt !== 'number') throw new LumaError('The relay sent an unexpected reply.');
    return { code: body.code, expiresAt: body.expiresAt };
  }

  async unlink(): Promise<void> { await this.call('hub/unlink', {}); }

  private async call(path: string, body: object, signal?: AbortSignal, timeout = 15_000) {
    const res = await this.fetcher(`${this.base}/${path}`, {
      method: 'POST', headers: { authorization: `Bearer ${this.token}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeout)]) : AbortSignal.timeout(timeout),
    });
    if (res.status === 200 || res.status === 204) return res;
    throw new LumaError(res.status === 401 ? "The relay rejected Luma's token. Check it matches the relay's HUB_TOKEN." : `Relay error ${res.status}.`);
  }
}

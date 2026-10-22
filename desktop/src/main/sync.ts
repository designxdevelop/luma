// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Screen Sync session controller. Electron-free and platform-neutral: a capture
// adapter (src/main/capture.ts on Windows; synthetic in demo) supplies sources, and
// the renderer supplies only bounded region averages per sampled frame. Stream values
// go through a latest-only LAN sender and are never treated as confirmed state.
// Privacy: no frame data, colors or source titles are written to the activity log.

import { randomBytes } from 'node:crypto';
import type { CapabilityCommand, LightDevice, SyncRegion, SyncSettings, SyncSource, SyncView } from '../shared/types';
import { DEFAULT_SYNC_SETTINGS, REGIONS, exceedsThreshold, gridColor, smooth, toTarget, validateGrid, validateSettings, type LightTarget, type LinearRGB } from '../shared/sync-math';
import { StreamSender, type StreamField } from '../core/stream';
import { LumaError, brightness, kelvin, message, rgb, supports } from '../core/model';

export interface SyncHost {
  /** Confirmed device records (never the pending overlay). */
  devices(): LightDevice[];
  /** True when ControlEngine has queued, sending or confirming work for the light. */
  hasPending(deviceID: string): boolean;
  sceneRunning(): boolean;
  /** The light answered on LAN during the current LAN session (a stale saved IP does not count). */
  lanReady(device: LightDevice): boolean;
  /** One direct LAN datagram (or a demo no-op). No status request, no cloud. */
  streamWrite(deviceID: string, field: StreamField, value: number): Promise<void>;
  /** Ordered restore writes through the normal engine, LAN only. Resolves when submitted. */
  restore(deviceID: string, commands: CapabilityCommand[]): Promise<void>;
  changed(): void;
  log(text: string, isError?: boolean): void;
}

export interface SyncOptions {
  demo: boolean;
  captureSupported: boolean;
  now?: () => number;
  schedule?: (fn: () => void, ms: number) => () => void;
  /** No frame for this long while running stops the session. */
  stallMs?: number;
  /** No first frame for this long after Start stops the session. */
  startMs?: number;
  /** Bound on in-flight sends when stopping. */
  drainMs?: number;
}

interface Member {
  id: string;
  name: string;
  region: SyncRegion;
  /** Last confirmed state when the session started; used only by an explicit restore. */
  original: Pick<LightDevice, 'brightness' | 'rgb' | 'colorTemperature'>;
  excluded: boolean;
  smoothed?: LinearRGB;
  target?: LightTarget;
}

const MAX_LIGHTS = 32;
/** Renderer samples at ~30 fps; the gate leaves room for worker/IPC jitter. */
const MIN_FRAME_MS = 1000 / 60;
const defaultSchedule = (fn: () => void, ms: number) => { const t = setTimeout(fn, ms); t.unref?.(); return () => clearTimeout(t); };

export class SyncController {
  settings: SyncSettings = { ...DEFAULT_SYNC_SETTINGS };
  phase: SyncView['phase'] = 'idle';
  generation = 0;
  private token?: string;
  private members = new Map<string, Member>();
  private sourceName?: string;
  private sender?: StreamSender;
  private stopping?: Promise<void>;
  private lastSeq = -1;
  private lastFrameAt = 0;
  private lastEmit = 0;
  private watchdog?: () => void;
  private lastStop?: string;
  private stats = { frames: 0, dropped: 0 };
  private readonly now: () => number;
  private readonly schedule: NonNullable<SyncOptions['schedule']>;

  constructor(private readonly host: SyncHost, private readonly options: SyncOptions) {
    this.now = options.now ?? Date.now;
    this.schedule = options.schedule ?? defaultSchedule;
  }

  get active(): boolean { return this.phase !== 'idle'; }

  /** The stream owns this light right now (manual control must exclude it first). */
  isStreaming(deviceID: string): boolean {
    const m = this.members.get(deviceID);
    return this.active && !!m && !m.excluded;
  }

  /** The light belongs to the live session, streaming or already excluded: manual writes must pass the barrier. */
  holds(deviceID: string): boolean { return this.active && this.members.has(deviceID); }

  eligibility(): SyncView['eligibility'] {
    return this.host.devices().map((d) => {
      const reason = this.ineligible(d);
      return { id: d.id, name: d.name, eligible: !reason, ...(reason ? { reason } : {}) };
    });
  }

  private ineligible(d: LightDevice): string | undefined {
    if (!d.isDemo) {
      if (!d.ip) return 'Cloud-only light: Screen Sync needs LAN Control.';
      if (!this.host.lanReady(d)) return 'Not seen on your network yet. Choose Discover.';
    }
    if (!supports(d, 'colorRgb')) return 'No RGB color.';
    if (d.online === false) return 'Offline.';
    if (d.power !== true) return 'Off or unknown. Turn it on first.';
    if (this.host.hasPending(d.id)) return 'A change is still being confirmed.';
    return undefined;
  }

  /** Validates lights and starts a session in "starting": nothing is sent until the first valid frame. */
  start(lights: unknown, sourceName: string): { token: string; generation: number } {
    if (this.active) throw new LumaError('Screen Sync is already active. Stop it first.', 409);
    if (this.host.sceneRunning()) throw new LumaError('A scene is running. Stop it before starting Screen Sync.', 409);
    if (!Array.isArray(lights) || lights.length === 0) throw new LumaError('Choose at least one light.');
    if (lights.length > MAX_LIGHTS) throw new LumaError(`Choose up to ${MAX_LIGHTS} lights.`);
    const devices = this.host.devices();
    const members = new Map<string, Member>();
    for (const item of lights) {
      const id = (item as { id?: unknown } | null)?.id, region = (item as { region?: unknown } | null)?.region;
      if (typeof id !== 'string' || members.has(id) || !REGIONS.includes(region as SyncRegion)) throw new LumaError('Invalid light selection.');
      const d = devices.find((x) => x.id === id);
      if (!d) throw new LumaError('Light not found.', 404);
      const reason = this.ineligible(d);
      if (reason) throw new LumaError(`${d.name}: ${reason}`, 409);
      members.set(id, { id, name: d.name, region: region as SyncRegion, original: { brightness: d.brightness, rgb: d.rgb, colorTemperature: d.colorTemperature }, excluded: false });
    }
    this.generation++;
    this.token = randomBytes(16).toString('hex');
    this.members = members;
    this.sourceName = sourceName.slice(0, 120);
    this.lastSeq = -1;
    this.lastFrameAt = 0;
    this.lastStop = undefined;
    this.stats = { frames: 0, dropped: 0 };
    this.sender = new StreamSender((id, field, value) => this.host.streamWrite(id, field, value), {
      now: this.now,
      schedule: this.schedule,
      onFatal: () => { void this.stop('Lights stopped accepting LAN updates.'); },
    });
    this.sender.setRate(this.settings.updateHz);
    this.phase = 'starting';
    this.arm(this.options.startMs ?? 15_000, 'Capture did not start.');
    this.host.log(`Screen Sync started for ${members.size} light${members.size === 1 ? '' : 's'}.`);
    this.host.changed();
    return { token: this.token, generation: this.generation };
  }

  /** The renderer's token belongs to the live session. */
  ownsToken(token: unknown): boolean { return !!this.token && token === this.token; }

  /** The current session is still waiting for its capture (used by the capture adapter). */
  awaitingCapture(generation: number): boolean { return this.phase === 'starting' && generation === this.generation; }

  /** One sampled frame. Returns false when stale, malformed, too fast or not running. */
  frame(token: unknown, generation: unknown, seq: unknown, input: unknown): boolean {
    if (!this.token || token !== this.token || generation !== this.generation) return false;
    if (this.phase !== 'running' && this.phase !== 'starting') return false;
    const now = this.now();
    if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq <= this.lastSeq || now - this.lastFrameAt < MIN_FRAME_MS) { this.stats.dropped++; return false; }
    let grid;
    try { grid = validateGrid(input); } catch { this.stats.dropped++; return false; }
    const dtS = this.lastFrameAt ? (now - this.lastFrameAt) / 1000 : undefined;
    this.lastSeq = seq;
    this.lastFrameAt = now;
    this.stats.frames++;
    if (this.phase === 'starting') { this.phase = 'running'; this.lastEmit = 0; }
    this.arm(this.options.stallMs ?? 10_000, 'No frames arrived; capture stalled.');
    for (const m of this.members.values()) {
      if (m.excluded) continue;
      // Region colors use the current settings, so depth and vivid apply from the next frame.
      const sample = gridColor(grid, m.region, this.settings.edgeDepth, this.settings.vivid);
      m.smoothed = smooth(m.smoothed, sample, this.settings.smoothing, dtS);
      const target = toTarget(m.smoothed, this.settings.brightnessCap);
      if (!exceedsThreshold(m.target, target, this.settings.threshold)) continue;
      m.target = target;
      this.sender?.push(m.id, target);
    }
    if (now - this.lastEmit >= 1000) { this.lastEmit = now; this.host.changed(); } // stats at most 1 Hz
    return true;
  }

  pause(): void {
    if (this.phase !== 'running' && this.phase !== 'starting') return;
    this.phase = 'paused';
    this.disarm();
    for (const m of this.members.values()) { m.smoothed = undefined; m.target = undefined; void this.sender?.remove(m.id); }
    this.host.log('Screen Sync paused.');
    this.host.changed();
  }

  resume(token: unknown): void {
    if (this.phase !== 'paused' || token !== this.token) throw new LumaError('Screen Sync is not paused.', 409);
    this.phase = 'running';
    this.lastFrameAt = 0;
    this.arm(this.options.stallMs ?? 10_000, 'No frames arrived; capture stalled.');
    this.host.log('Screen Sync resumed.');
    this.host.changed();
  }

  setSettings(input: unknown): void {
    const previousCap = this.settings.brightnessCap;
    this.settings = validateSettings(input, this.settings);
    this.sender?.setRate(this.settings.updateHz);
    const cap = Math.max(1, Math.round(this.settings.brightnessCap));
    if (this.settings.brightnessCap !== previousCap) {
      // An explicit cap change is never swallowed by the change threshold: anything above a
      // lowered cap is clamped and sent now; the next frame then recomputes from scratch.
      for (const m of this.members.values()) {
        if (m.excluded || !m.target) continue;
        if (m.target.brightness > cap) this.sender?.push(m.id, { ...m.target, brightness: cap });
        m.target = undefined;
      }
    }
    this.host.changed();
  }

  /**
   * Manual control takes a light out of the stream: its pending target is dropped and
   * this resolves after its in-flight datagram settles, so the manual write is ordered
   * after every stream write. Excluded lights are never restored.
   */
  async exclude(deviceID: string): Promise<void> {
    const m = this.members.get(deviceID);
    if (!m) return;
    if (!m.excluded) {
      m.excluded = true;
      this.host.log(`${m.name} left Screen Sync for manual control.`);
      this.host.changed();
    }
    // Every manual write waits for the same barrier, including a second rapid one.
    // While stopping, the session drain (and any restore submission) is the barrier.
    await (this.stopping ?? this.sender?.remove(deviceID));
    if ([...this.members.values()].every((x) => x.excluded) && (this.phase === 'running' || this.phase === 'starting' || this.phase === 'paused')) {
      // Not awaited: this light is already drained, and awaiting here would let a later manual write overtake this one.
      void this.stop('Every light was taken over manually.');
    }
  }

  /**
   * Stops safely: (1) new generation, so late frames are rejected; (2) discard pending
   * targets and wait (bounded) for in-flight sends; (3) only for an explicit user Stop
   * with "restore" chosen, submit last confirmed values through the engine, LAN only.
   */
  stop(reason: string, explicit = false): Promise<void> {
    if (this.stopping) return this.stopping;
    if (!this.active) return Promise.resolve();
    this.generation++;
    this.token = undefined;
    this.phase = 'stopping';
    this.disarm();
    this.host.changed();
    const sender = this.sender;
    this.sender = undefined;
    const restore = explicit && this.settings.restore;
    this.stopping = (async () => {
      if (sender) {
        let timer: (() => void) | undefined;
        await Promise.race([sender.stop(), new Promise<void>((r) => { timer = this.schedule(r, this.options.drainMs ?? 2000); })]);
        timer?.();
      }
      if (restore) await this.restoreAll();
      this.phase = 'idle';
      this.lastStop = reason;
      this.stopping = undefined;
      this.host.log(`Screen Sync stopped. ${reason}`);
      this.host.changed();
    })();
    return this.stopping;
  }

  private async restoreAll(): Promise<void> {
    const devices = this.host.devices();
    await Promise.all([...this.members.values()].filter((m) => !m.excluded).map(async (m) => {
      const d = devices.find((x) => x.id === m.id);
      const { commands, skipped } = restoreCommands(m.original);
      if (skipped) this.host.log(`${m.name}: ${skipped}`);
      if (!d || commands.length === 0) return;
      try { await this.host.restore(m.id, commands); }
      catch (error) { this.host.log(`${m.name} was not restored: ${message(error)}`, true); }
    }));
  }

  view(): SyncView {
    const sent = this.sender?.stats ?? { sent: 0, errors: 0, superseded: 0 };
    return {
      phase: this.phase,
      generation: this.generation,
      sourceName: this.active ? this.sourceName : undefined,
      synthetic: this.options.demo,
      captureSupported: this.options.captureSupported,
      lights: [...this.members.values()].map((m) => ({
        id: m.id, name: m.name, region: m.region, status: m.excluded ? 'excluded' as const : 'streaming' as const,
        ...(m.target && !m.excluded ? { requestedRGB: m.target.rgb, requestedBrightness: m.target.brightness } : {}),
      })),
      eligibility: this.eligibility(),
      settings: { ...this.settings },
      stats: { ...this.stats, ...sent },
      lastStop: this.lastStop,
    };
  }

  private arm(ms: number, reason: string): void {
    this.disarm();
    const generation = this.generation;
    this.watchdog = this.schedule(() => { if (generation === this.generation) void this.stop(reason); }, ms);
  }

  private disarm(): void { this.watchdog?.(); this.watchdog = undefined; }
}

/** Finite, ordered restore: brightness, then the previous color mode. Power is never changed (only lights that were on can stream). */
export function restoreCommands(original: Member['original']): { commands: CapabilityCommand[]; skipped?: string } {
  const commands: CapabilityCommand[] = [];
  let skipped: string | undefined;
  if (original.brightness !== undefined && original.brightness >= 1) commands.push(brightness(original.brightness));
  const k = original.colorTemperature;
  if (k !== undefined && k > 0) {
    if (k >= 2000 && k <= 9000) commands.push(kelvin(k));
    else skipped = 'its previous white temperature cannot be set over LAN, so color was left as is.';
  } else if (original.rgb !== undefined) commands.push(rgb(original.rgb));
  return { commands, skipped };
}

/** Explicit-request source list with expiring keys, plus a single-use, short-lived capture grant. */
export class CaptureGrants {
  private offered = new Map<string, { source: SyncSource & { id: string }; expires: number }>();
  private grant?: { source: { id: string; name: string }; generation: number; expires: number };
  private epoch = 0;
  private readonly now: () => number;

  constructor(private readonly enumerate: () => Promise<Array<{ id: string; name: string; kind: 'screen' | 'window' }>>, options: { now?: () => number; listMs?: number; grantMs?: number; revalidate?: boolean } = {}) {
    this.now = options.now ?? Date.now;
    this.revalidate = options.revalidate ?? true;
    this.listMs = options.listMs ?? 120_000;
    this.grantMs = options.grantMs ?? 10_000;
  }
  private readonly listMs: number;
  /** False where enumeration is itself the OS picker (Linux Wayland portal): the fresh list was the user's choice. */
  private readonly revalidate: boolean;
  private readonly grantMs: number;

  /** Enumerates only when the user asks; keys are opaque and replace any earlier list. */
  async list(): Promise<SyncSource[]> {
    const epoch = this.begin();
    const sources = (await this.enumerate()).slice(0, 64);
    this.current(epoch);
    const expires = this.now() + this.listMs;
    return sources.map((s) => {
      const key = randomBytes(12).toString('hex');
      const entry = { key, id: s.id, name: (s.name || (s.kind === 'screen' ? 'Screen' : 'Window')).slice(0, 120), kind: s.kind };
      this.offered.set(key, { source: entry, expires });
      return { key, name: entry.name, kind: entry.kind };
    });
  }

  /** Re-enumerates and requires the chosen source to still exist. The list is consumed. */
  async resolve(key: unknown): Promise<{ id: string; name: string; epoch: number }> {
    const offer = typeof key === 'string' ? this.offered.get(key) : undefined;
    const epoch = this.begin();
    if (!offer || offer.expires < this.now()) throw new LumaError('Choose the screen or window again.');
    if (!this.revalidate) return { id: offer.source.id, name: offer.source.name, epoch };
    const fresh = await this.enumerate();
    this.current(epoch);
    const match = fresh.find((s) => s.id === offer.source.id);
    if (!match) throw new LumaError('That screen or window is no longer available.');
    return { id: match.id, name: offer.source.name, epoch };
  }

  /** Throws unless nothing (revoke, a new list or resolve) superseded the work that started at `epoch`. */
  current(epoch: number): void {
    if (epoch !== this.epoch) throw new LumaError('Source selection was cancelled. Choose the screen or window again.', 409);
  }

  /** Grants only for a resolve that is still current; nothing is issued after a revocation. */
  issue(source: { id: string; name: string; epoch: number }, generation: number): void {
    this.current(source.epoch);
    this.grant = { source: { id: source.id, name: source.name }, generation, expires: this.now() + this.grantMs };
  }

  /** Single use: always clears the grant. */
  consume(generation: number): { id: string; name: string } | undefined {
    const g = this.grant;
    this.grant = undefined;
    if (!g || g.generation !== generation || g.expires < this.now()) return undefined;
    return g.source;
  }

  revoke(): void { this.begin(); this.grant = undefined; }

  /** New epoch: every earlier offer, pending list and pending resolve becomes unusable. */
  private begin(): number { this.offered.clear(); return ++this.epoch; }
}

/**
 * The renderer document was replaced (reload, main-frame navigation) or lost (crash, hang,
 * destroyed). Its frame pump and token are gone, so any session, paused or running, must stop
 * (never restore, never resume). `lost` must be idempotent.
 */
export function stopOnRendererLoss(contents: Pick<NodeJS.EventEmitter, 'on'>, lost: () => void): void {
  contents.on('did-start-navigation', (details: { isMainFrame?: boolean; isSameDocument?: boolean } | undefined) => {
    if (details?.isMainFrame && !details.isSameDocument) lost();
  });
  for (const event of ['render-process-gone', 'unresponsive', 'destroyed']) contents.on(event, () => lost());
}

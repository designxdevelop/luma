// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Latest-only stream sender for Screen Sync. Separate from ControlEngine on purpose:
// stream values are never confirmed, never read back, never persisted, never sent by
// cloud. Each light holds only its newest target; at most one send is in flight per
// light, and sends are spaced by the per-light rate cap. remove()/stop() discard the
// pending target and resolve once the in-flight send settles (a UDP datagram already
// handed to the OS cannot be recalled).

import { DEFAULT_SYNC_SETTINGS, SYNC_LIMITS, type LightTarget } from '../shared/sync-math';

export type StreamField = 'colorRgb' | 'brightness';
export type StreamWrite = (deviceID: string, field: StreamField, value: number) => Promise<void>;

export interface StreamOptions {
  now?: () => number;
  schedule?: (fn: () => void, ms: number) => () => void;
  /** Consecutive failed sends to one light before `onFatal`. */
  maxErrors?: number;
  onFatal?: (deviceID: string, error: unknown) => void;
}

interface Lane {
  id: string;
  latest?: LightTarget;
  sent: Partial<Record<StreamField, number>>;
  inflight?: Promise<void>;
  nextAt: number;
  cancel?: () => void;
  preferBrightness: boolean;
  errors: number;
  removed: boolean;
  /** A brightness write failed; this light is done for the session. */
  failed?: boolean;
}

const defaultSchedule = (fn: () => void, ms: number) => { const t = setTimeout(fn, ms); return () => clearTimeout(t); };

export class StreamSender {
  readonly stats = { sent: 0, errors: 0, superseded: 0 };
  private readonly lanes = new Map<string, Lane>();
  private intervalMs = 1000 / DEFAULT_SYNC_SETTINGS.updateHz;
  private stopped = false;
  private readonly now: () => number;
  private readonly schedule: NonNullable<StreamOptions['schedule']>;

  constructor(private readonly write: StreamWrite, private readonly options: StreamOptions = {}) {
    this.now = options.now ?? Date.now;
    this.schedule = options.schedule ?? defaultSchedule;
  }

  /** Per-light packet rate cap, clamped to SYNC_LIMITS.updateHz. */
  setRate(hz: number): void {
    if (!Number.isFinite(hz)) return;
    this.intervalMs = 1000 / Math.max(SYNC_LIMITS.updateHz[0], Math.min(SYNC_LIMITS.updateHz[1], hz));
  }

  /** Replaces the light's pending target (latest only). */
  push(deviceID: string, target: LightTarget): void {
    if (this.stopped || this.lanes.get(deviceID)?.failed) return;
    let lane = this.lanes.get(deviceID);
    if (!lane) { lane = { id: deviceID, sent: {}, nextAt: 0, preferBrightness: false, errors: 0, removed: false }; this.lanes.set(deviceID, lane); }
    lane.removed = false; // re-added after a pause; a send still in flight keeps the slot
    if (lane.latest && this.pick(lane)) this.stats.superseded++;
    lane.latest = target;
    this.pump(lane);
  }

  /** Drops the light's pending target; resolves after its in-flight send settles. */
  remove(deviceID: string): Promise<void> {
    const lane = this.lanes.get(deviceID);
    if (!lane) return Promise.resolve();
    lane.removed = true;
    lane.latest = undefined;
    lane.cancel?.();
    lane.cancel = undefined;
    // A lane with a send in flight stays known until it settles, so a second remove() is still a barrier.
    if (!lane.inflight) this.lanes.delete(deviceID);
    return lane.inflight ?? Promise.resolve();
  }

  /** Discards all pending targets; resolves after every in-flight send settles. Final. */
  stop(): Promise<void> {
    this.stopped = true;
    return Promise.all([...this.lanes.keys()].map((id) => this.remove(id))).then(() => undefined);
  }

  get inflight(): number { let n = 0; for (const l of this.lanes.values()) if (l.inflight) n++; return n; }

  private pick(lane: Lane): StreamField | undefined {
    const t = lane.latest;
    if (!t) return undefined;
    const color = lane.sent.colorRgb !== t.rgb, bright = lane.sent.brightness !== t.brightness;
    // Dimming (or an unknown starting brightness) goes first, so a full-scale color never flashes above the cap.
    if (bright && (lane.sent.brightness === undefined || t.brightness < lane.sent.brightness)) return 'brightness';
    if (color && bright) return lane.preferBrightness ? 'brightness' : 'colorRgb';
    return color ? 'colorRgb' : bright ? 'brightness' : undefined;
  }

  private pump(lane: Lane): void {
    if (this.stopped || lane.removed || lane.failed || lane.inflight) return;
    const field = this.pick(lane);
    if (!field) return;
    const wait = lane.nextAt - this.now();
    if (wait > 0) {
      lane.cancel ??= this.schedule(() => { lane.cancel = undefined; this.pump(lane); }, wait);
      return;
    }
    const value = field === 'colorRgb' ? lane.latest!.rgb : lane.latest!.brightness;
    lane.nextAt = this.now() + this.intervalMs;
    lane.preferBrightness = field === 'colorRgb'; // alternate when both changed
    lane.sent[field] = value; // never resent automatically; a newer frame supersedes it
    lane.inflight = this.write(lane.id, field, value).then(
      () => { lane.errors = 0; this.stats.sent++; },
      (error: unknown) => {
        this.stats.errors++;
        if (field === 'brightness') {
          // A known failed brightness write means the cap is not enforced: this light gets
          // nothing more (no retry, no color) and the failure is fatal immediately.
          lane.failed = true;
          lane.latest = undefined;
          lane.cancel?.();
          lane.cancel = undefined;
          if (!lane.removed) this.options.onFatal?.(lane.id, error);
          return;
        }
        if (++lane.errors === (this.options.maxErrors ?? 5) && !lane.removed) this.options.onFatal?.(lane.id, error);
      },
    ).finally(() => {
      lane.inflight = undefined;
      if (lane.removed) { if (this.lanes.get(lane.id) === lane) this.lanes.delete(lane.id); return; }
      this.pump(lane);
    });
  }
}

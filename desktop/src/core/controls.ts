// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Latest-intent control engine. Requested values live in a display overlay that is
// separate from confirmed (reported) state, so an optimistic edit is never persisted
// or returned by the webhook API. Writes run in order per device; only adjacent
// unsent writes to the same control coalesce, so nothing moves across another control.

import { randomUUID } from 'node:crypto';
import type { CapabilityCommand, ControlPhase, JSONValue, LightDevice, PendingView } from '../shared/types';
import { LAN_INSTANCES, LumaError, capability, jsonEqual, message, validateCommand } from './model';

type Reported = Pick<LightDevice, 'power' | 'brightness' | 'rgb' | 'colorTemperature' | 'online' | 'lastSeen'>;

export interface ControlTransport {
  /** Performs one write. `confirmed: true` means the write is known applied (demo). Never retried. */
  send(device: LightDevice, command: CapabilityCommand, signal: AbortSignal): Promise<{ route: string; confirmed?: boolean }>;
  /** Reads state. Returns fields read, or undefined when the reply arrives later via report() (LAN).
   *  `command` is the write being confirmed, so the read can use the route that carried it. */
  read(device: LightDevice, command?: CapabilityCommand): Promise<Partial<Reported> | undefined>;
}

export interface ControlDeps {
  device(id: string): LightDevice | undefined;
  /** Mutates the confirmed record in place; the caller persists. */
  update(id: string, mutate: (device: LightDevice) => void): void;
  changed(): void;
  log(message: string, isError?: boolean): void;
  transport: ControlTransport;
}

export interface ControlOptions {
  /** Delays between bounded confirmation reads after a write. */
  confirmDelays?: number[];
  /** An unconfirmed request expires and rolls back after this long. */
  expireMs?: number;
  /** After a LAN confirmation, ignore contradicting unversioned status for this long. */
  settleMs?: number;
  now?: () => number;
}

interface Op {
  id: string;
  deviceID: string;
  command: CapabilityCommand;
  coalesce: boolean;
  signal?: AbortSignal;
  resolve(): void;
  reject(error: unknown): void;
}

interface Pending { opID: string; command: CapabilityCommand; phase: ControlPhase; timer?: NodeJS.Timeout; expiry?: NodeJS.Timeout; }

const key = (deviceID: string, instance: string) => `${deviceID}\u0000${instance}`;
const isBasic = (instance: string) => (LAN_INSTANCES as readonly string[]).includes(instance);

export function reportedValue(device: Reported, instance: string): JSONValue | undefined {
  switch (instance) {
    case 'powerSwitch': return device.power === undefined ? undefined : device.power ? 1 : 0;
    case 'brightness': return device.brightness;
    case 'colorRgb': return device.rgb;
    case 'colorTemperatureK': return device.colorTemperature;
    default: return undefined;
  }
}

/** Applies a basic command's value to a device record (display overlay or demo confirmation). */
export function applyCommand(device: LightDevice, command: CapabilityCommand): void {
  if (typeof command.value !== 'number') return;
  const n = command.value;
  switch (command.instance) {
    case 'powerSwitch': device.power = n === 1; break;
    case 'brightness': device.brightness = n; break;
    case 'colorRgb': device.rgb = n; device.colorTemperature = 0; break;
    case 'colorTemperatureK': device.colorTemperature = n; break;
  }
}

function clearField(state: Partial<Reported>, instance: string): void {
  switch (instance) {
    case 'powerSwitch': delete state.power; break;
    case 'brightness': delete state.brightness; break;
    case 'colorRgb': delete state.rgb; break;
    case 'colorTemperatureK': delete state.colorTemperature; break;
  }
}

export class ControlEngine {
  private readonly pending = new Map<string, Pending>();
  private readonly queues = new Map<string, Op[]>();
  private readonly inFlight = new Map<string, Op>();
  private readonly workers = new Set<string>();
  private readonly revisions = new Map<string, number>();
  private readonly settled = new Map<string, { value: JSONValue; until: number }>();
  private readonly confirmDelays: number[];
  private readonly expireMs: number;
  private readonly settleMs: number;
  private readonly now: () => number;
  private stopped = false;

  constructor(private readonly deps: ControlDeps, options: ControlOptions = {}) {
    this.confirmDelays = options.confirmDelays ?? [2000, 4000, 8000];
    this.expireMs = options.expireMs ?? 30_000;
    this.settleMs = options.settleMs ?? 2000;
    this.now = options.now ?? Date.now;
  }

  revision(deviceID: string): number { return this.revisions.get(deviceID) ?? 0; }

  /** Validates, shows the intent immediately, and queues the write. Resolves when the write was submitted. */
  submit(deviceID: string, command: CapabilityCommand, options: { coalesce?: boolean; signal?: AbortSignal } = {}): Promise<void> {
    const device = this.deps.device(deviceID);
    if (!device) return Promise.reject(new LumaError('Light not found.', 404));
    try { validateCommand(command, device); } catch (error) { return Promise.reject(error); }
    if (options.signal?.aborted) return Promise.reject(abortError());
    this.stopped = false;
    return new Promise<void>((resolve, reject) => {
      const op: Op = { id: randomUUID(), deviceID, command, coalesce: options.coalesce ?? false, signal: options.signal, resolve, reject };
      this.revisions.set(deviceID, this.revision(deviceID) + 1);
      this.setPending(op, 'queued');
      if (isBasic(command.instance) && (command.instance === 'colorRgb' || command.instance === 'colorTemperatureK')) {
        // The opposite color mode is superseded: drop its pending intent and its settle guard,
        // or the guard would strip the new mode's report (e.g. Kelvin 0 after RGB).
        const opposite = key(deviceID, command.instance === 'colorRgb' ? 'colorTemperatureK' : 'colorRgb');
        this.clearPending(opposite);
        this.settled.delete(opposite);
      }
      this.settled.delete(key(deviceID, command.instance));
      const queue = this.queues.get(deviceID) ?? [];
      const tail = queue.at(-1);
      if (op.coalesce && tail?.coalesce && tail.command.instance === command.instance) {
        // Collapse only an adjacent unsent write to the same control: order is preserved.
        queue.pop();
        tail.resolve();
      }
      queue.push(op);
      this.queues.set(deviceID, queue);
      op.signal?.addEventListener('abort', () => this.cancelQueued(op), { once: true });
      this.deps.changed();
      void this.work(deviceID);
    });
  }

  /** Telemetry. `revision` (cloud reads) must match the current revision or the reply is stale and dropped. */
  report(deviceID: string, incoming: Partial<Reported>, source: { revision?: number; lan?: boolean } = {}): void {
    const device = this.deps.device(deviceID);
    if (!device) return;
    if (source.revision !== undefined && source.revision !== this.revision(deviceID)) return;
    const state = { ...incoming };
    const now = this.now();
    // Unversioned LAN status can arrive late. Right after a confirmation, a
    // contradicting value is treated as an older packet rather than a change.
    for (const instance of LAN_INSTANCES) {
      const k = key(deviceID, instance);
      const settle = this.settled.get(k);
      if (!settle) continue;
      if (settle.until <= now) { this.settled.delete(k); continue; }
      const value = reportedValue(state, instance);
      if (value !== undefined && !jsonEqual(value, settle.value)) clearField(state, instance);
    }
    this.deps.update(deviceID, (d) => {
      if (state.online !== undefined) d.online = state.online;
      if (state.lastSeen !== undefined) d.lastSeen = state.lastSeen;
      if (state.online === false) return; // historical values are not live telemetry
      if (state.power !== undefined) d.power = state.power;
      if (state.brightness !== undefined) d.brightness = state.brightness;
      if (state.rgb !== undefined) d.rgb = state.rgb;
      if (state.colorTemperature !== undefined) d.colorTemperature = state.colorTemperature;
    });
    if (state.online !== false) {
      for (const instance of LAN_INSTANCES) {
        const k = key(deviceID, instance);
        const p = this.pending.get(k);
        if (p?.phase !== 'confirming') continue;
        // Only fields present in this report can confirm a write. Cached values may
        // happen to match, including the remembered RGB while a light is in white mode.
        const rgbModeConfirmed = instance !== 'colorRgb' || state.colorTemperature === 0 ||
          (state.colorTemperature === undefined && device.colorTemperature === undefined && !device.ip && !capability(device, 'colorTemperatureK'));
        if (rgbModeConfirmed && jsonEqual(reportedValue(state, instance), p.command.value)) {
          this.clearPending(k);
          if (source.lan) this.settled.set(k, { value: p.command.value, until: now + this.settleMs });
          if (instance === 'colorRgb') {
            // Guard only an explicitly reported color mode; never manufacture telemetry.
            if (source.lan && state.colorTemperature === 0) this.settled.set(key(deviceID, 'colorTemperatureK'), { value: 0, until: now + this.settleMs });
          }
        }
      }
    }
    this.deps.changed();
  }

  /** Reported device with requested values overlaid, for display only. */
  overlay(device: LightDevice): LightDevice {
    const shown: LightDevice = { ...device };
    for (const p of this.pendingFor(device.id)) applyCommand(shown, { type: '', instance: p.instance, value: p.value });
    return shown;
  }

  pendingFor(deviceID: string): PendingView[] {
    const views: PendingView[] = [];
    for (const [k, p] of this.pending) if (k.startsWith(deviceID + '\u0000')) views.push({ instance: p.command.instance, value: p.command.value, phase: p.phase });
    return views;
  }

  /** Drops all queued work and overlays (leaving demo, shutdown). In-flight writes may still complete. */
  stop(): void {
    this.stopped = true;
    for (const queue of this.queues.values()) for (const op of queue) op.reject(abortError());
    this.queues.clear();
    for (const k of [...this.pending.keys()]) this.clearPending(k);
    this.settled.clear();
    this.deps.changed();
  }

  private async work(deviceID: string): Promise<void> {
    if (this.workers.has(deviceID)) return;
    this.workers.add(deviceID);
    try {
      for (let op = this.queues.get(deviceID)?.shift(); op && !this.stopped; op = this.queues.get(deviceID)?.shift()) {
        this.inFlight.set(deviceID, op);
        await this.transmit(op);
        this.inFlight.delete(deviceID);
      }
    } finally {
      this.workers.delete(deviceID);
      this.inFlight.delete(deviceID);
    }
  }

  private async transmit(op: Op): Promise<void> {
    const k = key(op.deviceID, op.command.instance);
    const device = this.deps.device(op.deviceID);
    if (!device) { this.fail(op, new LumaError('Light not found.', 404)); return; }
    if (this.pending.get(k)?.opID === op.id) this.pending.get(k)!.phase = 'sending';
    this.deps.changed();
    let result: { route: string; confirmed?: boolean };
    try {
      result = await this.deps.transport.send(device, op.command, op.signal ?? new AbortController().signal);
    } catch (error) {
      this.fail(op, error);
      return;
    }
    op.resolve();
    this.deps.log(`${device.name}: ${op.command.instance} · ${result.route}`);
    if (result.confirmed) {
      this.deps.update(op.deviceID, (d) => applyCommand(d, op.command));
      if (this.pending.get(k)?.opID === op.id) this.clearPending(k);
      this.deps.changed();
      return;
    }
    this.confirm(op);
  }

  /** Bounded confirmation reads, yielding to queued writes; expires to the last reported value. */
  private confirm(op: Op): void {
    const k = key(op.deviceID, op.command.instance);
    const p = this.pending.get(k);
    if (p?.opID !== op.id) return;
    if (!isBasic(op.command.instance)) { this.clearPending(k); this.deps.changed(); return; } // accepted; no readable state
    p.phase = 'confirming';
    // The deadline is independent of reads: a read stuck in the paced cloud queue cannot extend it.
    p.expiry = setTimeout(() => {
      if (this.pending.get(k)?.opID !== op.id) return;
      this.fail(op, new LumaError(`Could not confirm ${op.command.instance} for this light. Showing its last reported state; use Refresh to check it.`));
    }, this.expireMs);
    const delays = [...this.confirmDelays];
    const step = () => {
      const current = this.pending.get(k);
      const delay = delays.shift();
      if (current?.opID !== op.id || delay === undefined) return;
      current.timer = setTimeout(async () => {
        if (this.pending.get(k)?.opID !== op.id) return;
        const device = this.deps.device(op.deviceID);
        if (device && !this.workers.has(op.deviceID)) {
          const revision = this.revision(op.deviceID);
          try {
            const state = await this.deps.transport.read(device, op.command);
            // Discard replies that land after expiry or after a newer intent.
            if (state && this.pending.get(k)?.opID === op.id) this.report(op.deviceID, state, { revision });
          } catch (error) {
            this.deps.log(`State confirmation unavailable: ${message(error)}`);
          }
        }
        step();
      }, delay);
    };
    step();
    this.deps.changed();
  }

  private cancelQueued(op: Op): void {
    const queue = this.queues.get(op.deviceID);
    const index = queue?.indexOf(op) ?? -1;
    if (!queue || index < 0) return; // already sent: cancellation does not undo it
    queue.splice(index, 1);
    const k = key(op.deviceID, op.command.instance);
    if (this.pending.get(k)?.opID === op.id) {
      this.clearPending(k);
      // A cancelled step no longer supersedes an earlier in-flight write to the same control.
      const previous = this.inFlight.get(op.deviceID);
      if (previous && previous.command.instance === op.command.instance) this.setPending(previous, 'sending');
    }
    op.reject(abortError());
    this.deps.changed();
  }

  private fail(op: Op, error: unknown): void {
    const k = key(op.deviceID, op.command.instance);
    const text = message(error);
    if (this.pending.get(k)?.opID === op.id) {
      // Only the latest intent rolls back; the display returns to the last reported value.
      this.clearPending(k);
      this.deps.log(text, true);
    } else {
      this.deps.log(text);
    }
    op.reject(error);
    this.deps.changed();
  }

  private setPending(op: Op, phase: ControlPhase): void {
    const k = key(op.deviceID, op.command.instance);
    this.clearPending(k);
    this.pending.set(k, { opID: op.id, command: op.command, phase });
  }

  private clearPending(k: string): void {
    const p = this.pending.get(k);
    if (p?.timer) clearTimeout(p.timer);
    if (p?.expiry) clearTimeout(p.expiry);
    this.pending.delete(k);
  }
}

function abortError(): Error {
  const error = new Error('The operation was cancelled.');
  error.name = 'AbortError';
  return error;
}

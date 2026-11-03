// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// The app side of the doorbell alert: settings file, light I/O for the engine, the outbound
// Alexa relay poll, and the /v1/alerts/doorbell webhook routes. Home passes in narrow hooks.

import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import type { CapabilityCommand, DoorbellView, LightDevice } from '../shared/types';
import { LumaError, message } from '../core/model';
import { DoorbellEngine, RelayClient, decodeDoorbell, defaultDoorbell, restoreCommands, snapshotMatches, snapshotOf, realClock, type AlertClock, type Candidate, type DoorbellConfig, type Outcome, type RelayEvent } from '../core/doorbell';
import type { HttpResponse } from '../core/http';
import type { SecretStore } from './storage';

const RELAY_TOKEN = 'alexa-relay-token';

export interface DoorbellDeps {
  demo: boolean;
  /** Folder for doorbell-alert.json; undefined in demo (nothing is saved). */
  folder?: string;
  secrets?: SecretStore;
  lights(): LightDevice[];
  device(id: string): LightDevice | undefined;
  /** True when writes to this light go over a live LAN session (same rule as alertWrite). */
  lanReady(device: LightDevice): boolean;
  /** Why a light can't be alerted right now (Screen Sync, DreamView, a pending write), or undefined. */
  busy(id: string): string | undefined;
  /** Fresh state read; resolves true once a new report has arrived. */
  read(device: LightDevice): Promise<boolean>;
  /** One direct write: no queue, no confirmation overlay, never retried. */
  write(id: string, command: CapabilityCommand): Promise<void>;
  log(text: string, isError?: boolean): void;
  changed(): void;
  clock?: AlertClock;
  fetch?: ConstructorParameters<typeof RelayClient>[2];
}

export class DoorbellController {
  readonly engine: DoorbellEngine;
  private relayState = 'Off';
  private pairing?: { code: string; expiresAt: number };
  private relay?: AbortController;

  constructor(private readonly deps: DoorbellDeps) {
    this.engine = new DoorbellEngine({
      devices: () => deps.lights(),
      prepare: (targets) => this.prepare(targets),
      pulse: (id, command) => deps.write(id, command),
      restore: (id, snapshot) => this.restore(id, snapshot),
      log: (text, isError) => deps.log(text, isError),
      changed: () => deps.changed(),
    }, deps.clock ?? realClock);
    this.engine.config = this.load();
    this.startRelay();
  }

  private get file(): string | undefined { return this.deps.folder ? join(this.deps.folder, 'doorbell-alert.json') : undefined; }

  private load(): DoorbellConfig {
    if (this.deps.demo) return { ...defaultDoorbell(), enabled: true, rooms: ['Living room'] };
    try { return this.file && existsSync(this.file) ? decodeDoorbell(JSON.parse(readFileSync(this.file, 'utf8'))) : defaultDoorbell(); }
    catch { this.deps.log('Doorbell alert settings could not be read; using defaults. The file was left untouched.', true); return defaultDoorbell(); }
  }

  private relayToken(): string | undefined {
    if (this.deps.demo || !this.deps.secrets?.available) return undefined;
    try { return this.deps.secrets.read(RELAY_TOKEN); } catch { return undefined; }
  }

  view(): DoorbellView {
    return { config: this.engine.config, phase: this.engine.phase, status: this.engine.status, relayState: this.relayState, relayTokenSaved: this.relayToken() !== undefined, pairing: this.pairing };
  }

  /** The renderer's single IPC entry point. Every argument is untrusted. */
  async command(action: unknown, arg?: unknown, arg2?: unknown): Promise<void> {
    switch (action) {
      case 'update': return this.update(arg);
      case 'test': this.trigger(`test-${randomUUID()}`); return;
      case 'stop': this.engine.stop(); return;
      case 'saveRelay': return this.saveRelay(arg, arg2);
      case 'forgetRelay': this.deps.secrets?.delete(RELAY_TOKEN); this.pairing = undefined; return this.update({ ...this.engine.config, relayURL: undefined });
      case 'pairingCode': this.pairing = await this.client().pairingCode(); this.deps.changed(); return;
      case 'unlink': await this.client().unlink(); this.pairing = undefined; this.deps.log('Alexa account links on your relay were revoked.'); return;
      default: throw new LumaError('Unknown doorbell action.');
    }
  }

  update(value: unknown): void {
    const next = decodeDoorbell(value);
    const relayChanged = next.relayURL !== this.engine.config.relayURL || next.enabled !== this.engine.config.enabled;
    if (this.file && this.deps.folder) {
      mkdirSync(this.deps.folder, { recursive: true, mode: 0o700 });
      const temp = `${this.file}.${randomUUID()}.tmp`;
      try { writeFileSync(temp, JSON.stringify(next, null, 2), { mode: 0o600, flag: 'wx' }); renameSync(temp, this.file); }
      finally { if (existsSync(temp)) unlinkSync(temp); }
    }
    this.engine.config = next;
    if (relayChanged) this.startRelay();
    this.deps.changed();
  }

  trigger(eventID: string): Outcome {
    const outcome = this.engine.trigger(eventID);
    if (outcome !== 'started') this.engine.status = describe(outcome);
    this.deps.changed();
    return outcome;
  }

  yield(id: string): void { this.engine.yield(id); }
  isAlerting(id: string): boolean { return this.engine.isAlerting(id); }

  /** Best effort at quit: owed restores are sent at once (cloud ones get two seconds). */
  async shutdown(): Promise<void> {
    this.relay?.abort();
    const owed = this.engine.takePendingRestores();
    await Promise.race([
      Promise.allSettled(owed.map(async ({ id, snapshot }) => { for (const c of restoreCommands(snapshot)) await this.deps.write(id, c); })),
      new Promise((resolve) => setTimeout(resolve, 2000).unref?.()),
    ]);
  }

  /** Busy lights are skipped, then every target is read fresh: a stale saved state is never restored. */
  private async prepare(targets: LightDevice[]): Promise<Candidate[]> {
    const fresh = await Promise.all(targets.map(async (d) => {
      const busy = this.deps.busy(d.id);
      if (busy) return busy;
      if (d.isDemo) return undefined;
      try { return (await this.deps.read(d)) ? undefined : 'no fresh status from the light'; } catch { return "couldn't read its state"; }
    }));
    return targets.map((target, i) => {
      const d = this.deps.device(target.id) ?? target;
      const route = d.isDemo || this.deps.lanReady(d) ? 'lan' as const : 'cloud' as const;
      if (fresh[i]) return { id: d.id, name: d.name, route, skip: fresh[i] };
      try { return { id: d.id, name: d.name, route, snapshot: snapshotOf(d) }; } catch (error) { return { id: d.id, name: d.name, route, skip: message(error) }; }
    });
  }

  private async restore(id: string, snapshot: ReturnType<typeof snapshotOf>): Promise<boolean> {
    for (const c of restoreCommands(snapshot)) await this.deps.write(id, c);
    const device = this.deps.device(id);
    if (!device) return false;
    if (!device.isDemo && !(await this.deps.read(device).catch(() => false))) return false;
    const now = this.deps.device(id);
    return !!now && snapshotMatches(snapshot, now);
  }

  // ---------- Alexa relay ----------

  private saveRelay(url: unknown, token: unknown): void {
    if (this.deps.demo) throw new LumaError('Leave the demo to connect your Alexa relay.');
    if (!this.deps.secrets?.available) throw new LumaError('Secure storage is unavailable, so the relay token was not saved.');
    const base = typeof url === 'string' ? url.trim() : '', secret = typeof token === 'string' ? token.trim() : '';
    new RelayClient(base, secret); // validates both
    this.deps.secrets.write(RELAY_TOKEN, secret);
    this.update({ ...this.engine.config, relayURL: base });
    this.startRelay();
  }

  private client(): RelayClient {
    const token = this.relayToken();
    if (!this.engine.config.relayURL || !token) throw new LumaError('Connect your Alexa relay first.');
    return new RelayClient(this.engine.config.relayURL, token, this.deps.fetch);
  }

  /** Outbound long poll while the alert is on and a relay is connected. */
  startRelay(): void {
    this.relay?.abort(); this.relay = undefined;
    const { relayURL, enabled } = this.engine.config;
    let client: RelayClient;
    try { client = this.client(); } catch {
      this.relayState = !relayURL ? 'Off' : 'Needs the relay token'; return;
    }
    if (!enabled) { this.relayState = 'Paused: the alert is off'; return; }
    const abort = new AbortController();
    this.relay = abort;
    this.relayState = 'Connecting…';
    void (async () => {
      let backoff = 2000, connected = false;
      while (!abort.signal.aborted) {
        try {
          const events = await client.next(connected, abort.signal);
          connected = true;
          if (this.relayState !== 'Connected · waiting for Alexa') { this.relayState = 'Connected · waiting for Alexa'; this.deps.changed(); }
          backoff = 2000;
          for (const e of events) this.receive(e);
        } catch (error) {
          if (abort.signal.aborted) return;
          connected = false;
          this.relayState = `Reconnecting: ${message(error)}`; this.deps.changed();
          await new Promise((resolve) => setTimeout(resolve, backoff).unref?.());
          backoff = Math.min(backoff * 2, 60_000);
        }
      }
    })();
  }

  receive(event: RelayEvent): void {
    if (event.type === 'deactivate') { this.deps.log('Alexa stopped the doorbell alert.'); this.engine.stop(); return; }
    this.deps.log(`Alexa doorbell scene: ${this.trigger(`alexa:${event.id}`)}.`);
  }

  // ---------- webhook routes (the server checked the bearer token already) ----------

  /** GET status; POST a ring {eventId, timestamp (Unix seconds, ±120 s)}; POST /stop. */
  api(method: string, rest: string[], body: Buffer, now = Date.now()): HttpResponse {
    if (method === 'GET' && rest.length === 0) return { status: 200, body: { enabled: this.engine.config.enabled, phase: this.engine.phase, status: this.engine.status } };
    if (method !== 'POST') return { status: 405, body: { error: 'Method not allowed.' } };
    if (rest.length === 1 && rest[0] === 'stop') { this.engine.stop(); return { status: 202, body: { accepted: true } }; }
    if (rest.length) return { status: 404, body: { error: 'Not found.' } };
    let ring: { eventId?: unknown; timestamp?: unknown } = {};
    try { ring = JSON.parse(body.toString('utf8')); } catch { /* reported below */ }
    if (typeof ring?.eventId !== 'string' || !/^[A-Za-z0-9._:-]{8,128}$/.test(ring.eventId) || typeof ring.timestamp !== 'number') {
      return { status: 400, body: { error: 'Send {"eventId": 8–128 letters, digits or -_.:, "timestamp": Unix seconds}' } };
    }
    if (Math.abs(now / 1000 - ring.timestamp) > 120) return { status: 409, body: { error: "Stale or future timestamp; check the caller's clock." } };
    const outcome = this.trigger(`webhook:${ring.eventId}`);
    this.deps.log(`Doorbell webhook: ${outcome}.`);
    return { status: outcome === 'disabled' ? 409 : 202, body: { outcome, status: this.engine.status } };
  }
}

export function describe(outcome: Outcome): string {
  switch (outcome) {
    case 'started': return 'Ringing…';
    case 'coalesced': return 'Rang again; the running alert continues.';
    case 'cooldown': return 'Rang again during the cooldown; lights left alone.';
    case 'duplicate': return 'Ignored a repeated delivery of the same ring.';
    case 'disabled': return 'Rang, but the doorbell alert is off.';
    case 'quiet': return 'Rang during quiet hours; lights left alone.';
  }
}

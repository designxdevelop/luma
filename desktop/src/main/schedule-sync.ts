// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Schedule sync for Windows/Linux: run shared schedules here ("runner"), or pair with the
// computer that runs them ("paired"). Protocol rules live in core/schedule-sync.ts; this
// file adds storage, the LAN server, the pinned client and the hand-off between runners.
// Secrets (tokens, TLS key) live in the SecretStore only, never in schedule-sync.json.

import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomUUID, X509Certificate } from 'node:crypto';
import { hostname, networkInterfaces } from 'node:os';
import { connect } from 'node:tls';
import { join } from 'node:path';
import type { LightScene, SceneSchedule } from '../shared/types';
import type { ScheduleSyncView } from '../shared/types';
import { generateWebhookIdentity } from '../core/certificate';
import { WebhookServer, type HttpRequest, type HttpResponse } from '../core/http';
import {
  RETIRE_PATH, RUN_GRACE_MS, SYNC_PATH, SYNC_PORT, SYNC_PROTOCOL, SyncError, applyOp, applyResponse, buildBatches, canonicalID,
  certPin, clientView, decodeClientState, decodeHubDoc, formatPairingCode, hubHandle, liveValues, newClientState, newHubDoc, newSyncToken,
  occurrences, parsePairingCode, stage,
  type ClientState, type HubDoc, type PairingCode, type PeerInfo, type Refusal, type RunReport, type SceneWire, type ScheduleWire, type SyncOp, type SyncResponse,
} from '../core/schedule-sync';
import { iconFor, symbolFor } from './backup';
import type { SecretStore } from './storage';

const TOKEN = 'schedule-sync-token';
const TLS = 'schedule-sync-tls';
const CLIENT_TOKEN = 'schedule-sync-client-token';
const RETIRE_TOKEN = 'schedule-sync-retire-token';
const FILE = 'schedule-sync.json';
const CLIENT_INTERVAL_MS = 30_000;
const REQUEST_TIMEOUT_MS = 10_000;

type Role = 'off' | 'runner' | 'paired';
interface ClientInfo {
  host: string; port: number; pin: string; state: ClientState;
  runner?: { id: string; name: string; platform: string; timeZone: string; executing: boolean };
  lastSync?: number; lastError?: string; runs: RunReport[]; moved?: string;
}
interface SavedSync {
  version: 1; role: Role; device: PeerInfo; keepAwake: boolean; port: number;
  runner?: HubDoc; client?: ClientInfo;
  /** A forced take-over whose old runner hasn't confirmed yet; retried until it does. */
  retirePending?: { host: string; port: number; pin: string; name: string };
}

/** One HTTPS request to a pinned runner. The bearer token is written only after the pin matches. */
export type SyncTransport = (target: { host: string; port: number; pin: string; token: string }, path: string, body: unknown) => Promise<{ status: number; body: unknown }>;

export interface ScheduleSyncDeps {
  /** Undefined in demo: sync is off and nothing is stored. */
  folder?: string;
  secrets?: SecretStore;
  platform: string;
  scenes(): LightScene[];
  schedules(): SceneSchedule[];
  /** Replaces the home's scenes and schedules with the shared view. */
  apply(scenes: LightScene[], schedules: SceneSchedule[]): void;
  /** Validates and starts a scene; returns its run ID or throws. */
  run(sceneID: string): string;
  /** True while a scene runs; a due shared schedule then waits for it, up to the run grace. */
  sceneRunning?(): boolean;
  runStatus(runID: string): string | undefined;
  /** Saves home.json now (used before a scheduled run starts). */
  persistHome(): void;
  log(text: string, isError?: boolean): void;
  changed(): void;
  keepAwake?(on: boolean): void;
  transport?: SyncTransport;
  now?: () => Date;
  timeZone?: () => string;
  addresses?: () => string[];
}

const UUIDISH = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fit = (text: string, max: number) => text.replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, max) || 'Scene';

export const sceneToWire = (s: LightScene): SceneWire => ({
  id: s.id.toUpperCase(), name: s.name, symbol: symbolFor(s.icon), icon: s.icon,
  steps: s.steps.map((st) => ({ id: st.id.toUpperCase(), deviceID: st.deviceID, command: st.command, delayMilliseconds: st.delayMilliseconds })),
});
export const sceneFromWire = (w: SceneWire): LightScene => ({
  id: w.id, name: fit(w.name, 80), icon: w.icon && symbolFor(w.icon) !== 'sparkles' ? w.icon : iconFor(w.symbol),
  steps: w.steps.map((st) => ({ ...st })),
});
export const scheduleToWire = (s: SceneSchedule): ScheduleWire => ({
  id: s.id.toUpperCase(), sceneID: s.sceneID.toUpperCase(), hour: s.hour, minute: s.minute, weekdays: [...s.weekdays].sort((a, b) => a - b), enabled: s.enabled,
  ...(s.pausedUntil ? { pausedUntil: s.pausedUntil } : {}),
});
const scheduleFromWire = (w: ScheduleWire, lastRunMinute?: string): SceneSchedule => ({
  id: w.id, sceneID: w.sceneID, hour: w.hour, minute: w.minute, weekdays: w.weekdays, enabled: w.enabled,
  ...(w.pausedUntil ? { pausedUntil: w.pausedUntil } : {}), ...(lastRunMinute ? { lastRunMinute } : {}),
});

/** Gives every scene, step and schedule an uppercase UUID (older Electron scenes may not have one), rewiring schedules. */
export function canonicalize(scenes: LightScene[], schedules: SceneSchedule[]): { scenes: LightScene[]; schedules: SceneSchedule[] } {
  const up = (id: string) => (UUIDISH.test(id) ? id.toUpperCase() : randomUUID().toUpperCase());
  const ids = new Map<string, string>();
  const out = scenes.map((s) => { const id = up(s.id); ids.set(s.id, id); return { ...s, id, steps: s.steps.map((st) => ({ ...st, id: up(st.id) })) }; });
  return { scenes: out, schedules: schedules.filter((s) => ids.has(s.sceneID)).map((s) => ({ ...s, id: up(s.id), sceneID: ids.get(s.sceneID)! })) };
}

/** Raw TLS so the pin is checked on `secureConnect`, before the request (and its token) is written. */
export const pinnedTransport: SyncTransport = (target, path, body) => new Promise((resolve, reject) => {
  const payload = Buffer.from(JSON.stringify(body));
  const socket = connect({ host: target.host, port: target.port, rejectUnauthorized: false, minVersion: 'TLSv1.2' });
  const chunks: Buffer[] = [];
  const fail = (error: Error) => { socket.destroy(); reject(error); };
  socket.setTimeout(REQUEST_TIMEOUT_MS, () => fail(new SyncError('The runner did not answer in time.', 504)));
  socket.on('error', (error) => fail(new SyncError(`Can't reach the runner (${(error as NodeJS.ErrnoException).code ?? error.message}).`, 503)));
  socket.on('secureConnect', () => {
    const raw = socket.getPeerCertificate().raw;
    if (!raw || certPin(raw) !== target.pin) { fail(new SyncError("The runner's identity doesn't match the pairing code. Pair again.", 495)); return; }
    socket.write(`POST ${path} HTTP/1.1\r\nHost: ${target.host}:${target.port}\r\nAuthorization: Bearer ${target.token}\r\nContent-Type: application/json\r\nContent-Length: ${payload.length}\r\nConnection: close\r\n\r\n`);
    socket.write(payload);
  });
  socket.on('data', (chunk: Buffer) => chunks.push(chunk));
  socket.on('end', () => {
    const text = Buffer.concat(chunks).toString('utf8');
    const split = text.indexOf('\r\n\r\n');
    const status = Number(/^HTTP\/1\.1 (\d{3})/.exec(text)?.[1]);
    if (split < 0 || !status) { reject(new SyncError('The runner sent an unreadable answer.', 502)); return; }
    try { resolve({ status, body: JSON.parse(text.slice(split + 4)) }); } catch { reject(new SyncError('The runner sent an unreadable answer.', 502)); }
  });
});

export function lanAddresses(interfaces = networkInterfaces()): string[] {
  return Object.values(interfaces).flat().filter((i) => i && i.family === 'IPv4' && !i.internal).map((i) => i!.address);
}

export class ScheduleSync {
  private saved: SavedSync;
  private readonly server = new WebhookServer();
  private serverStatus = 'Stopped';
  private lastTick: Date;
  /** Shared occurrences that came due while a scene ran, in due order. Memory only; reported when they start or miss. */
  private queued: Array<{ id: string; occurrence: string; at: number }> = [];
  private clientTimer?: NodeJS.Timeout;
  private flushing?: Promise<void>;
  private flushAgain = false;
  private notices: string[] = [];
  private pin?: string;
  private readonly transport: SyncTransport;
  private readonly now: () => Date;

  constructor(private readonly deps: ScheduleSyncDeps) {
    this.transport = deps.transport ?? pinnedTransport;
    this.now = deps.now ?? (() => new Date());
    this.lastTick = this.now();
    this.saved = { version: 1, role: 'off', device: { id: randomUUID().toUpperCase(), name: hostname().slice(0, 64) || 'Computer', platform: deps.platform }, keepAwake: false, port: SYNC_PORT };
    if (!deps.folder) return;
    const file = join(deps.folder, FILE);
    if (!existsSync(file)) return;
    try { this.saved = decodeSaved(JSON.parse(readFileSync(file, 'utf8')), deps.platform); }
    catch {
      // Fail closed: an unreadable sync file never falls back to running schedules locally.
      this.saved.role = 'paired';
      this.notices.push(`The schedule sync file couldn't be read, so schedules won't run on this computer. It was left at ${file}. Turn sync off, then on again.`);
    }
  }

  get enabled(): boolean { return this.deps.folder !== undefined; }
  get role(): Role { return this.saved.role; }
  /** The runner's LAN server is up. `start()` keeps going after a bind error, so the headless bridge checks this. */
  get listening(): boolean { return this.server.running; }
  get port(): number { return this.server.port ?? this.saved.port; }

  /** Moves the runner's server to another port (for example when a Luma window on the same computer uses 8788). Devices pair again. */
  async setPort(port: number): Promise<void> {
    if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new SyncError('Port must be a whole number from 1024 to 65535.');
    const previous = this.saved.port;
    this.saved.port = port;
    if (!this.save()) { this.saved.port = previous; throw new SyncError('Could not save the schedule sync port.'); }
    if (this.saved.role === 'runner' && this.server.running) await this.startServer();
  }

  /** Only an active runner, or a computer that isn't sharing schedules at all, may execute them. */
  get mayExecute(): boolean {
    if (this.saved.role === 'off') return true;
    return this.saved.role === 'runner' && !!this.saved.runner && !this.saved.runner.retiredTo && !this.saved.retirePending;
  }

  /** Starts the server or the background sync after launch. */
  async start(): Promise<void> {
    if (!this.enabled) return;
    // A retired runner keeps answering 410 so devices learn where schedules went.
    if (this.saved.role === 'runner') await this.startServer().catch(() => undefined);
    if (this.saved.role === 'runner') this.deps.keepAwake?.(this.saved.keepAwake && !this.saved.runner?.retiredTo);
    if (this.saved.role === 'paired' && this.saved.client) this.startClientLoop();
    if (this.saved.retirePending) this.startClientLoop();
    this.materialize();
  }

  async stop(): Promise<void> {
    this.dropQueued();
    clearInterval(this.clientTimer); this.clientTimer = undefined;
    await this.server.stop();
    await this.flushing?.catch(() => undefined);
  }

  // ---------- setup ----------

  async becomeRunner(): Promise<void> {
    const secrets = this.requireReady();
    if (this.saved.role !== 'off') throw new SyncError('Turn schedule sync off first.');
    const { scenes, schedules } = canonicalize(this.deps.scenes(), this.deps.schedules());
    const doc = newHubDoc();
    const by = this.saved.device.name, now = this.now().getTime();
    for (const s of scenes) applyOp(doc, { opID: randomUUID().toUpperCase(), type: 'put', kind: 'scene', id: s.id, baseRev: 0, value: sceneToWire(s) }, by, now);
    for (const s of schedules) applyOp(doc, { opID: randomUUID().toUpperCase(), type: 'put', kind: 'schedule', id: s.id, baseRev: 0, value: scheduleToWire(s) }, by, now);
    if (!secrets.read(TOKEN)) secrets.write(TOKEN, newSyncToken());
    this.saved = { ...this.saved, role: 'runner', runner: doc, client: undefined };
    this.save();
    this.materialize();
    this.lastTick = this.now();
    await this.startServer();
    this.deps.keepAwake?.(this.saved.keepAwake);
    this.deps.log('This computer now runs shared schedules. Pair your phone or other computers with its pairing code.');
  }

  /** Pairs with a runner. Local scenes and schedules are added to the runner's (same IDs keep the runner's copy). */
  async pair(code: string): Promise<void> {
    const secrets = this.requireReady();
    if (this.saved.role === 'runner' && !this.saved.runner?.retiredTo) throw new SyncError('This computer runs schedules. Turn that off before pairing it with another computer.');
    const target = parsePairingCode(code);
    const previous = this.saved.client;
    const client: ClientInfo = { host: target.host, port: target.port, pin: target.pin, state: newClientState(), runs: [] };
    const response = await this.request(client, target.token, []);
    // Same runner at a new address keeps its copy and unsent changes; a runner that was turned off and on is a new one.
    const sameRunner = !!previous && previous.pin === target.pin && previous.state.hubID === response.hub.id;
    if (sameRunner) client.state = previous!.state;
    else {
      applyResponse(client.state, [], response);
      const dropped = Object.keys(previous?.state.pending ?? {}).length;
      if (dropped) this.notices.push(`${dropped} unsent change${dropped === 1 ? ' was' : 's were'} dropped: this is a different runner than before.`);
    }
    const state = client.state;
    secrets.write(CLIENT_TOKEN, target.token);
    if (!sameRunner) {
      const local = canonicalize(this.deps.scenes(), this.deps.schedules());
      const known = new Set(Object.values(state.mirror).map((r) => `${r.kind}:${r.id}`));
      for (const s of local.scenes) if (!known.has(`scene:${s.id}`)) stage(state, 'scene', sceneToWire(s));
      for (const s of local.schedules) if (!known.has(`schedule:${s.id}`)) stage(state, 'schedule', scheduleToWire(s));
    }
    this.saved = { ...this.saved, role: 'paired', runner: undefined, client: { ...client, ...this.runnerInfo(response), lastSync: this.now().getTime() } };
    this.deps.keepAwake?.(false);
    await this.server.stop();
    this.save();
    this.materialize();
    this.startClientLoop();
    this.deps.log(`Paired with ${response.hub.name}. It runs your schedules; this computer won't.`);
    await this.syncNow();
  }

  /**
   * Turns sharing off. Schedules stay, but a paired or handed-off computer turns them all
   * off first: the runner may still be running them, and a schedule must never run twice.
   */
  async turnOff(): Promise<void> {
    const wasRunner = this.saved.role === 'runner' && !this.saved.runner?.retiredTo && !this.saved.retirePending;
    clearInterval(this.clientTimer); this.clientTimer = undefined;
    await this.server.stop();
    this.deps.keepAwake?.(false);
    const schedules = this.deps.schedules().map((s) => ({ ...s, enabled: wasRunner ? s.enabled : false }));
    if (!wasRunner && this.saved.role !== 'off') {
      this.deps.apply(this.deps.scenes(), schedules);
      this.deps.log('Schedule sync is off. Schedules here were turned off so they don\'t also run on the other computer; turn on the ones this computer should run.');
    } else if (wasRunner) this.deps.log('Schedule sync is off. Paired devices can no longer change or see these schedules.');
    this.saved = { ...this.saved, role: 'off', runner: undefined, client: undefined, retirePending: undefined };
    for (const name of [CLIENT_TOKEN, RETIRE_TOKEN]) this.deps.secrets?.delete(name);
    this.save();
    this.deps.changed();
  }

  /**
   * Moves running schedules from the paired runner to this computer. The old runner must
   * confirm first; with `force` (old runner unreachable) this computer keeps asking it to stop,
   * and doesn't run anything itself until it has confirmed.
   */
  async takeOver(force = false): Promise<void> {
    const secrets = this.requireReady();
    const client = this.saved.client;
    const token = secrets.read(CLIENT_TOKEN);
    if (this.saved.role !== 'paired' || !client || !token) throw new SyncError('Pair with the current runner first.');
    await this.syncNow();
    const doc = newHubDoc();
    let confirmed = true;
    try {
      const r = await this.transport({ ...client, token }, RETIRE_PATH, { protocol: SYNC_PROTOCOL, runner: { id: doc.hubID, name: this.saved.device.name } });
      if (r.status !== 200 && r.status !== 410) throw new SyncError(errorText(r.body) ?? `The runner refused (${r.status}).`, r.status);
    } catch (error) {
      if (!force) throw error;
      confirmed = false;
    }
    // The runner's copy (with tombstones and its revisions) becomes this computer's.
    for (const r of Object.values(client.state.mirror)) doc.records[`${r.kind}:${r.id}`] = r;
    doc.seq = Math.max(0, ...Object.values(doc.records).map((r) => r.rev));
    for (const p of Object.values(client.state.pending)) {
      const opID = randomUUID().toUpperCase();
      const current = doc.records[`${p.kind}:${p.id}`];
      applyOp(doc, p.desired === null ? { opID, type: 'delete', kind: p.kind, id: p.id } : { opID, type: 'put', kind: p.kind, id: p.id, baseRev: current?.rev ?? 0, value: p.desired }, this.saved.device.name, this.now().getTime());
    }
    if (!secrets.read(TOKEN)) secrets.write(TOKEN, newSyncToken());
    if (!confirmed) secrets.write(RETIRE_TOKEN, token);
    this.saved = { ...this.saved, role: 'runner', runner: doc, client: undefined,
      ...(confirmed ? { retirePending: undefined } : { retirePending: { host: client.host, port: client.port, pin: client.pin, name: client.runner?.name ?? 'the old runner' } }) };
    secrets.delete(CLIENT_TOKEN);
    this.save();
    this.materialize();
    this.lastTick = this.now();
    await this.startServer();
    this.deps.keepAwake?.(this.saved.keepAwake);
    clearInterval(this.clientTimer); this.clientTimer = undefined;
    if (!confirmed) this.startClientLoop();
    this.deps.log(confirmed
      ? 'This computer now runs shared schedules. Pair your other devices with its pairing code.'
      : `This computer will run shared schedules once ${client.runner?.name ?? 'the old runner'} confirms it has stopped. Until then this computer runs nothing; the old runner may still run its copy.`);
  }

  async setKeepAwake(on: boolean): Promise<void> {
    this.saved.keepAwake = on; this.save();
    if (this.mayExecute && this.saved.role === 'runner') this.deps.keepAwake?.(on);
    this.deps.changed();
  }

  /** New token: every paired device must pair again. */
  async rotatePairing(): Promise<void> {
    const secrets = this.requireReady();
    if (this.saved.role !== 'runner') throw new SyncError('Only the runner has a pairing code.');
    secrets.write(TOKEN, newSyncToken());
    await this.startServer();
    this.deps.log('Pairing code replaced. Pair each device again.');
  }

  // ---------- local edits ----------

  /** Called after the home saved, deleted or edited a scene or schedule. No-op when sync is off. */
  localChange(kind: 'scene' | 'schedule', id: string): void {
    if (this.saved.role === 'off' || !this.enabled) return;
    if (this.saved.role === 'runner' && this.saved.runner?.retiredTo) { this.notices.push('This computer no longer runs schedules, so the change stays here only.'); this.deps.changed(); return; }
    const found = kind === 'scene' ? this.deps.scenes().find((s) => s.id === id) : this.deps.schedules().find((s) => s.id === id);
    let value: SceneWire | ScheduleWire | null = null;
    try {
      // canonicalize gives a legacy non-UUID scene a fresh ID; the shared view then replaces the old entry.
      if (found) value = kind === 'scene' ? sceneToWire(canonicalize([found as LightScene], []).scenes[0]!) : scheduleToWire(found as SceneSchedule);
    } catch (error) { this.notices.push(`Not shared: ${(error as Error).message}`); this.materialize(); return; }
    const canon = value?.id ?? canonicalID(id);
    if (!canon) { this.materialize(); return; }
    if (this.saved.role === 'runner' && this.saved.runner) {
      const doc = structuredClone(this.saved.runner);
      const current = doc.records[`${kind}:${canon}`];
      const opID = randomUUID().toUpperCase();
      if (value === null) {
        if (current && !current.deleted) applyOp(doc, { opID, type: 'delete', kind, id: canon! }, this.saved.device.name, this.now().getTime());
      } else {
        const result = applyOp(doc, { opID, type: 'put', kind, id: value.id, baseRev: current?.rev ?? 0, value }, this.saved.device.name, this.now().getTime());
        if (result.status !== 'applied') this.notices.push(`Not saved: ${result.reason ?? result.status}`);
      }
      this.saved.runner = doc;
      this.save();
    } else if (this.saved.client) {
      if (value === null) {
        // Deleting a scene deletes its schedules, as on the runner.
        stage(this.saved.client.state, kind, null, canon);
        if (kind === 'scene') for (const s of clientView<ScheduleWire>(this.saved.client.state, 'schedule')) if (s.sceneID === canon) stage(this.saved.client.state, 'schedule', null, s.id);
      } else {
        try { stage(this.saved.client.state, kind, value); } catch (error) { this.notices.push(`Not shared: ${(error as Error).message}`); }
      }
      this.save();
      void this.syncNow();
    }
    this.materialize();
  }

  /** Replacing everything (backup restore) would bypass the change rules, so it is refused while sharing. */
  assertMayReplaceAll(): void {
    if (this.saved.role !== 'off') throw new SyncError('Turn schedule sync off before restoring a backup, so restored schedules can\'t undo changes made on other devices.');
  }

  // ---------- execution (runner only) ----------

  /** Runs due shared schedules. Returns false when the home's own (unshared) scheduler should run instead. */
  tick(now = this.now()): boolean {
    if (this.saved.role === 'off' || !this.enabled) return false;
    const lastTick = this.lastTick;
    this.lastTick = now;
    if (!this.mayExecute || !this.saved.runner) return true;
    const doc = this.saved.runner;
    const schedules = this.deps.schedules();
    let changed = false;
    for (const wire of liveValues<ScheduleWire>(doc.records, 'schedule')) {
      const local = schedules.find((s) => s.id === wire.id);
      for (const occ of occurrences(wire, lastTick, now)) {
        if (local?.lastRunMinute === occ.key || doc.runs[wire.id]?.occurrence === occ.key) continue;
        // Recorded before the scene starts: after a crash the occurrence is skipped, never repeated.
        if (local) { local.lastRunMinute = occ.key; this.deps.persistHome(); }
        if (!occ.paused && occ.lateMs <= RUN_GRACE_MS) { this.queued.push({ id: wire.id, occurrence: occ.key, at: occ.at }); continue; } // started below
        const report: RunReport = { scheduleID: wire.id, occurrence: occ.key, at: now.getTime(), status: 'paused' };
        if (!occ.paused) { report.status = 'missed'; report.detail = `This computer was asleep or closed until ${Math.round(occ.lateMs / 60_000)} min after the scheduled time.`; }
        if (report.status === 'missed') this.deps.log(`Missed a schedule: ${report.detail}`, true);
        doc.runs[wire.id] = report;
        changed = true;
      }
    }
    this.queued.sort((a, b) => a.at - b.at);
    if (this.startQueued(now) || changed) { this.save(); this.deps.changed(); }
    return true;
  }

  /** Starts queued shared schedules once the running scene ends (the home calls this when its runner is free). */
  runQueued(): void { if (this.startQueued(this.now())) { this.save(); this.deps.changed(); } }

  dropQueued(): void { this.queued = []; }

  /**
   * Starts queued occurrences in due order while no scene runs; one still waiting past the grace is reported missed.
   * The run report is written only when the occurrence starts, misses or fails, so the protocol is unchanged.
   */
  private startQueued(now: Date): boolean {
    const doc = this.saved.runner;
    let wrote = false;
    while (this.queued.length) {
      const q = this.queued[0]!;
      // Disabled, deleted, or this computer stopped running schedules while it waited: dropped.
      const wire = doc && this.mayExecute ? liveValues<ScheduleWire>(doc.records, 'schedule').find((w) => w.id === q.id && w.enabled) : undefined;
      const paused = (wire?.pausedUntil ?? 0) > q.at;
      const busy = this.deps.sceneRunning?.() ?? false, late = now.getTime() - q.at > RUN_GRACE_MS;
      if (wire && !paused && busy && !late) break; // waits for the runner
      this.queued.shift();
      if (!wire) continue;
      const report: RunReport = { scheduleID: q.id, occurrence: q.occurrence, at: now.getTime(), status: 'started' };
      if (paused) report.status = 'paused';
      else if (late) {
        report.status = 'missed'; report.detail = `Another scene was still running ${RUN_GRACE_MS / 60_000} min after the scheduled time.`;
        this.deps.log(`Missed a schedule: ${this.deps.scenes().find((s) => s.id.toUpperCase() === wire.sceneID)?.name ?? 'A scene'} didn't start because another scene was still running ${RUN_GRACE_MS / 60_000} min after its scheduled time.`, true);
      } else {
        try { report.runID = this.deps.run(wire.sceneID); }
        catch (error) { report.status = 'failed'; report.detail = (error as Error).message; this.deps.log(`Schedule skipped: ${report.detail}`, true); }
      }
      doc!.runs[q.id] = report;
      wrote = true;
    }
    return wrote;
  }

  // ---------- paired client ----------

  syncNow(): Promise<void> {
    if (this.flushing) { this.flushAgain = true; return this.flushing; }
    this.flushing = this.flush().finally(() => {
      this.flushing = undefined;
      if (this.flushAgain) { this.flushAgain = false; void this.syncNow(); }
    });
    return this.flushing;
  }

  private async flush(): Promise<void> {
    if (this.saved.retirePending) await this.retryRetire();
    const client = this.saved.client;
    const token = this.deps.secrets?.read(CLIENT_TOKEN);
    if (this.saved.role !== 'paired' || !client || !token) return;
    try {
      for (const batch of buildBatches(client.state)) {
        const response = await this.request(client, token, batch);
        const refusals = applyResponse(client.state, batch, response);
        Object.assign(client, this.runnerInfo(response));
        client.lastSync = this.now().getTime(); client.lastError = undefined; client.moved = undefined;
        this.report(refusals);
        this.save();
      }
    } catch (error) {
      const e = error as SyncError;
      client.lastError = e.message;
      if (e.status === 410) client.moved = e.message;
      this.save();
    }
    this.materialize();
  }

  private async retryRetire(): Promise<void> {
    const pending = this.saved.retirePending!;
    const token = this.deps.secrets?.read(RETIRE_TOKEN);
    if (!token || !this.saved.runner) return;
    try {
      const r = await this.transport({ ...pending, token }, RETIRE_PATH, { protocol: SYNC_PROTOCOL, runner: { id: this.saved.runner.hubID, name: this.saved.device.name } });
      if (r.status !== 200 && r.status !== 410) return;
      this.saved.retirePending = undefined;
      this.deps.secrets?.delete(RETIRE_TOKEN);
      this.lastTick = this.now();
      this.save();
      if (this.saved.role !== 'paired') { clearInterval(this.clientTimer); this.clientTimer = undefined; }
      this.deps.keepAwake?.(this.saved.keepAwake);
      this.deps.log(`${pending.name} confirmed it stopped running schedules. They run on this computer now.`);
    } catch { /* still unreachable; try again next round */ }
  }

  private async request(client: Pick<ClientInfo, 'host' | 'port' | 'pin' | 'state'>, token: string, ops: SyncOp[]): Promise<SyncResponse> {
    const body = { protocol: SYNC_PROTOCOL, client: this.saved.device, ...(client.state.hubID ? { hubID: client.state.hubID } : {}), since: client.state.cursor, ops };
    const r = await this.transport({ host: client.host, port: client.port, pin: client.pin, token }, SYNC_PATH, body);
    if (r.status !== 200) throw new SyncError(errorText(r.body) ?? `The runner answered ${r.status}.`, r.status);
    return r.body as SyncResponse;
  }

  private runnerInfo(response: SyncResponse): Pick<ClientInfo, 'runner' | 'runs'> {
    const { id, name, platform, timeZone, executing } = response.hub;
    return { runner: { id, name, platform, timeZone, executing }, runs: response.runs.slice(0, 1000) };
  }

  private report(refusals: Refusal[]): void {
    for (const r of refusals) this.notices.push(`A change to a ${r.kind} wasn't applied: ${r.reason} The runner's version is shown.`);
    this.notices.splice(0, Math.max(0, this.notices.length - 10));
  }

  private startClientLoop(): void {
    clearInterval(this.clientTimer);
    this.clientTimer = setInterval(() => void this.syncNow(), CLIENT_INTERVAL_MS);
    this.clientTimer.unref?.();
  }

  // ---------- runner server ----------

  private async startServer(): Promise<void> {
    const secrets = this.requireReady();
    const token = secrets.read(TOKEN)!;
    try {
      const { port } = await this.server.start({ port: this.saved.port, allowLAN: true, token, tls: this.identity(secrets), handler: (req) => this.handle(req) });
      this.serverStatus = `Listening on the local network · port ${port}`;
    } catch (error) {
      this.serverStatus = `Not running: ${(error as Error).message}`;
      this.deps.log(`Schedule sync: ${this.serverStatus}`, true);
      throw error;
    }
    this.deps.changed();
  }

  private identity(secrets: SecretStore): { key: string; cert: string } {
    const saved = secrets.read(TLS);
    if (saved) {
      try {
        const id = JSON.parse(saved) as { key: string; cert: string };
        const cert = new X509Certificate(id.cert);
        if (Date.parse(cert.validTo) > Date.now() + 86_400_000) { this.pin = certPin(cert.raw); return id; }
      } catch { /* replaced below; paired devices must pair again */ }
    }
    const fresh = generateWebhookIdentity(new Date(), ['localhost', '127.0.0.1']);
    secrets.write(TLS, JSON.stringify({ key: fresh.key, cert: fresh.cert }));
    this.pin = certPin(new X509Certificate(fresh.cert).raw);
    return fresh;
  }

  /** Exposed for tests: the runner's request handler. */
  async handle(req: HttpRequest): Promise<HttpResponse> {
    const doc = this.saved.runner;
    if (this.saved.role !== 'runner' || !doc) return { status: 503, body: { error: 'This computer no longer runs schedules.' } };
    if (req.method !== 'POST') return { status: 405, body: { error: 'Use POST' } };
    let body: unknown;
    try { body = JSON.parse(req.body.toString('utf8')); } catch { return { status: 400, body: { error: 'Invalid JSON' } }; }
    try {
      if (req.path === SYNC_PATH) {
        const { doc: next, response } = hubHandle(doc, body, { hub: { id: doc.hubID, name: this.saved.device.name, platform: this.saved.device.platform }, timeZone: this.timeZone(), now: this.now().getTime() });
        for (const run of response.runs) if (run.runID) { const status = this.deps.runStatus(run.runID); if (status && status !== 'running') run.status = status as RunReport['status']; }
        if (!this.commit(next)) return { status: 503, body: { error: 'The runner could not save the change. Nothing was applied.' } };
        if (response.results.length) { this.materialize(); }
        else this.deps.changed();
        return { status: 200, body: response };
      }
      if (req.path === RETIRE_PATH) {
        const runner = (body as { runner?: { id?: unknown; name?: unknown } })?.runner;
        const id = canonicalID(runner?.id), name = typeof runner?.name === 'string' ? runner.name.slice(0, 64) : '';
        if ((body as { protocol?: unknown })?.protocol !== SYNC_PROTOCOL || !id || !name) return { status: 400, body: { error: 'Invalid request.' } };
        if (doc.retiredTo) return { status: 410, body: { error: `Schedules already run on ${doc.retiredTo.name}.` } };
        const next = { ...structuredClone(doc), retiredTo: { id, name, at: this.now().getTime() } };
        if (!this.commit(next)) return { status: 503, body: { error: 'The runner could not save the change.' } };
        this.deps.keepAwake?.(false);
        this.deps.log(`Schedules now run on ${name}. This computer stopped running them.`);
        this.deps.changed();
        return { status: 200, body: { retired: true } };
      }
      return { status: 404, body: { error: 'Route not found' } };
    } catch (error) {
      const e = error as SyncError;
      return { status: e instanceof SyncError ? e.status : 500, body: { error: e instanceof SyncError ? e.message : 'Internal error' } };
    }
  }

  /** Saves first, adopts second: an acknowledged change is always on disk. */
  private commit(next: HubDoc): boolean {
    const previous = this.saved.runner;
    this.saved.runner = next;
    if (this.save()) return true;
    this.saved.runner = previous;
    return false;
  }

  // ---------- state ----------

  /** Pushes the shared view into the home: scenes and schedules exactly as the runner (plus unsent changes) has them. */
  private materialize(): void {
    let scenes: SceneWire[], schedules: ScheduleWire[];
    if (this.saved.role === 'runner' && this.saved.runner && !this.saved.runner.retiredTo) {
      scenes = liveValues(this.saved.runner.records, 'scene'); schedules = liveValues(this.saved.runner.records, 'schedule');
    } else if (this.saved.role === 'paired' && this.saved.client) {
      scenes = clientView(this.saved.client.state, 'scene'); schedules = clientView(this.saved.client.state, 'schedule');
    } else { this.deps.changed(); return; }
    const last = new Map(this.deps.schedules().map((s) => [s.id.toUpperCase(), s.lastRunMinute]));
    this.deps.apply(scenes.map(sceneFromWire), schedules.map((w) => scheduleFromWire(w, last.get(w.id))));
    this.deps.changed();
  }

  private save(): boolean {
    if (!this.deps.folder) return true;
    const file = join(this.deps.folder, FILE);
    const temp = `${file}.${randomUUID()}.tmp`;
    try {
      mkdirSync(this.deps.folder, { recursive: true, mode: 0o700 });
      writeFileSync(temp, JSON.stringify(this.saved), { mode: 0o600, flag: 'wx' });
      renameSync(temp, file);
      return true;
    } catch (error) {
      this.deps.log(`Could not save schedule sync: ${(error as Error).message}`, true);
      return false;
    } finally { if (existsSync(temp)) unlinkSync(temp); }
  }

  private requireReady(): SecretStore {
    if (!this.enabled) throw new SyncError('Demo mode: schedule sync is disabled.');
    if (!this.deps.secrets?.available) throw new SyncError('Secure storage is unavailable, so Luma can\'t keep a pairing secret. Schedule sync is off.');
    return this.deps.secrets;
  }

  private timeZone(): string { return this.deps.timeZone?.() ?? Intl.DateTimeFormat().resolvedOptions().timeZone; }

  dismissNotices(): void { this.notices = []; this.deps.changed(); }

  view(): ScheduleSyncView {
    const s = this.saved;
    const base = { available: this.enabled && (this.deps.secrets?.available ?? false), role: s.role, deviceName: s.device.name, mayExecute: this.mayExecute, notices: [...this.notices], timeZone: this.timeZone() };
    if (s.role === 'runner' && s.runner) {
      const token = this.deps.secrets?.read(TOKEN);
      const addresses = (this.deps.addresses ?? lanAddresses)();
      const pin = this.pin;
      const codes = token && pin && !s.runner.retiredTo ? addresses.map((host) => formatPairingCode({ host, port: this.server.port ?? s.port, pin, token } satisfies PairingCode)) : [];
      return { ...base, runner: { status: this.server.running ? this.serverStatus : s.runner.retiredTo ? 'Stopped' : this.serverStatus, pairingCodes: codes, keepAwake: s.keepAwake,
        clients: Object.values(s.runner.clients).sort((a, b) => b.lastSeen - a.lastSeen), runs: Object.values(s.runner.runs),
        ...(s.runner.retiredTo ? { retiredTo: s.runner.retiredTo.name } : {}), ...(s.retirePending ? { waitingFor: s.retirePending.name } : {}) } };
    }
    if (s.role === 'paired' && s.client) {
      const c = s.client;
      return { ...base, paired: { host: c.host, runnerName: c.runner?.name ?? c.host, runnerPlatform: c.runner?.platform, runnerTimeZone: c.runner?.timeZone, runnerExecuting: c.runner?.executing ?? false,
        lastSync: c.lastSync, lastError: c.lastError, moved: c.moved, unsent: Object.keys(c.state.pending).length, runs: c.runs } };
    }
    return base;
  }
}

function errorText(body: unknown): string | undefined {
  return typeof body === 'object' && body !== null && typeof (body as { error?: unknown }).error === 'string' ? (body as { error: string }).error : undefined;
}

function decodeSaved(v: unknown, platform: string): SavedSync {
  const o = v as Partial<SavedSync> & Record<string, unknown>;
  if (!o || o.version !== 1 || !['off', 'runner', 'paired'].includes(o.role as string) || !o.device || !canonicalID(o.device.id)) throw new Error('bad');
  const saved: SavedSync = { version: 1, role: o.role as Role, device: { id: canonicalID(o.device.id)!, name: String(o.device.name).slice(0, 64), platform }, keepAwake: o.keepAwake === true,
    port: typeof o.port === 'number' && Number.isInteger(o.port) && (o.port === 0 || (o.port >= 1024 && o.port <= 65535)) ? o.port : SYNC_PORT };
  if (o.runner) saved.runner = decodeHubDoc(o.runner);
  if (o.client) {
    const c = o.client;
    parsePairingCode(formatPairingCode({ host: c.host, port: c.port, pin: c.pin, token: 'A'.repeat(26) }));
    saved.client = { host: c.host, port: c.port, pin: c.pin, state: decodeClientState(c.state), runs: Array.isArray(c.runs) ? c.runs : [],
      ...(c.runner ? { runner: c.runner } : {}), ...(c.lastSync ? { lastSync: c.lastSync } : {}), ...(c.lastError ? { lastError: c.lastError } : {}), ...(c.moved ? { moved: c.moved } : {}) };
  }
  if (o.retirePending) saved.retirePending = o.retirePending;
  if (saved.role === 'runner' && !saved.runner) throw new Error('bad');
  if (saved.role === 'paired' && !saved.client) throw new Error('bad');
  return saved;
}

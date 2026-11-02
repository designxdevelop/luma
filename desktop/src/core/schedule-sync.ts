// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Shared schedule sync: one desktop ("the runner") holds the authoritative copy of
// scenes and schedules and is the only device that executes them. Phones and other
// computers pair with it over the LAN and send changes as operations. Electron-free and
// clock-free so every rule is testable; the Swift port in LumaCore/ScheduleSync.swift
// follows the same rules and the shared vectors in test/fixtures/schedule-sync-vectors.json.
//
// Rules (docs/SCHEDULE-SYNC.md):
// - Revisions are the runner's own sequence numbers. Device clocks never decide conflicts.
// - Changes that can add activity (create, edit, enable, resume) must name the revision
//   they were based on; a stale one is refused and the runner's copy wins.
// - Changes that only reduce activity (disable, pause, delete) always apply.
// - Deleted records stay as tombstones forever, so nothing can bring them back.

import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { JSONValue } from '../shared/types';
import { minuteKey } from './automation';

export const SYNC_PROTOCOL = 1;
export const SYNC_PATH = '/v1/sync';
export const RETIRE_PATH = '/v1/sync/retire';
export const SYNC_PORT = 8788;
/** Request bodies are capped at 64 KB by both servers; batches stay well under it. */
export const OP_BATCH_BYTES = 48 * 1024;
export const OPS_PER_REQUEST = 200;
export const RECORD_LIMIT = 5000;
/** A run is still started this late (timer jitter, App Nap); later ones are reported as missed. */
export const RUN_GRACE_MS = 120_000;
const APPLIED_PER_CLIENT = 500;
const CLIENT_LIMIT = 64;

export type SyncKind = 'scene' | 'schedule';
export interface SceneStepWire { id: string; deviceID: string; command: { type: string; instance: string; value: JSONValue }; delayMilliseconds: number }
/** Same shape as a scene in the `luma-home-backup` file, so both apps already decode it. */
export interface SceneWire { id: string; name: string; symbol: string; icon?: string; steps: SceneStepWire[] }
export interface ScheduleWire { id: string; sceneID: string; hour: number; minute: number; weekdays: number[]; enabled: boolean; /** Epoch ms. */ pausedUntil?: number }
export type WireValue = SceneWire | ScheduleWire;
export interface SyncRecord { kind: SyncKind; id: string; rev: number; deleted?: true; value?: WireValue; updatedBy: string; updatedAt: number }
export type SyncOp =
  | { opID: string; type: 'put'; kind: SyncKind; id: string; baseRev: number; value: WireValue }
  | { opID: string; type: 'reduce'; kind: 'schedule'; id: string; enabled?: false; pausedUntil?: number }
  | { opID: string; type: 'delete'; kind: SyncKind; id: string };
export type OpStatus = 'applied' | 'conflict' | 'gone' | 'invalid';
export interface OpResult { opID: string; status: OpStatus; rev?: number; reason?: string }
export interface PeerInfo { id: string; name: string; platform: string }
export type RunStatus = 'started' | 'completed' | 'failed' | 'cancelled' | 'missed' | 'paused';
/** What the runner observed when it tried to run a schedule. Telemetry, not settings. */
export interface RunReport { scheduleID: string; occurrence: string; at: number; status: RunStatus; detail?: string; runID?: string }
export interface SyncRequest { protocol: number; client: PeerInfo; hubID?: string; since: number; ops: SyncOp[] }
export interface HubInfo extends PeerInfo { timeZone: string; now: number; executing: boolean }
export interface SyncResponse {
  protocol: number; hub: HubInfo; seq: number; reset: boolean; results: OpResult[]; changes: SyncRecord[];
  runs: RunReport[]; clients: Array<PeerInfo & { lastSeen: number }>;
}
export interface HubDoc {
  protocol: 1; hubID: string; seq: number;
  records: Record<string, SyncRecord>;
  /** Recent results per client, so a resent request after a lost response gets the same answer. */
  applied: Record<string, Array<{ opID: string; result: OpResult }>>;
  clients: Record<string, PeerInfo & { lastSeen: number }>;
  runs: Record<string, RunReport>;
  /** Set when another computer took over running schedules. A retired runner never executes. */
  retiredTo?: { id: string; name: string; at: number };
}

export class SyncError extends Error {
  constructor(message: string, readonly status = 400) { super(message); }
}

const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
export const canonicalID = (id: unknown): string | undefined => {
  if (typeof id !== 'string') return undefined;
  const upper = id.toUpperCase();
  return UUID.test(upper) ? upper : undefined;
};
const keyOf = (kind: SyncKind, id: string) => `${kind}:${id}`;
const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const int = (v: unknown, min: number, max: number) => (typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max ? v : undefined);
const label = (v: unknown, max: number) => (typeof v === 'string' && v.trim() !== '' && v.length <= max && !/[\u0000-\u001f]/.test(v) ? v : undefined);
const invalid = (what: string) => new SyncError(`Invalid ${what}.`);

function jsonValue(v: unknown, depth = 0): JSONValue {
  if (depth > 12) throw invalid('command value');
  if (v === null || typeof v === 'boolean' || typeof v === 'string') return v;
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (Array.isArray(v) && v.length <= 4096) return v.map((x) => jsonValue(x, depth + 1));
  if (isRecord(v) && Object.keys(v).length <= 256) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, jsonValue(x, depth + 1)]));
  throw invalid('command value');
}

/** Structural checks only: the runner validates commands against its own lights when it runs them. */
export function sceneWire(v: unknown): SceneWire {
  if (!isRecord(v)) throw invalid('scene');
  const id = canonicalID(v.id), name = label(v.name, 200);
  if (!id || !name || !Array.isArray(v.steps) || v.steps.length === 0 || v.steps.length > 200) throw invalid('scene');
  let total = 0;
  const stepIDs = new Set<string>();
  const steps = v.steps.map((raw): SceneStepWire => {
    if (!isRecord(raw) || !isRecord(raw.command)) throw invalid('scene step');
    const stepID = canonicalID(raw.id), deviceID = label(raw.deviceID, 128), delay = int(raw.delayMilliseconds ?? 0, 0, 60_000);
    const type = label(raw.command.type, 128), instance = label(raw.command.instance, 128);
    if (!stepID || stepIDs.has(stepID) || !deviceID || delay === undefined || !type || !instance || !('value' in raw.command)) throw invalid('scene step');
    stepIDs.add(stepID);
    if ((total += delay) > 300_000) throw invalid('scene delay');
    return { id: stepID, deviceID, command: { type, instance, value: jsonValue(raw.command.value) }, delayMilliseconds: delay };
  });
  const symbol = label(v.symbol, 64) ?? 'sparkles';
  const icon = typeof v.icon === 'string' && /^[a-z-]{1,24}$/.test(v.icon) ? v.icon : undefined;
  return { id, name, symbol, ...(icon ? { icon } : {}), steps };
}

export function scheduleWire(v: unknown): ScheduleWire {
  if (!isRecord(v)) throw invalid('schedule');
  const id = canonicalID(v.id), sceneID = canonicalID(v.sceneID), hour = int(v.hour, 0, 23), minute = int(v.minute, 0, 59);
  if (!id || !sceneID || hour === undefined || minute === undefined || typeof v.enabled !== 'boolean' || !Array.isArray(v.weekdays) || v.weekdays.length > 7) throw invalid('schedule');
  const weekdays = [...new Set(v.weekdays.map((d) => { const n = int(d, 1, 7); if (n === undefined) throw invalid('schedule'); return n; }))].sort((a, b) => a - b);
  const pausedUntil = v.pausedUntil === undefined || v.pausedUntil === null ? undefined : int(v.pausedUntil, 0, Number.MAX_SAFE_INTEGER);
  if (v.pausedUntil !== undefined && v.pausedUntil !== null && pausedUntil === undefined) throw invalid('schedule');
  return { id, sceneID, hour, minute, weekdays, enabled: v.enabled, ...(pausedUntil !== undefined ? { pausedUntil } : {}) };
}

const wire = (kind: SyncKind, v: unknown): WireValue => (kind === 'scene' ? sceneWire(v) : scheduleWire(v));
const kindOf = (v: unknown): SyncKind => { if (v === 'scene' || v === 'schedule') return v; throw invalid('record kind'); };
const peer = (v: unknown): PeerInfo => {
  if (!isRecord(v) || !canonicalID(v.id) || !label(v.name, 64) || !label(v.platform, 16)) throw invalid('client');
  return { id: canonicalID(v.id)!, name: v.name as string, platform: v.platform as string };
};

/** Strict decode of an untrusted request body. */
export function decodeRequest(body: unknown): SyncRequest {
  if (!isRecord(body) || body.protocol !== SYNC_PROTOCOL) throw new SyncError('This Luma uses a different sync version. Update both apps.', 400);
  const since = int(body.since, 0, Number.MAX_SAFE_INTEGER);
  if (since === undefined || !Array.isArray(body.ops) || body.ops.length > OPS_PER_REQUEST) throw invalid('request');
  const hubID = body.hubID === undefined ? undefined : canonicalID(body.hubID);
  if (body.hubID !== undefined && !hubID) throw invalid('request');
  const ops = body.ops.map((raw): SyncOp => {
    if (!isRecord(raw)) throw invalid('change');
    const opID = canonicalID(raw.opID), id = canonicalID(raw.id), kind = kindOf(raw.kind);
    if (!opID || !id) throw invalid('change');
    if (raw.type === 'put') {
      const baseRev = int(raw.baseRev, 0, Number.MAX_SAFE_INTEGER);
      if (baseRev === undefined) throw invalid('change');
      return { opID, type: 'put', kind, id, baseRev, value: raw.value as WireValue }; // value checked when applied
    }
    if (raw.type === 'reduce' && kind === 'schedule') {
      if (raw.enabled !== undefined && raw.enabled !== false) throw invalid('change');
      const pausedUntil = raw.pausedUntil === undefined ? undefined : int(raw.pausedUntil, 0, Number.MAX_SAFE_INTEGER);
      if (raw.pausedUntil !== undefined && pausedUntil === undefined) throw invalid('change');
      return { opID, type: 'reduce', kind, id, ...(raw.enabled === false ? { enabled: false as const } : {}), ...(pausedUntil !== undefined ? { pausedUntil } : {}) };
    }
    if (raw.type === 'delete') return { opID, type: 'delete', kind, id };
    throw invalid('change');
  });
  return { protocol: SYNC_PROTOCOL, client: peer(body.client), ...(hubID ? { hubID } : {}), since, ops };
}

// ---------------- runner (hub) ----------------

export function newHubDoc(hubID = randomUUID().toUpperCase()): HubDoc {
  return { protocol: 1, hubID, seq: 0, records: {}, applied: {}, clients: {}, runs: {} };
}

/** Strict decode of a saved runner file. Throws rather than guessing, so a damaged file is never served. */
export function decodeHubDoc(v: unknown): HubDoc {
  if (!isRecord(v) || v.protocol !== 1 || !canonicalID(v.hubID) || int(v.seq, 0, Number.MAX_SAFE_INTEGER) === undefined || !isRecord(v.records)) throw invalid('runner file');
  const records: Record<string, SyncRecord> = {};
  for (const raw of Object.values(v.records)) {
    const r = decodeRecord(raw);
    records[keyOf(r.kind, r.id)] = r;
  }
  const doc = v as unknown as HubDoc;
  return { protocol: 1, hubID: canonicalID(v.hubID)!, seq: v.seq as number, records,
    applied: isRecord(v.applied) ? doc.applied : {}, clients: isRecord(v.clients) ? doc.clients : {}, runs: isRecord(v.runs) ? doc.runs : {},
    ...(isRecord(v.retiredTo) ? { retiredTo: doc.retiredTo } : {}) };
}

export function decodeRecord(raw: unknown): SyncRecord {
  if (!isRecord(raw)) throw invalid('record');
  const kind = kindOf(raw.kind), id = canonicalID(raw.id), rev = int(raw.rev, 1, Number.MAX_SAFE_INTEGER);
  if (!id || rev === undefined) throw invalid('record');
  const base = { kind, id, rev, updatedBy: typeof raw.updatedBy === 'string' ? raw.updatedBy.slice(0, 64) : '', updatedAt: int(raw.updatedAt, 0, Number.MAX_SAFE_INTEGER) ?? 0 };
  if (raw.deleted === true) return { ...base, deleted: true };
  const value = wire(kind, raw.value);
  if (value.id !== id) throw invalid('record');
  return { ...base, value };
}

const liveValue = (doc: HubDoc, kind: SyncKind, id: string) => { const r = doc.records[keyOf(kind, id)]; return r && !r.deleted ? r.value : undefined; };

function bump(doc: HubDoc, record: Omit<SyncRecord, 'rev' | 'updatedBy' | 'updatedAt'>, by: string, now: number): number {
  const rev = ++doc.seq;
  doc.records[keyOf(record.kind, record.id)] = { ...record, rev, updatedBy: by, updatedAt: now };
  return rev;
}

/** Applies one change to the runner's copy. The caller saves before answering. */
export function applyOp(doc: HubDoc, op: SyncOp, by: string, now: number): OpResult {
  const key = keyOf(op.kind, op.id);
  const current = doc.records[key];
  const result = (status: OpStatus, reason?: string, rev = doc.records[key]?.rev): OpResult => ({ opID: op.opID, status, ...(rev !== undefined ? { rev } : {}), ...(reason ? { reason } : {}) });
  if (op.type === 'delete') {
    if (current?.deleted) return result('applied');
    bump(doc, { kind: op.kind, id: op.id, deleted: true }, by, now);
    if (op.kind === 'scene') {
      // Same as deleting a scene in either app: its schedules go with it.
      for (const r of Object.values(doc.records)) {
        if (r.kind === 'schedule' && !r.deleted && (r.value as ScheduleWire).sceneID === op.id) bump(doc, { kind: 'schedule', id: r.id, deleted: true }, by, now);
      }
    }
    return result('applied');
  }
  if (op.type === 'reduce') {
    if (!current) return result('gone', 'This schedule was never saved on the runner.');
    if (current.deleted) return result('applied');
    const value = { ...(current.value as ScheduleWire) };
    let changed = false;
    if (op.enabled === false && value.enabled) { value.enabled = false; changed = true; }
    if (op.pausedUntil !== undefined && op.pausedUntil > (value.pausedUntil ?? 0)) { value.pausedUntil = op.pausedUntil; changed = true; }
    if (changed) bump(doc, { kind: 'schedule', id: op.id, value }, by, now);
    return result('applied');
  }
  let value: WireValue;
  try { value = wire(op.kind, op.value); } catch (error) { return result('invalid', (error as Error).message); }
  if (value.id !== op.id) return result('invalid', 'The record ID does not match.');
  if (current?.deleted) return result('conflict', 'It was deleted on another device.');
  if (!current && op.baseRev !== 0) return result('gone', 'It no longer exists on the runner.');
  if (current && current.rev !== op.baseRev) return result('conflict', 'It was changed on another device first.');
  if (op.kind === 'schedule' && !liveValue(doc, 'scene', (value as ScheduleWire).sceneID)) return result('invalid', 'Its scene is not on the runner.');
  if (!current && Object.keys(doc.records).length >= RECORD_LIMIT) return result('invalid', 'The runner holds the maximum number of records.');
  const rev = bump(doc, { kind: op.kind, id: op.id, value }, by, now);
  return result('applied', undefined, rev);
}

export interface HubContext { hub: PeerInfo; timeZone: string; now: number }

/**
 * Handles one sync request against a copy of the runner's state. Returns the new state,
 * which the caller must save durably before sending the response; on a failed save the
 * caller keeps the old state and answers 503, so a client never sees an unsaved change acknowledged.
 */
export function hubHandle(doc: HubDoc, body: unknown, ctx: HubContext): { doc: HubDoc; response: SyncResponse } {
  if (doc.retiredTo) throw new SyncError(`Schedules now run on ${doc.retiredTo.name}. Pair with it instead.`, 410);
  const request = decodeRequest(body);
  if (request.hubID && request.hubID !== doc.hubID) throw new SyncError('This is a different runner than the one you paired with. Pair again.', 409);
  const next: HubDoc = structuredClone(doc);
  const log = (next.applied[request.client.id] ??= []);
  const results = request.ops.map((op) => {
    const seen = log.find((e) => e.opID === op.opID);
    if (seen) return seen.result;
    const result = applyOp(next, op, request.client.name, ctx.now);
    log.push({ opID: op.opID, result });
    return result;
  });
  log.splice(0, Math.max(0, log.length - APPLIED_PER_CLIENT));
  next.clients[request.client.id] = { ...request.client, lastSeen: ctx.now };
  const clients = Object.values(next.clients).sort((a, b) => b.lastSeen - a.lastSeen);
  for (const stale of clients.slice(CLIENT_LIMIT)) { delete next.clients[stale.id]; delete next.applied[stale.id]; }
  const reset = request.since > next.seq || (request.hubID === undefined && request.since !== 0);
  const since = reset ? 0 : request.since;
  return { doc: next, response: {
    protocol: SYNC_PROTOCOL, hub: { ...ctx.hub, timeZone: ctx.timeZone, now: ctx.now, executing: !next.retiredTo }, seq: next.seq, reset, results,
    changes: Object.values(next.records).filter((r) => r.rev > since).sort((a, b) => a.rev - b.rev),
    runs: Object.values(next.runs), clients: clients.slice(0, CLIENT_LIMIT),
  } };
}

/** Live values of one kind, as the runner should execute them. */
export function liveValues<T extends WireValue>(records: Record<string, SyncRecord>, kind: SyncKind): T[] {
  return Object.values(records).filter((r) => r.kind === kind && !r.deleted).map((r) => r.value as T);
}

// ---------------- paired device (client) ----------------

export interface Pending { kind: SyncKind; id: string; opID: string; baseRev: number; /** null = delete */ desired: WireValue | null }
export interface ClientState { hubID?: string; cursor: number; mirror: Record<string, SyncRecord>; pending: Record<string, Pending> }
export const newClientState = (): ClientState => ({ cursor: 0, mirror: {}, pending: {} });

export function decodeClientState(v: unknown): ClientState {
  if (!isRecord(v) || int(v.cursor, 0, Number.MAX_SAFE_INTEGER) === undefined || !isRecord(v.mirror) || !isRecord(v.pending)) throw invalid('sync file');
  const mirror: Record<string, SyncRecord> = {};
  for (const raw of Object.values(v.mirror)) { const r = decodeRecord(raw); mirror[keyOf(r.kind, r.id)] = r; }
  const pending: Record<string, Pending> = {};
  for (const raw of Object.values(v.pending)) {
    if (!isRecord(raw)) throw invalid('sync file');
    const kind = kindOf(raw.kind), id = canonicalID(raw.id), opID = canonicalID(raw.opID), baseRev = int(raw.baseRev, 0, Number.MAX_SAFE_INTEGER);
    if (!id || !opID || baseRev === undefined) throw invalid('sync file');
    pending[keyOf(kind, id)] = { kind, id, opID, baseRev, desired: raw.desired === null ? null : wire(kind, raw.desired) };
  }
  const hubID = canonicalID(v.hubID);
  return { ...(hubID ? { hubID } : {}), cursor: v.cursor as number, mirror, pending };
}

const same = (a: unknown, b: unknown) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
function canonical(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(canonical);
  if (isRecord(v)) return Object.fromEntries(Object.keys(v).sort().filter((k) => v[k] !== undefined).map((k) => [k, canonical(v[k])]));
  return v;
}

/** Records a local change to send later. Several edits before a sync collapse into one change. */
export function stage(state: ClientState, kind: SyncKind, desired: WireValue | null, id = desired?.id): void {
  const canon = canonicalID(id);
  if (!canon) throw invalid('record ID');
  const key = keyOf(kind, canon);
  const mirrored = state.mirror[key];
  const existing = state.pending[key];
  const live = mirrored && !mirrored.deleted ? mirrored.value : undefined;
  if ((desired === null && !mirrored) || (desired !== null && live && same(live, desired)) || (desired === null && mirrored?.deleted)) { delete state.pending[key]; return; }
  state.pending[key] = { kind, id: canon, opID: randomUUID().toUpperCase(), baseRev: existing?.baseRev ?? mirrored?.rev ?? 0, desired: desired === null ? null : wire(kind, desired) };
}

/** What this device should show: the runner's copy with unsent local changes on top. */
export function clientView<T extends WireValue>(state: ClientState, kind: SyncKind): T[] {
  const values = new Map<string, WireValue>();
  for (const r of Object.values(state.mirror)) if (r.kind === kind && !r.deleted && r.value) values.set(r.id, r.value);
  for (const p of Object.values(state.pending)) {
    if (p.kind !== kind) continue;
    if (p.desired === null) values.delete(p.id); else values.set(p.id, p.desired);
  }
  return [...values.values()] as T[];
}

/** True when `next` only turns a schedule off or pauses it for longer. */
export function onlyReduces(before: ScheduleWire, next: ScheduleWire): boolean {
  const { enabled: e1, pausedUntil: p1, ...rest1 } = before;
  const { enabled: e2, pausedUntil: p2, ...rest2 } = next;
  if (!same(rest1, rest2)) return false;
  const disables = e1 && !e2, keeps = e1 === e2;
  const pauses = (p2 ?? 0) > (p1 ?? 0), pauseSame = (p2 ?? 0) === (p1 ?? 0);
  return (disables || keeps) && (pauses || pauseSame) && (disables || pauses);
}

/** Changes in a safe order (scenes before the schedules that use them), split under the body limit. */
export function buildBatches(state: ClientState): SyncOp[][] {
  const order = (p: Pending) => (p.desired === null ? (p.kind === 'schedule' ? 2 : 3) : (p.kind === 'scene' ? 0 : 1));
  const ops = Object.values(state.pending).sort((a, b) => order(a) - order(b)).map((p): SyncOp => {
    if (p.desired === null) return { opID: p.opID, type: 'delete', kind: p.kind, id: p.id };
    const mirrored = state.mirror[keyOf(p.kind, p.id)];
    if (p.kind === 'schedule' && mirrored && !mirrored.deleted && onlyReduces(mirrored.value as ScheduleWire, p.desired as ScheduleWire)) {
      const before = mirrored.value as ScheduleWire, next = p.desired as ScheduleWire;
      return { opID: p.opID, type: 'reduce', kind: 'schedule', id: p.id,
        ...(before.enabled && !next.enabled ? { enabled: false as const } : {}),
        ...((next.pausedUntil ?? 0) > (before.pausedUntil ?? 0) ? { pausedUntil: next.pausedUntil } : {}) };
    }
    return { opID: p.opID, type: 'put', kind: p.kind, id: p.id, baseRev: p.baseRev, value: p.desired };
  });
  const batches: SyncOp[][] = [[]];
  let size = 0;
  for (const op of ops) {
    const bytes = Buffer.byteLength(JSON.stringify(op)) + 1;
    const last = batches[batches.length - 1]!;
    if (last.length && (size + bytes > OP_BATCH_BYTES || last.length >= OPS_PER_REQUEST)) { batches.push([op]); size = bytes; }
    else { last.push(op); size += bytes; }
  }
  return batches;
}

/** A change the runner refused, with the name the person knows it by. */
export interface Refusal { kind: SyncKind; id: string; status: OpStatus; reason: string }

/** Folds a response into the local mirror. Returns refused changes so the UI can say what was undone. */
export function applyResponse(state: ClientState, sent: SyncOp[], response: SyncResponse): Refusal[] {
  if (state.hubID && response.hub.id !== state.hubID) throw new SyncError('This is a different runner than the one you paired with. Pair again.', 409);
  state.hubID = response.hub.id;
  if (response.reset) state.mirror = {};
  for (const raw of response.changes) {
    const r = decodeRecord(raw);
    const key = keyOf(r.kind, r.id);
    if ((state.mirror[key]?.rev ?? 0) < r.rev || response.reset) state.mirror[key] = r;
  }
  state.cursor = response.seq;
  const refusals: Refusal[] = [];
  for (const op of sent) {
    const result = response.results.find((x) => x.opID === op.opID);
    if (!result) continue;
    const key = keyOf(op.kind, op.id);
    const pending = state.pending[key];
    if (result.status === 'applied') {
      if (pending?.opID === op.opID) delete state.pending[key];
      else if (pending && result.rev !== undefined) pending.baseRev = result.rev; // edited again while this was in flight
    } else {
      refusals.push({ kind: op.kind, id: op.id, status: result.status, reason: result.reason ?? 'Refused by the runner.' });
      if (pending?.opID === op.opID) delete state.pending[key];
    }
  }
  // A local change to something the runner has since deleted can never apply.
  for (const [key, p] of Object.entries(state.pending)) if (state.mirror[key]?.deleted && p.desired !== null && p.baseRev !== 0) delete state.pending[key];
  return refusals;
}

// ---------------- execution ----------------

export interface Occurrence { key: string; at: number; lateMs: number; paused: boolean }

/**
 * Scheduled local minutes in (lastTick, now], at most a day back. Local wall-clock math:
 * a time skipped by a spring-forward change never occurs, and a time repeated by a
 * fall-back change shares one key, so it runs once.
 */
export function occurrences(schedule: ScheduleWire, lastTick: Date, now: Date): Occurrence[] {
  if (!schedule.enabled || now <= lastTick) return [];
  const found: Occurrence[] = [];
  const from = Math.max(lastTick.getTime(), now.getTime() - 86_400_000);
  for (let t = Math.floor(from / 60_000) * 60_000 + 60_000; t <= now.getTime(); t += 60_000) {
    const d = new Date(t);
    if (d.getHours() !== schedule.hour || d.getMinutes() !== schedule.minute || !schedule.weekdays.includes(d.getDay() + 1)) continue;
    found.push({ key: minuteKey(d), at: t, lateMs: now.getTime() - t, paused: (schedule.pausedUntil ?? 0) > t });
  }
  return found;
}

// ---------------- pairing ----------------

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export function base32(bytes: Uint8Array): string {
  let out = '', bits = 0, value = 0;
  for (const byte of bytes) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}
/** First 128 bits of the certificate's SHA-256, in base32: short enough to type, long enough to pin. */
export const certPin = (der: Uint8Array): string => base32(createHash('sha256').update(der).digest().subarray(0, 16));
export const newSyncToken = (): string => base32(randomBytes(16));

export interface PairingCode { host: string; port: number; pin: string; token: string }
export const formatPairingCode = (c: PairingCode): string => `luma1/${c.host}/${c.port}/${c.pin}/${c.token}`;
export function parsePairingCode(text: string): PairingCode {
  const parts = text.trim().replace(/\s+/g, '').split('/');
  const bad = new SyncError('That pairing code is not complete. Copy it again from the computer that runs schedules.');
  if (parts.length !== 5 || parts[0]!.toLowerCase() !== 'luma1') throw bad;
  const [, host, portText, pin, token] = parts as [string, string, string, string, string];
  const port = Number(portText);
  if (!/^[A-Za-z0-9.-]{1,253}$/.test(host) || !Number.isInteger(port) || port < 1 || port > 65535) throw bad;
  const p = pin.toUpperCase(), t = token.toUpperCase();
  if (!/^[A-Z2-7]{26}$/.test(p) || !/^[A-Z2-7]{26}$/.test(t)) throw bad;
  return { host, port, pin: p, token: t };
}

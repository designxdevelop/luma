// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Home persistence. Owner-only permissions where the OS supports them, atomic replace,
// and an unreadable file is preserved instead of overwritten.

import { existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { Capability, CapabilityCommand, DreamViewDraft, JSONValue, LightDevice, LightScene, SavedHome, SceneSchedule, SceneStep } from '../shared/types';
import { DEFAULT_SYNC_SETTINGS, REGIONS, validateSettings } from '../shared/sync-math';
import { isObject, repairStepIDs, safeInt } from '../core/model';

export const emptyHome = (): SavedHome => ({ version: 1, devices: [], scenes: [], schedules: [], webhookPort: 8787, allowLAN: false });

export class HomeStorage {
  readonly file: string;
  private unreadable = false;
  constructor(readonly folder: string) { this.file = join(folder, 'home.json'); }

  load(): SavedHome {
    try {
      if (!existsSync(this.file)) { this.unreadable = false; return emptyHome(); }
      if (statSync(this.file).size > HOME_LIMIT) throw invalidHome();
      const home = decodeHome(JSON.parse(readFileSync(this.file, 'utf8')));
      this.unreadable = false;
      return home;
    } catch (error) { this.unreadable = true; throw error; }
  }

  save(home: SavedHome): void {
    if (this.unreadable) throw invalidHome();
    this.write(this.file, home);
  }

  /** A safety copy beside home.json (for example before a restore), replaced each time. Owner-only. */
  saveCopy(home: SavedHome, name: 'home-before-restore.json'): void {
    this.write(join(this.folder, name), home);
  }

  private write(file: string, home: SavedHome): void {
    // Reconstruct known fields only: accidental runtime fields/secrets are not serialized.
    let data: string;
    try { data = JSON.stringify(decodeHome(home), null, 2); } catch { throw unsavable(); }
    if (Buffer.byteLength(data) > HOME_LIMIT) throw unsavable();
    mkdirSync(this.folder, { recursive: true, mode: 0o700 });
    atomicWrite(file, data);
  }
}

/** Owner-only temp file, then rename over the target: a crash leaves the old file or the new one, never half of one. */
export function atomicWrite(file: string, data: string | Buffer): void {
  const temp = `${file}.${randomUUID()}.tmp`;
  try { writeFileSync(temp, data, { mode: 0o600, flag: 'wx' }); renameSync(temp, file); }
  finally { if (existsSync(temp)) unlinkSync(temp); }
}

const HOME_LIMIT = 8 * 1024 * 1024;
const invalidHome = () => new Error('Unrecognized or damaged home file. The original file has been preserved.');
/** In-memory data that the file format can't hold; nothing on disk is wrong. */
const unsavable = () => new Error('Some data in memory is not in a form Luma can store, so this change was not written. The last saved home file is unchanged.');
const text = (v: unknown, max: number, allowEmpty = false): string => {
  if (typeof v !== 'string' || v.length > max || (!allowEmpty && !v.trim()) || /[\u0000-\u001f]/.test(v)) throw invalidHome();
  return v;
};
const list = (v: unknown, max: number): unknown[] => {
  if (!Array.isArray(v) || v.length > max) throw invalidHome();
  return v;
};
const unique = <T extends { id: string }>(values: T[]): T[] => {
  if (new Set(values.map(v => v.id)).size !== values.length) throw invalidHome();
  return values;
};
function json(v: unknown, depth = 0): JSONValue {
  if (depth > 12) throw invalidHome();
  if (v === null || typeof v === 'boolean' || typeof v === 'string') return v;
  if (typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= Number.MAX_SAFE_INTEGER) return v;
  if (Array.isArray(v)) return list(v, 4096).map(item => json(item, depth + 1));
  if (isObject(v)) {
    const entries = Object.entries(v);
    if (entries.length > 256) throw invalidHome();
    return Object.fromEntries(entries.map(([k, value]) => [k, json(value, depth + 1)]));
  }
  throw invalidHome();
}
function command(v: unknown): CapabilityCommand {
  if (!isObject(v) || !Object.hasOwn(v, 'value')) throw invalidHome();
  return { type: text(v.type, 128), instance: text(v.instance, 128), value: json(v.value) };
}
function device(v: unknown): LightDevice {
  if (!isObject(v)) throw invalidHome();
  const result: LightDevice = {
    id: text(v.id, 128), sku: text(v.sku, 64), name: text(v.name, 160), room: text(v.room, 160, true),
    capabilities: list(v.capabilities ?? [], 256).map((raw): Capability => {
      if (!isObject(raw)) throw invalidHome();
      return { type: text(raw.type, 128), instance: text(raw.instance, 128), ...(raw.parameters === undefined ? {} : { parameters: json(raw.parameters) }) };
    }),
  };
  if (v.customName !== undefined) result.customName = text(v.customName, 64);
  if (v.deviceType !== undefined) result.deviceType = text(v.deviceType, 128);
  if (v.power !== undefined) {
    if (typeof v.power !== 'boolean') throw invalidHome();
    result.power = v.power;
  }
  for (const [field, max] of [['brightness', 100], ['rgb', 0xffffff], ['colorTemperature', 10000], ['lastSeen', Number.MAX_SAFE_INTEGER]] as const) {
    if (v[field] === undefined) continue;
    const n = safeInt(v[field], 0, max);
    if (n === undefined) throw invalidHome();
    result[field] = n;
  }
  // Addresses, liveness and demo flags are deliberately never restored or saved.
  return result;
}
/** Structural scene decoder (no light lookup): also used for backup restore. Throws on any malformed field. */
export function scene(v: unknown): LightScene {
  if (!isObject(v)) throw invalidHome();
  let total = 0;
  const result: LightScene = {
    id: text(v.id, 64), name: text(v.name, 80), icon: typeof v.icon === 'string' && /^[a-z-]{1,24}$/.test(v.icon) ? v.icon : 'sparkles',
    steps: list(v.steps, 200).map((raw): SceneStep => {
      if (!isObject(raw)) throw invalidHome();
      const delay = safeInt(raw.delayMilliseconds ?? 0, 0, 60000);
      if (delay === undefined || (total += delay) > 300000) throw invalidHome();
      return { id: typeof raw.id === 'string' && raw.id.length <= 64 ? raw.id : '', deviceID: text(raw.deviceID, 128), command: command(raw.command), delayMilliseconds: delay };
    }),
  };
  // Repair only local legacy identifiers. Import and execution retain strict duplicate rejection.
  return repairStepIDs(result);
}
export function schedule(v: unknown): SceneSchedule {
  if (!isObject(v)) throw invalidHome();
  const hour = safeInt(v.hour, 0, 23), minute = safeInt(v.minute, 0, 59);
  if (hour === undefined || minute === undefined || typeof v.enabled !== 'boolean') throw invalidHome();
  const weekdays = list(v.weekdays, 7).map(day => {
    const n = safeInt(day, 1, 7);
    if (n === undefined) throw invalidHome();
    return n;
  });
  const pausedUntil = v.pausedUntil === undefined ? undefined : safeInt(v.pausedUntil, 1);
  return { id: text(v.id, 64), sceneID: text(v.sceneID, 64), hour, minute, weekdays: [...new Set(weekdays)], enabled: v.enabled,
    ...(pausedUntil === undefined ? {} : { pausedUntil }),
    ...(v.lastRunMinute === undefined ? {} : { lastRunMinute: text(v.lastRunMinute, 80) }) };
}
/** Native DreamView drafts, shape-checked so a re-exported backup always decodes on the Mac. */
export function dreamViewDrafts(v: unknown): Record<string, DreamViewDraft> {
  if (!isObject(v) || Object.keys(v).length > 1000) throw invalidHome();
  return Object.fromEntries(Object.entries(v).map(([id, draft]) => {
    if (id.length > 128 || !isObject(draft)) throw invalidHome();
    const members = list(draft.members ?? [], 64).map((m) => {
      if (!isObject(m)) throw invalidHome();
      const areas = list(m.areas ?? [], 10).map((a) => { const n = safeInt(a, 1, 10); if (n === undefined) throw invalidHome(); return n; });
      return { deviceID: text(m.deviceID, 128), areas };
    });
    return [id, { members }];
  }));
}
function decodeHome(v: unknown): SavedHome {
  if (!isObject(v) || v.version !== 1) throw invalidHome();
  return { version: 1,
    devices: unique(list(v.devices, 1000).map(device)),
    scenes: unique(list(v.scenes, 1000).map(scene)),
    schedules: unique(list(v.schedules, 1000).map(schedule)),
    webhookPort: safeInt(v.webhookPort, 1024, 65535) ?? 8787,
    allowLAN: v.allowLAN === true,
    appearance: v.appearance === 'light' || v.appearance === 'dark' ? v.appearance : 'system',
    syncSettings: v.syncSettings === undefined ? { ...DEFAULT_SYNC_SETTINGS } : validateSettings(v.syncSettings, DEFAULT_SYNC_SETTINGS),
    syncAssignments: v.syncAssignments === undefined ? [] : unique(list(v.syncAssignments, 1000).map(raw => {
      if (!isObject(raw) || typeof raw.region !== 'string' || !REGIONS.includes(raw.region as never) || typeof raw.included !== 'boolean') throw invalidHome();
      return { id: text(raw.id, 128), region: raw.region as (typeof REGIONS)[number], included: raw.included };
    })),
    ...(v.dreamViewDrafts === undefined ? {} : { dreamViewDrafts: dreamViewDrafts(v.dreamViewDrafts) }),
  };
}

/** Encrypted secret storage. Implementations must never fall back to plaintext. */
export interface SecretStore {
  readonly available: boolean;
  read(name: string): string | undefined;
  write(name: string, value: string): void;
  delete(name: string): void;
}

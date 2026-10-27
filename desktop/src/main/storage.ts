// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Home persistence. Owner-only permissions where the OS supports them, atomic replace,
// and an unreadable file is preserved instead of overwritten.

import { existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { Capability, CapabilityCommand, JSONValue, LightDevice, LightScene, SavedHome, SceneSchedule, SceneStep } from '../shared/types';
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
    // Reconstruct known fields only: accidental runtime fields/secrets are not serialized.
    const data = JSON.stringify(decodeHome(home), null, 2);
    if (Buffer.byteLength(data) > HOME_LIMIT) throw invalidHome();
    mkdirSync(this.folder, { recursive: true, mode: 0o700 });
    const temp = `${this.file}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temp, data, { mode: 0o600, flag: 'wx' });
      renameSync(temp, this.file);
    } finally {
      if (existsSync(temp)) unlinkSync(temp);
    }
  }
}

const HOME_LIMIT = 8 * 1024 * 1024;
const invalidHome = () => new Error('Unrecognized or damaged home file. The original file has been preserved.');
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
function scene(v: unknown): LightScene {
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
function schedule(v: unknown): SceneSchedule {
  if (!isObject(v)) throw invalidHome();
  const hour = safeInt(v.hour, 0, 23), minute = safeInt(v.minute, 0, 59);
  if (hour === undefined || minute === undefined || typeof v.enabled !== 'boolean') throw invalidHome();
  const weekdays = list(v.weekdays, 7).map(day => {
    const n = safeInt(day, 1, 7);
    if (n === undefined) throw invalidHome();
    return n;
  });
  return { id: text(v.id, 64), sceneID: text(v.sceneID, 64), hour, minute, weekdays: [...new Set(weekdays)], enabled: v.enabled,
    ...(v.lastRunMinute === undefined ? {} : { lastRunMinute: text(v.lastRunMinute, 80) }) };
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
  };
}

/** Encrypted secret storage. Implementations must never fall back to plaintext. */
export interface SecretStore {
  readonly available: boolean;
  read(name: string): string | undefined;
  write(name: string, value: string): void;
  delete(name: string): void;
}

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Whole-home backup in the native app's `luma-home-backup` v1 format, so a file
// made on Windows/Linux restores on Mac/iPhone and the other way round. A backup
// holds scenes, schedules, names and rooms; never keys, tokens, IPs or webhook settings.

import { randomUUID } from 'node:crypto';
import type { BackupResult, DreamViewDraft, LightScene, SavedHome, SceneSchedule } from '../shared/types';
import { LumaError, fitText, isObject } from '../core/model';
import { dreamViewDrafts, scene as decodeScene, schedule as decodeSchedule } from './storage';

export const BACKUP_FORMAT = 'luma-home-backup';
export const BACKUP_VERSION = 1;
export const BACKUP_LIMIT = 8 * 1024 * 1024;

export interface BackupLight { id: string; sku: string; customName?: string; room: string }
export interface DecodedBackup { scenes: LightScene[]; schedules: SceneSchedule[]; lights: BackupLight[]; dreamViewDrafts?: Record<string, DreamViewDraft> }

// Electron icon ↔ native SF Symbol. Unknown names fall back to sparkles on either side.
const SYMBOLS: Record<string, string> = {
  sparkles: 'sparkles', moon: 'moon.stars', sun: 'sun.max', sofa: 'sofa', bed: 'bed.double', book: 'book', film: 'film',
  party: 'party.popper', leaf: 'leaf', coffee: 'cup.and.saucer', bolt: 'bolt', heart: 'heart',
};
const ICONS: Record<string, string> = {
  ...Object.fromEntries(Object.entries(SYMBOLS).map(([icon, symbol]) => [symbol, icon])),
  sunrise: 'sun', sunset: 'sun', tv: 'film', gamecontroller: 'party', 'fork.knife': 'coffee', 'music.note': 'party', 'arrow.uturn.backward': 'sparkles',
};
export const symbolFor = (icon: string): string => SYMBOLS[icon] ?? 'sparkles';
export const iconFor = (symbol: string): string => ICONS[symbol] ?? 'sparkles';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Encodes the backup JSON. Non-UUID IDs (older Electron scenes) get fresh UUIDs, with schedules rewired to match. */
export function encodeBackup(home: SavedHome, now = new Date()): string {
  const sceneIDs = new Map<string, string>();
  const uuid = (id: string) => (UUID.test(id) ? id : randomUUID());
  const scenes = home.scenes.map((s) => {
    const id = uuid(s.id);
    sceneIDs.set(s.id, id);
    return { id, name: s.name, symbol: symbolFor(s.icon), icon: s.icon,
      steps: s.steps.map((st) => ({ id: uuid(st.id), deviceID: st.deviceID, command: st.command, delayMilliseconds: st.delayMilliseconds })) };
  });
  const schedules = home.schedules.filter((s) => sceneIDs.has(s.sceneID)).map((s) => ({
    id: uuid(s.id), sceneID: sceneIDs.get(s.sceneID)!, hour: s.hour, minute: s.minute, weekdays: s.weekdays, enabled: s.enabled,
  }));
  const lights = home.devices.filter((d) => !d.isDemo).map((d) => ({ id: d.id, sku: d.sku, ...(d.customName ? { customName: d.customName } : {}), room: d.room }));
  // Swift's .iso8601 date strategy rejects fractional seconds.
  return JSON.stringify({ format: BACKUP_FORMAT, version: BACKUP_VERSION, exportedAt: now.toISOString().replace(/\.\d{3}Z$/, 'Z'), scenes, schedules, lights,
    ...(home.dreamViewDrafts && Object.keys(home.dreamViewDrafts).length ? { dreamViewDrafts: home.dreamViewDrafts } : {}) }, null, 2);
}

const notBackup = () => new LumaError("That file isn't a Luma home backup.");

/** Display text the Mac allows longer than Luma for Windows/Linux stores: shortened, never a reason to refuse a backup. */
const fit = (v: unknown, max: number): unknown => (typeof v === 'string' ? fitText(v, max) : v);

/** Strict structural decode. Lights don't need to be connected: scenes for missing lights are kept and counted. */
export function decodeBackup(text: string): DecodedBackup {
  if (typeof text !== 'string' || text.length > BACKUP_LIMIT) throw new LumaError('That backup is too large.');
  let root: unknown;
  try { root = JSON.parse(text); } catch { throw notBackup(); }
  if (!isObject(root) || root.format !== BACKUP_FORMAT) throw notBackup();
  if (typeof root.version !== 'number' || root.version > BACKUP_VERSION) throw new LumaError("That isn't a Luma home backup this version can read.");
  if (!Array.isArray(root.scenes) || !Array.isArray(root.schedules) || !Array.isArray(root.lights)) throw notBackup();
  if (root.scenes.length > 1000 || root.schedules.length > 1000 || root.lights.length > 1000) throw notBackup();
  try {
    const scenes = root.scenes.map((raw) => {
      if (!isObject(raw)) throw notBackup();
      const icon = typeof raw.icon === 'string' && SYMBOLS[raw.icon] ? raw.icon : iconFor(typeof raw.symbol === 'string' ? raw.symbol : '');
      return decodeScene({ ...raw, icon, name: fit(raw.name, 80) || 'Scene' });
    });
    if (new Set(scenes.map((s) => s.id)).size !== scenes.length) throw notBackup();
    const schedules = root.schedules.map((raw) => { const s = decodeSchedule(raw); delete s.lastRunMinute; return s; });
    if (new Set(schedules.map((s) => s.id)).size !== schedules.length) throw notBackup();
    const lights = root.lights.map((raw): BackupLight => {
      if (!isObject(raw) || typeof raw.id !== 'string' || typeof raw.sku !== 'string' || typeof raw.room !== 'string') throw notBackup();
      const clean = (v: string, max: number) => { if (v.length > max || /[\u0000-\u001f]/.test(v)) throw notBackup(); return v; };
      const customName = fit(raw.customName, 64) as string | undefined;
      return { id: clean(raw.id, 128), sku: clean(raw.sku, 64), room: (fit(raw.room, 40) as string) || 'Unassigned', ...(customName ? { customName } : {}) };
    });
    const drafts = root.dreamViewDrafts === undefined || root.dreamViewDrafts === null ? undefined : dreamViewDrafts(root.dreamViewDrafts);
    return { scenes, schedules, lights, ...(drafts ? { dreamViewDrafts: drafts } : {}) };
  } catch (error) {
    if (error instanceof LumaError) throw error;
    throw notBackup();
  }
}

/** Replaces scenes and schedules; applies names and rooms only to lights already known (same ID and model). */
export function applyBackup(home: SavedHome, backup: DecodedBackup): BackupResult {
  const result: BackupResult = { scenes: 0, schedules: 0, lightsUpdated: 0, lightsNotFound: 0, scenesWithMissingLights: 0 };
  for (const label of backup.lights) {
    const device = home.devices.find((d) => d.id === label.id && d.sku.toLowerCase() === label.sku.toLowerCase());
    if (!device) { result.lightsNotFound++; continue; }
    device.room = label.room;
    if (label.customName) { device.customName = label.customName; device.name = label.customName; }
    else delete device.customName; // the device's own name returns on the next cloud refresh
    result.lightsUpdated++;
  }
  const sceneIDs = new Set(backup.scenes.map((s) => s.id));
  home.scenes = backup.scenes;
  home.schedules = backup.schedules.filter((s) => sceneIDs.has(s.sceneID));
  const known = new Set(home.devices.map((d) => d.id));
  // Like the native restore: drafts are replaced by the backup's, kept only for lights known here.
  const drafts = Object.entries(backup.dreamViewDrafts ?? {}).filter(([id]) => known.has(id));
  if (drafts.length) home.dreamViewDrafts = Object.fromEntries(drafts); else delete home.dreamViewDrafts;
  result.scenes = home.scenes.length;
  result.schedules = home.schedules.length;
  result.scenesWithMissingLights = home.scenes.filter((s) => s.steps.some((st) => !known.has(st.deviceID))).length;
  return result;
}

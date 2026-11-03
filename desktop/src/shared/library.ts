// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Pure helpers shared by main and the renderer: the Govee scene library (a port of the
// native GoveeSceneLibrary), room power summaries for the tray, floor-plan pin rules and
// DreamView draft limits. No DOM, Electron or Node.

import type { CapabilityCommand, FloorPlan, JSONValue, LightDevice } from './types';
import { isLight } from './devices.js';

export type SceneKind = 'lightScene' | 'diyScene' | 'snapshot';
export const SCENE_KINDS: SceneKind[] = ['lightScene', 'diyScene', 'snapshot'];
export const SCENE_KIND_TITLE: Record<SceneKind, string> = { lightScene: 'Built-in', diyScene: 'DIY', snapshot: 'Snapshot' };

/** One option from a light's scene lists, exactly as Govee's public API listed it. */
export interface SceneOption { kind: SceneKind; name: string; type: string; value: JSONValue; id: string }
/** One row in the browser: the light's own option (one light), or a kind+name across several lights. */
export interface SceneRow { kind: SceneKind; name: string; option?: SceneOption; count: number; id: string }

const obj = (v: unknown): v is { [k: string]: JSONValue } => typeof v === 'object' && v !== null && !Array.isArray(v);
const same = (a: JSONValue, b: JSONValue) => JSON.stringify(a) === JSON.stringify(b);
const fold = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

export const sceneCommand = (o: SceneOption): CapabilityCommand => ({ type: o.type, instance: o.kind, value: o.value });

/** Every scene option the light has listed so far, built-in first. Unnamed options get a placeholder; exact duplicates are dropped. */
export function sceneOptions(device: LightDevice): SceneOption[] {
  const result: SceneOption[] = [];
  for (const kind of SCENE_KINDS) {
    const cap = device.capabilities.find((c) => c.instance === kind);
    const options = obj(cap?.parameters) && Array.isArray(cap.parameters.options) ? cap.parameters.options : [];
    const seen = new Map<string, JSONValue[]>();
    options.forEach((option, index) => {
      if (!obj(option) || option.value === undefined) return;
      const trimmed = typeof option.name === 'string' ? option.name.trim() : '';
      const name = trimmed || `${SCENE_KIND_TITLE[kind]} ${index + 1}`;
      const values = seen.get(name) ?? [];
      if (values.some((v) => same(v, option.value!))) return;
      values.push(option.value); seen.set(name, values);
      result.push({ kind, name, type: cap!.type, value: option.value, id: `${kind}|${index}|${name}` });
    });
  }
  return result;
}

/** Whether the model advertises a scene list at all, loaded or not. */
export const advertisesScenes = (d: LightDevice) => d.capabilities.some((c) => (SCENE_KINDS as string[]).includes(c.instance));

/** Case- and accent-insensitive name filter; an empty query keeps everything. */
export function matchesQuery(name: string, query: string): boolean {
  const q = fold(query.trim());
  return !q || fold(name).includes(q);
}

/** The option on this light with the same kind and name (case-insensitive), for applying one name across a room. */
export function matchScene(kind: SceneKind, name: string, device: LightDevice): SceneOption | undefined {
  const n = name.toLowerCase();
  return sceneOptions(device).find((o) => o.kind === kind && o.name.toLowerCase() === n);
}

/** One row per option for a single light; one row per kind+name across several lights. */
export function sceneRows(lights: LightDevice[]): SceneRow[] {
  if (lights.length === 1) return sceneOptions(lights[0]!).map((o) => ({ kind: o.kind, name: o.name, option: o, count: 1, id: `${o.id}|one` }));
  const rows: SceneRow[] = [];
  const index = new Map<string, number>();
  for (const light of lights) {
    const seen = new Set<string>();
    for (const o of sceneOptions(light)) {
      const key = `${o.kind}|${o.name.toLowerCase()}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const i = index.get(key);
      if (i !== undefined) rows[i]!.count += 1; else { index.set(key, rows.length); rows.push({ kind: o.kind, name: o.name, count: 1, id: key }); }
    }
  }
  return rows;
}

/** Per light: the command to send, or why it is skipped (as the native room apply reports). */
export function planSceneApply(kind: SceneKind, name: string, lights: LightDevice[]): Array<{ device: LightDevice; command?: CapabilityCommand; skipped?: string }> {
  return lights.map((device) => {
    const o = matchScene(kind, name, device);
    return o ? { device, command: sceneCommand(o) } : { device, skipped: sceneOptions(device).length ? `doesn't list ${name}` : 'scenes not loaded' };
  });
}

/** Tray/menu rooms: lights with a power switch only, sorted, with how many are on (matches the Mac menu bar). */
export function roomPower(devices: LightDevice[]): Array<{ room: string; ids: string[]; on: number }> {
  const switchable = devices.filter((d) => isLight(d) && d.capabilities.some((c) => c.instance === 'powerSwitch'));
  const rooms = [...new Set(devices.filter(isLight).map((d) => d.room))].sort((a, b) => (a === 'Unassigned' ? 1 : b === 'Unassigned' ? -1 : a.localeCompare(b)));
  return rooms.map((room) => {
    const lights = switchable.filter((d) => d.room === room);
    return { room, ids: lights.map((d) => d.id), on: lights.filter((d) => d.power === true).length };
  });
}

// ---------- floor plans ----------

export const FLOOR_NAME_MAX = 64;

/** Trimmed 1–64 character floor name, or undefined (native FloorPlan rule). */
export function floorName(v: unknown): string | undefined {
  const name = typeof v === 'string' ? v.trim() : '';
  return name && name.length <= FLOOR_NAME_MAX && !/[\u0000-\u001f]/.test(name) ? name : undefined;
}

/** A physical light has one place across all floors: placing it removes it from every other floor. */
export function placePin(plans: FloorPlan[], planID: string, deviceID: string, x: number, y: number): FloorPlan[] {
  if (!deviceID || !Number.isFinite(x) || !Number.isFinite(y) || x < 0 || x > 1 || y < 0 || y > 1) throw new Error('Choose a light and a position inside the floor plan.');
  if (!plans.some((p) => p.id === planID)) throw new Error('Floor plan not found.');
  return plans.map((p) => ({ ...p, pins: [...p.pins.filter((pin) => pin.deviceID !== deviceID), ...(p.id === planID ? [{ deviceID, x, y }] : [])] }));
}

/** List order for the accessible alternative: top to bottom, then left to right. */
export const pinOrder = (plan: FloorPlan) => [...plan.pins].sort((a, b) => a.y - b.y || a.x - b.x);

// ---------- DreamView ----------

/** Member capacity per ha-govee-led-ble services.yaml; undefined for models it doesn't list (native DreamViewDraft). */
export const dreamViewMemberLimit = (sku: string): number | undefined => ({ H6199: 5, H6097: 7, H6099: 7, H66A0: 10 } as Record<string, number>)[sku.toUpperCase()];
export const DREAMVIEW_APPLY_BLOCKER = "Luma can't send this to your lights yet: it can't read which lights are in the group or their command versions, and a Bluetooth writer would also have to handle the encryption these TV backlights report supporting. Set members in Govee Home.";

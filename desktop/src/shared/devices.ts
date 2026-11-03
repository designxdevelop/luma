// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Pure device helpers shared by main and the renderer (no DOM, Electron or Node).
// Main re-validates every command these build with validateCommand before sending.

import type { Capability, CapabilityCommand, JSONValue, LightDevice } from './types';

/** Lights are the only devices bulk actions (All on, rooms, webhooks `all`/`room:`, Screen Sync) may touch. */
export const isLight = (d: Pick<LightDevice, 'deviceType'>): boolean => d.deviceType === undefined || d.deviceType === 'devices.types.light';

const obj = (v: unknown): v is { [k: string]: JSONValue } => typeof v === 'object' && v !== null && !Array.isArray(v);
const int = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v);

export const SEGMENT_INSTANCES = ['segmentedColorRgb', 'segmentedBrightness'] as const;

/** What the painter needs from a segment capability's advertised STRUCT schema. */
export interface SegmentSchema {
  type: string;
  instance: string;
  /** Advertised segment indexes, in order. */
  indexes: number[];
  /** The struct's value field (`rgb` or `brightness`) and its range. */
  valueField: string;
  valueRange: [number, number];
  /** Most segments one command may carry (the array's size.max), if advertised. */
  perCommand?: number;
}

const MAX_SEGMENTS = 256;

/** Reads a `segmentedColorRgb` / `segmentedBrightness` schema; undefined when it isn't paintable. */
export function segmentSchema(cap: Capability | undefined): SegmentSchema | undefined {
  if (!cap || !(SEGMENT_INSTANCES as readonly string[]).includes(cap.instance)) return undefined;
  const p = cap.parameters;
  if (!obj(p) || String(p.dataType).toUpperCase() !== 'STRUCT' || !Array.isArray(p.fields)) return undefined;
  const fields = p.fields.filter(obj);
  const segment = fields.find((f) => f.fieldName === 'segment');
  const value = fields.find((f) => f.fieldName !== 'segment' && String(f.dataType).toUpperCase() === 'INTEGER' && typeof f.fieldName === 'string');
  if (!segment || !value || fields.some((f) => f.required === true && f !== segment && f !== value)) return undefined;
  let indexes: number[] = [];
  const er = segment.elementRange;
  if (obj(er) && int(er.min) && int(er.max) && er.min >= 0 && er.max >= er.min && er.max - er.min < MAX_SEGMENTS) {
    for (let i = er.min; i <= er.max; i++) indexes.push(i);
  } else if (Array.isArray(segment.options)) {
    indexes = [...new Set(segment.options.filter(obj).map((o) => o.value).filter(int))].sort((a, b) => a - b).slice(0, MAX_SEGMENTS);
  }
  if (indexes.length === 0) return undefined;
  const range = obj(value.range) ? value.range : {};
  const fallback: [number, number] = value.fieldName === 'rgb' ? [0, 0xffffff] : [0, 100];
  const lo = int(range.min) ? range.min : fallback[0], hi = int(range.max) ? range.max : fallback[1];
  const size = obj(segment.size) ? segment.size : {};
  return {
    type: cap.type, instance: cap.instance, indexes, valueField: value.fieldName as string,
    valueRange: lo <= hi ? [lo, hi] : fallback,
    ...(int(size.max) && size.max > 0 ? { perCommand: size.max } : {}),
  };
}

/**
 * Turns painted segments into the fewest commands: one per distinct value, segments
 * ascending, split at the advertised per-command limit. Ordered by first segment so the
 * same painting always yields the same commands. Throws on a value or index the schema doesn't allow.
 */
export function paintCommands(schema: SegmentSchema, paint: ReadonlyMap<number, number>): CapabilityCommand[] {
  const groups = new Map<number, number[]>();
  const allowed = new Set(schema.indexes);
  for (const [index, value] of paint) {
    if (!allowed.has(index)) throw new Error(`Segment ${index} isn't on this light.`);
    if (!int(value) || value < schema.valueRange[0] || value > schema.valueRange[1]) throw new Error(`${schema.valueField} must be ${schema.valueRange[0]}…${schema.valueRange[1]}.`);
    groups.set(value, [...(groups.get(value) ?? []), index]);
  }
  const commands: CapabilityCommand[] = [];
  for (const [value, indexes] of groups) {
    indexes.sort((a, b) => a - b);
    const chunk = schema.perCommand ?? indexes.length;
    for (let i = 0; i < indexes.length; i += chunk) {
      commands.push({ type: schema.type, instance: schema.instance, value: { segment: indexes.slice(i, i + chunk), [schema.valueField]: value } });
    }
  }
  const first = (c: CapabilityCommand) => ((c.value as { segment: number[] }).segment[0] ?? 0);
  return commands.sort((a, b) => first(a) - first(b));
}

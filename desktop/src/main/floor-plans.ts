// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Floor plans, stored like the native app: floor-plans/plans.json plus one <UUID>.png per floor.
// Images are re-encoded by the caller (metadata such as GPS is dropped). A plans.json that
// can't be read is preserved: nothing is saved over it. Demo mode keeps everything in memory.

import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { FloorPlan } from '../shared/types';
import { floorName, placePin } from '../shared/library';
import { LumaError } from '../core/model';

export const FLOOR_IMAGE_LIMIT = 20 * 1024 * 1024;
const PLANS_LIMIT = 4 * 1024 * 1024;

/** Turns any supported image into PNG bytes no larger than 4096 px on the long side; undefined when it isn't an image. */
export type ImageEncoder = (data: Buffer) => Buffer | undefined;

const unreadable = () => new LumaError('Existing floor plans could not be read and have been preserved.');

/** Strict decode of native plans.json: any invalid floor or pin rejects the whole file. */
export function decodePlans(v: unknown): FloorPlan[] {
  if (!Array.isArray(v) || v.length > 100) throw unreadable();
  const plans = v.map((p): FloorPlan => {
    if (typeof p !== 'object' || p === null || typeof p.id !== 'string' || !/^[0-9A-Fa-f-]{36}$/.test(p.id) || !Array.isArray(p.pins) || p.pins.length > 1000) throw unreadable();
    const name = floorName(p.name);
    if (!name) throw unreadable();
    const pins = p.pins.map((pin: unknown) => {
      const q = pin as { deviceID?: unknown; x?: unknown; y?: unknown };
      if (typeof q?.deviceID !== 'string' || !q.deviceID || q.deviceID.length > 128 || typeof q.x !== 'number' || typeof q.y !== 'number'
        || !(q.x >= 0 && q.x <= 1) || !(q.y >= 0 && q.y <= 1)) throw unreadable();
      return { deviceID: q.deviceID, x: q.x, y: q.y };
    });
    return { id: p.id.toUpperCase(), name, pins };
  });
  if (new Set(plans.map((p) => p.id)).size !== plans.length) throw unreadable();
  return plans;
}

export class FloorPlanStore {
  private plans: FloorPlan[] = [];
  private versions = new Map<string, number>();
  private memory = new Map<string, Buffer>();
  writable = true;

  constructor(private readonly folder: string | undefined, private readonly encode: ImageEncoder) {
    if (!folder) return;
    const file = join(folder, 'plans.json');
    if (!existsSync(file)) return;
    try {
      const text = readFileSync(file, 'utf8');
      if (text.length > PLANS_LIMIT) throw unreadable();
      this.plans = decodePlans(JSON.parse(text));
    } catch { this.writable = false; }
  }

  list(): Array<FloorPlan & { imageVersion: number }> {
    return this.plans.map((p) => ({ ...p, pins: p.pins.map((pin) => ({ ...pin })), imageVersion: this.versions.get(p.id) ?? 0 }));
  }

  add(image: Buffer): string {
    const id = randomUUID().toUpperCase();
    this.writeImage(id, image);
    try { this.commit([...this.plans, { id, name: this.nextName(), pins: [] }]); } catch (error) { this.removeImage(id); throw error; }
    return id;
  }

  /** Pins keep their positions: a replacement is the same floor with a new picture. */
  replace(id: string, image: Buffer): void {
    this.find(id);
    if (!this.writable) throw unreadable();
    this.writeImage(id, image);
  }

  rename(id: string, name: unknown): void {
    const label = floorName(name);
    if (!label) throw new LumaError('Name the floor plan using 1–64 characters.');
    this.find(id);
    this.commit(this.plans.map((p) => (p.id === id ? { ...p, name: label } : p)));
  }

  place(id: string, deviceID: string, x: unknown, y: unknown): void {
    try { this.commit(placePin(this.plans, id, deviceID, Number(x), Number(y))); }
    catch (error) { throw error instanceof LumaError ? error : new LumaError(error instanceof Error ? error.message : String(error)); }
  }

  removePin(id: string, deviceID: string): void {
    this.find(id);
    this.commit(this.plans.map((p) => (p.id === id ? { ...p, pins: p.pins.filter((pin) => pin.deviceID !== deviceID) } : p)));
  }

  delete(id: string): void {
    this.find(id);
    this.commit(this.plans.filter((p) => p.id !== id));
    this.removeImage(id);
  }

  image(id: string): Buffer | undefined {
    this.find(id);
    if (!this.folder) return this.memory.get(id);
    try { return readFileSync(join(this.folder, `${id}.png`)); } catch { return undefined; }
  }

  private find(id: string): FloorPlan {
    const plan = this.plans.find((p) => p.id === id);
    if (!plan) throw new LumaError('Floor plan not found.');
    return plan;
  }

  private nextName(): string {
    for (let n = this.plans.length + 1; ; n++) if (!this.plans.some((p) => p.name === `Floor ${n}`)) return `Floor ${n}`;
  }

  private writeImage(id: string, data: Buffer): void {
    if (!this.writable) throw unreadable();
    if (data.length === 0 || data.length > FLOOR_IMAGE_LIMIT) throw new LumaError('Choose an image smaller than 20 MB.');
    const png = this.encode(data);
    if (!png) throw new LumaError('That file isn\'t an image Luma can read. Choose a PNG or JPEG.');
    this.versions.set(id, (this.versions.get(id) ?? 0) + 1);
    if (!this.folder) { this.memory.set(id, png); return; }
    this.atomic(join(this.folder, `${id}.png`), png);
  }

  private removeImage(id: string): void {
    this.memory.delete(id);
    if (this.folder) { try { unlinkSync(join(this.folder, `${id}.png`)); } catch { /* already gone */ } }
  }

  private commit(plans: FloorPlan[]): void {
    if (!this.writable) throw unreadable();
    // Swift's JSONEncoder writes the same keys; UUIDs stay uppercase as Swift encodes them.
    if (this.folder) this.atomic(join(this.folder, 'plans.json'), Buffer.from(JSON.stringify(plans, null, 2)));
    this.plans = plans;
  }

  private atomic(file: string, data: Buffer): void {
    mkdirSync(this.folder!, { recursive: true, mode: 0o700 });
    const temp = `${file}.${randomUUID()}.tmp`;
    try { writeFileSync(temp, data, { mode: 0o600, flag: 'wx' }); renameSync(temp, file); }
    finally { if (existsSync(temp)) unlinkSync(temp); }
  }
}

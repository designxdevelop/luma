// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Platform-neutral Screen Sync math. Pure functions only (no DOM, Electron or Node):
// compiled as CommonJS for main/tests and as an ES module for the renderer worker.
// Colors are averaged in linear light from sRGB 8-bit samples. HDR sources arrive
// tone-mapped to SDR by the capture stack, so results are an SDR approximation.

import type { SyncRegion, SyncSettings } from './types';

export type LinearRGB = [number, number, number];
export type RegionSamples = Record<SyncRegion, LinearRGB>;
export interface Bands { top: number; bottom: number; left: number; right: number }
export interface LightTarget { rgb: number; brightness: number }

export const REGIONS: readonly SyncRegion[] = ['full', 'left', 'right', 'top', 'bottom'];

export const DEFAULT_SYNC_SETTINGS: SyncSettings = { smoothing: 0.6, threshold: 0.03, brightnessCap: 80, updateHz: 2, restore: false };
/** Inclusive bounds; updateHz is a per-light LAN cap (Govee LAN is unacknowledged UDP). */
export const SYNC_LIMITS = { smoothing: [0, 0.95], threshold: [0.005, 0.2], brightnessCap: [1, 100], updateHz: [0.5, 5] } as const;

const LINEAR = Array.from({ length: 256 }, (_, i) => {
  const c = i / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
});

export function srgbToLinear(c8: number): number { return LINEAR[Math.max(0, Math.min(255, Math.round(c8)))]!; }

/** Linear 0…1 → sRGB 0…255 (unrounded). */
export function linearToSrgb(l: number): number {
  const c = Math.max(0, Math.min(1, l));
  return 255 * (c <= 0.0031308 ? c * 12.92 : 1.055 * c ** (1 / 2.4) - 0.055);
}

/** Near-black: no channel above this 8-bit value (tolerates encoder noise). */
const DARK = 24;
/** A row/column is a bar when at most 2% of its pixels are brighter than DARK. */
const BAR_TOLERANCE = 0.02;
/** Bars never take more than this share of a side; a 2.76:1 film in 16:9 uses ~18%. */
const MAX_BAR = 0.25;

function lineIsDark(px: ArrayLike<number>, start: number, step: number, count: number): boolean {
  let bright = 0;
  const allowed = Math.floor(count * BAR_TOLERANCE);
  for (let i = 0, o = start; i < count; i++, o += step) {
    if (px[o]! > DARK || px[o + 1]! > DARK || px[o + 2]! > DARK) { if (++bright > allowed) return false; }
  }
  return true;
}

/**
 * Contiguous black bars at the edges (letterbox / pillarbox). Bars must be symmetric
 * (the smaller side wins), so a dark sky at the top of a scene is not cropped, and an
 * entirely dark frame is a dark scene rather than all bars.
 */
export function letterbox(px: ArrayLike<number>, w: number, h: number): Bands {
  const rowDark = (y: number) => lineIsDark(px, y * w * 4, 4, w);
  const colDark = (x: number) => lineIsDark(px, x * 4, w * 4, h);
  const scan = (dark: (i: number) => boolean, from: number, dir: number, limit: number) => {
    let n = 0;
    while (n < limit && dark(from + dir * n)) n++;
    return n;
  };
  const maxRows = Math.floor(h * MAX_BAR), maxCols = Math.floor(w * MAX_BAR);
  let allDark = true;
  for (let y = 0; y < h && allDark; y++) allDark = rowDark(y);
  if (allDark) return { top: 0, bottom: 0, left: 0, right: 0 };
  const v = Math.min(scan(rowDark, 0, 1, maxRows), scan(rowDark, h - 1, -1, maxRows));
  const hz = Math.min(scan(colDark, 0, 1, maxCols), scan(colDark, w - 1, -1, maxCols));
  return { top: v, bottom: v, left: hz, right: hz };
}

/** Average linear color of the picture (bars removed) and of its left/right/top/bottom thirds. */
export function regionAverages(px: ArrayLike<number>, w: number, h: number, bands: Bands = letterbox(px, w, h)): RegionSamples {
  const x0 = bands.left, x1 = w - bands.right, y0 = bands.top, y1 = h - bands.bottom;
  const iw = x1 - x0, ih = y1 - y0;
  const sums = { full: [0, 0, 0, 0], left: [0, 0, 0, 0], right: [0, 0, 0, 0], top: [0, 0, 0, 0], bottom: [0, 0, 0, 0] } as Record<SyncRegion, number[]>;
  const lx = x0 + iw / 3, rx = x0 + (2 * iw) / 3, ty = y0 + ih / 3, by = y0 + (2 * ih) / 3;
  const add = (s: number[], r: number, g: number, b: number) => { s[0]! += r; s[1]! += g; s[2]! += b; s[3]! += 1; };
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const o = (y * w + x) * 4;
      const r = LINEAR[px[o]!]!, g = LINEAR[px[o + 1]!]!, b = LINEAR[px[o + 2]!]!;
      add(sums.full, r, g, b);
      if (x < lx) add(sums.left, r, g, b);
      if (x >= rx) add(sums.right, r, g, b);
      if (y < ty) add(sums.top, r, g, b);
      if (y >= by) add(sums.bottom, r, g, b);
    }
  }
  const avg = (s: number[]): LinearRGB => (s[3]! > 0 ? [s[0]! / s[3]!, s[1]! / s[3]!, s[2]! / s[3]!] : [0, 0, 0]);
  return { full: avg(sums.full), left: avg(sums.left), right: avg(sums.right), top: avg(sums.top), bottom: avg(sums.bottom) };
}

/** Exponential smoothing in linear light. `smoothing` 0 follows instantly; 0.95 is very slow. Per frame, so it scales with frame rate. */
export function smooth(previous: LinearRGB | undefined, next: LinearRGB, smoothing: number): LinearRGB {
  if (!previous) return [...next];
  const a = 1 - smoothing;
  return [previous[0] + a * (next[0] - previous[0]), previous[1] + a * (next[1] - previous[1]), previous[2] + a * (next[2] - previous[2])];
}

/**
 * Light command values: full-saturation hue (the brightest channel at 255) plus a
 * brightness from the brightest channel, scaled by the cap (never below 1%).
 * Black keeps a neutral color at 1% so lights never turn off.
 */
export function toTarget(color: LinearRGB, brightnessCap: number): LightTarget {
  const cap = Math.max(1, Math.min(100, Math.round(brightnessCap)));
  const m = Math.max(color[0], color[1], color[2]);
  if (!(m > 1 / 4096)) return { rgb: 0xffffff, brightness: 1 };
  const c = color.map((v) => Math.round(linearToSrgb(v / m))) as LinearRGB;
  const brightness = Math.max(1, Math.min(cap, Math.round((cap * linearToSrgb(m)) / 255)));
  return { rgb: (c[0] << 16) | (c[1] << 8) | c[2], brightness };
}

/** Dead band: only changes at least `threshold` (0…1) of the channel/brightness range are sent. */
export function exceedsThreshold(previous: LightTarget | undefined, next: LightTarget, threshold: number): boolean {
  if (!previous) return true;
  const ch = (v: number, s: number) => (v >> s) & 255;
  const dc = Math.max(...[16, 8, 0].map((s) => Math.abs(ch(previous.rgb, s) - ch(next.rgb, s))));
  return dc >= Math.max(1, threshold * 255) || Math.abs(previous.brightness - next.brightness) >= Math.max(1, threshold * 100);
}

/** Merges a partial settings update; every present field must be finite and in range. */
export function validateSettings(input: unknown, base: SyncSettings): SyncSettings {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) throw new Error('Invalid Screen Sync settings.');
  const next = { ...base };
  for (const [key, value] of Object.entries(input)) {
    if (key === 'restore') {
      if (typeof value !== 'boolean') throw new Error('Invalid Screen Sync settings.');
      next.restore = value;
      continue;
    }
    const range = (SYNC_LIMITS as Record<string, readonly [number, number]>)[key];
    if (!range || typeof value !== 'number' || !Number.isFinite(value) || value < range[0] || value > range[1]) throw new Error(`Invalid Screen Sync setting: ${key.slice(0, 32)}.`);
    (next as unknown as Record<string, number>)[key] = value;
  }
  return next;
}

/** Strict shape for frame samples crossing IPC: exactly the five regions, three finite values in [0, 1] each. */
export function validateSamples(input: unknown): RegionSamples {
  const invalid = () => new Error('Invalid frame samples.');
  if (typeof input !== 'object' || input === null || Array.isArray(input)) throw invalid();
  const keys = Object.keys(input);
  if (keys.length !== REGIONS.length || !REGIONS.every((r) => keys.includes(r))) throw invalid();
  const out = {} as RegionSamples;
  for (const r of REGIONS) {
    const v = (input as Record<string, unknown>)[r];
    if (!Array.isArray(v) || v.length !== 3 || !v.every((n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1)) throw invalid();
    out[r] = [v[0], v[1], v[2]];
  }
  return out;
}

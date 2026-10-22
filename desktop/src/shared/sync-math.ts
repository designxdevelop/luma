// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Platform-neutral Screen Sync math. Pure functions only (no DOM, Electron or Node):
// compiled as CommonJS for main/tests and as an ES module for the renderer worker.
// Colors are averaged in linear light from sRGB 8-bit samples. HDR sources arrive
// tone-mapped to SDR by the capture stack, so results are an SDR approximation.

import type { SyncGrid, SyncRegion, SyncSettings } from './types';

export type LinearRGB = [number, number, number];
export type RegionSamples = Record<SyncRegion, LinearRGB>;
export interface Bands { top: number; bottom: number; left: number; right: number }
export interface LightTarget { rgb: number; brightness: number }

export const REGIONS: readonly SyncRegion[] = [
  'full', 'left', 'right', 'top', 'bottom',
  'edgeLeft', 'edgeRight', 'edgeTop', 'edgeBottom',
  'cornerTopLeft', 'cornerTopRight', 'cornerBottomLeft', 'cornerBottomRight',
  'edgeLeftUpper', 'edgeLeftLower', 'edgeRightUpper', 'edgeRightLower',
  'edgeTopLeft', 'edgeTopRight', 'edgeBottomLeft', 'edgeBottomRight',
];

export const DEFAULT_SYNC_SETTINGS: SyncSettings = { smoothing: 0.4, threshold: 0.02, brightnessCap: 80, updateHz: 5, edgeDepth: 0.15, vivid: false, restore: false };
/**
 * Inclusive bounds; updateHz is a per-light LAN cap. Govee LAN is unacknowledged UDP:
 * sends are latest-only with no retries, so a dropped datagram is replaced, never queued.
 */
export const SYNC_LIMITS = { smoothing: [0, 0.95], threshold: [0.005, 0.2], brightnessCap: [1, 100], updateHz: [0.5, 10], edgeDepth: [0.05, 0.33] } as const;
/** `smoothing` is the share kept per this many seconds, so feel doesn't depend on frame rate. */
export const SMOOTHING_STEP_S = 0.1;
/** A jump of this share of the sRGB range (any channel) bypasses smoothing entirely. */
export const JUMP_RELEASE = 0.25;

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

/** Area as fractions of the cropped picture: [x0, x1, y0 (top), y1]. Edges, corners and half edges are `d` deep. */
export function regionRect(region: SyncRegion, d: number): [number, number, number, number] {
  const t = 1 / 3, n = 1 - d;
  switch (region) {
    case 'full': return [0, 1, 0, 1];
    case 'left': return [0, t, 0, 1];
    case 'right': return [1 - t, 1, 0, 1];
    case 'top': return [0, 1, 0, t];
    case 'bottom': return [0, 1, 1 - t, 1];
    case 'edgeLeft': return [0, d, 0, 1];
    case 'edgeRight': return [n, 1, 0, 1];
    case 'edgeTop': return [0, 1, 0, d];
    case 'edgeBottom': return [0, 1, n, 1];
    case 'cornerTopLeft': return [0, d, 0, d];
    case 'cornerTopRight': return [n, 1, 0, d];
    case 'cornerBottomLeft': return [0, d, n, 1];
    case 'cornerBottomRight': return [n, 1, n, 1];
    case 'edgeLeftUpper': return [0, d, 0, 0.5];
    case 'edgeLeftLower': return [0, d, 0.5, 1];
    case 'edgeRightUpper': return [n, 1, 0, 0.5];
    case 'edgeRightLower': return [n, 1, 0.5, 1];
    case 'edgeTopLeft': return [0, 0.5, 0, d];
    case 'edgeTopRight': return [0.5, 1, 0, d];
    case 'edgeBottomLeft': return [0, 0.5, n, 1];
    case 'edgeBottomRight': return [0.5, 1, n, 1];
  }
}

export const GRID_MAX_COLUMNS = 30, GRID_MAX_ROWS = 18, GRID_VALUES = 8;
/** Every pixel counts at least this much in vivid mode, so gray scenes still have a color. */
const VIVID_FLOOR = 0.05;
const MAX_PIXELS = 1 << 20;

/**
 * Reduces an RGBA frame (bars cropped) to a grid of linear-light sums. Pixel p falls in cell
 * floor(p * cells / size), so with 30×18 cells the thirds land on exact pixel boundaries.
 */
export function sampleGrid(px: ArrayLike<number>, w: number, h: number, bands: Bands = letterbox(px, w, h)): SyncGrid {
  const x0 = bands.left, iw = w - bands.right - x0, y0 = bands.top, ih = h - bands.bottom - y0;
  const columns = Math.min(GRID_MAX_COLUMNS, iw), rows = Math.min(GRID_MAX_ROWS, ih);
  const cellX = Array.from({ length: iw }, (_, x) => Math.floor((x * columns) / iw) * GRID_VALUES);
  const cells = new Array<number>(columns * rows * GRID_VALUES).fill(0);
  for (let y = 0; y < ih; y++) {
    const cellRow = Math.floor((y * rows) / ih) * columns * GRID_VALUES;
    for (let x = 0; x < iw; x++) {
      const o = ((y0 + y) * w + x0 + x) * 4, r8 = px[o]!, g8 = px[o + 1]!, b8 = px[o + 2]!;
      const r = LINEAR[r8]!, g = LINEAR[g8]!, b = LINEAR[b8]!;
      const chroma = (Math.max(r8, g8, b8) - Math.min(r8, g8, b8)) / 255, wt = VIVID_FLOOR + chroma * chroma;
      const i = cellRow + cellX[x]!;
      cells[i]! += 1; cells[i + 1]! += r; cells[i + 2]! += g; cells[i + 3]! += b;
      cells[i + 4]! += wt; cells[i + 5]! += wt * r; cells[i + 6]! += wt * g; cells[i + 7]! += wt * b;
    }
  }
  return { columns, rows, cells };
}

/** Cell index range covering the fraction a..b of n cells; never empty. */
function span(a: number, b: number, n: number): [number, number] {
  const lo = Math.min(Math.round(a * n), n - 1);
  return [lo, Math.max(lo + 1, Math.min(Math.round(b * n), n))];
}

/** One region's linear color, plain average or vivid-weighted. */
export function gridColor(grid: SyncGrid, region: SyncRegion, depth: number, vivid: boolean): LinearRGB {
  const [rx0, rx1, ry0, ry1] = regionRect(region, depth);
  const [cx0, cx1] = span(rx0, rx1, grid.columns), [cy0, cy1] = span(ry0, ry1, grid.rows);
  const s = new Array<number>(GRID_VALUES).fill(0);
  for (let y = cy0; y < cy1; y++) {
    for (let x = cx0; x < cx1; x++) {
      const o = (y * grid.columns + x) * GRID_VALUES;
      for (let i = 0; i < GRID_VALUES; i++) s[i]! += grid.cells[o + i]!;
    }
  }
  const [n, base] = vivid ? [s[4]!, 5] : [s[0]!, 1];
  return n > 0 ? [s[base]! / n, s[base + 1]! / n, s[base + 2]! / n] : [0, 0, 0];
}

export function gridColors(grid: SyncGrid, depth = DEFAULT_SYNC_SETTINGS.edgeDepth, vivid = false): RegionSamples {
  return Object.fromEntries(REGIONS.map((r) => [r, gridColor(grid, r, depth, vivid)])) as RegionSamples;
}

/**
 * Exponential smoothing in linear light, normalized to elapsed `dtS` seconds. `smoothing` 0
 * follows instantly; 0.95 is very slow. Smoothing eases off in proportion to the jump (measured
 * in sRGB, so dark scenes count), so scene cuts land at once while small noise stays filtered.
 */
export function smooth(previous: LinearRGB | undefined, next: LinearRGB, smoothing: number, dtS = SMOOTHING_STEP_S): LinearRGB {
  if (!previous) return [...next];
  const jump = Math.max(...[0, 1, 2].map((i) => Math.abs(linearToSrgb(next[i]!) - linearToSrgb(previous[i]!)))) / 255;
  const s = Math.max(0, Math.min(1, smoothing)) * Math.max(0, 1 - jump / JUMP_RELEASE);
  const a = 1 - s ** (Math.max(0.001, Math.min(1, Number.isFinite(dtS) ? dtS : SMOOTHING_STEP_S)) / SMOOTHING_STEP_S);
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
    if (key === 'restore' || key === 'vivid') {
      if (typeof value !== 'boolean') throw new Error('Invalid Screen Sync settings.');
      next[key] = value;
      continue;
    }
    const range = (SYNC_LIMITS as Record<string, readonly [number, number]>)[key];
    if (!range || typeof value !== 'number' || !Number.isFinite(value) || value < range[0] || value > range[1]) throw new Error(`Invalid Screen Sync setting: ${key.slice(0, 32)}.`);
    (next as unknown as Record<string, number>)[key] = value;
  }
  return next;
}

/** Strict shape for a frame grid crossing IPC: bounded size, and every cell's sums consistent with its pixel count. */
export function validateGrid(input: unknown): SyncGrid {
  const invalid = () => new Error('Invalid frame grid.');
  if (typeof input !== 'object' || input === null || Array.isArray(input)) throw invalid();
  const { columns, rows, cells } = input as Record<string, unknown>;
  if (Object.keys(input).length !== 3 || !Number.isInteger(columns) || !Number.isInteger(rows)) throw invalid();
  const c = columns as number, r = rows as number;
  if (c < 1 || c > GRID_MAX_COLUMNS || r < 1 || r > GRID_MAX_ROWS || !Array.isArray(cells) || cells.length !== c * r * GRID_VALUES) throw invalid();
  for (let o = 0; o < cells.length; o += GRID_VALUES) {
    const v = cells.slice(o, o + GRID_VALUES);
    if (!v.every((x) => typeof x === 'number' && Number.isFinite(x) && x >= 0)) throw invalid();
    const n = v[0] as number, wt = v[4] as number, eps = 1e-6 * Math.max(1, n);
    if (!Number.isInteger(n) || n < 1 || n > MAX_PIXELS || wt > (1 + VIVID_FLOOR) * n + eps) throw invalid();
    if (v.slice(1, 4).some((x) => (x as number) > n + eps) || v.slice(5).some((x) => (x as number) > wt + eps)) throw invalid();
  }
  return { columns: c, rows: r, cells: cells as number[] };
}

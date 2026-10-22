// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_SYNC_SETTINGS, REGIONS, exceedsThreshold, gridColor, gridColors, letterbox, linearToSrgb, sampleGrid, smooth, srgbToLinear,
  toTarget, validateGrid, validateSettings, type LinearRGB,
} from '../shared/sync-math';

const regionAverages = (px: ArrayLike<number>, w: number, h: number) => gridColors(sampleGrid(px, w, h));

type Rgb = readonly [number, number, number];

/** RGBA pixel buffer from a per-pixel color function. */
function image(w: number, h: number, color: (x: number, y: number) => Rgb): Uint8ClampedArray {
  const px = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const [r, g, b] = color(x, y);
      px.set([r, g, b, 255], (y * w + x) * 4);
    }
  }
  return px;
}

const near = (actual: number, expected: number, eps = 1e-9) =>
  assert.ok(Math.abs(actual - expected) <= eps, `${actual} is not within ${eps} of ${expected}`);

test('sRGB <-> linear: known values and round-trip', () => {
  assert.equal(srgbToLinear(0), 0);
  assert.equal(srgbToLinear(255), 1);
  near(srgbToLinear(128), 0.2158605, 1e-6);
  assert.equal(srgbToLinear(300), 1);
  assert.equal(srgbToLinear(-5), 0);
  near(linearToSrgb(0.5), 187.5, 0.1);
  near(linearToSrgb(2), 255);
  assert.equal(linearToSrgb(-1), 0);
  for (let i = 0; i < 256; i++) near(linearToSrgb(srgbToLinear(i)), i, 1e-6);
});

test('regionAverages averages in linear light, not sRGB', () => {
  const px = image(100, 100, (x) => (x < 50 ? [0, 0, 0] : [255, 255, 255]));
  const { full } = regionAverages(px, 100, 100);
  for (const c of full) near(c, 0.5, 1e-9);
  // The perceptual midpoint (~188) is far from the naive sRGB average (127.5).
  assert.ok(Math.abs(linearToSrgb(full[0]) - 127.5) > 50);
});

test('letterbox detects symmetric bars using the smaller side', () => {
  const px = image(100, 100, (_x, y) => (y < 8 || y >= 88 ? [0, 0, 0] : [128, 128, 128]));
  assert.deepEqual(letterbox(px, 100, 100), { top: 8, bottom: 8, left: 0, right: 0 });
});

test('letterbox detects pillarbox bars', () => {
  const px = image(100, 60, (x) => (x < 15 || x >= 85 ? [0, 0, 0] : [128, 128, 128]));
  assert.deepEqual(letterbox(px, 100, 60), { top: 0, bottom: 0, left: 15, right: 15 });
});

test('letterbox does not over-crop an asymmetric dark top (dark sky)', () => {
  const px = image(100, 100, (_x, y) => (y < 20 ? [0, 0, 0] : [128, 128, 128]));
  assert.deepEqual(letterbox(px, 100, 100), { top: 0, bottom: 0, left: 0, right: 0 });
});

test('letterbox: a fully dark frame is a dark scene, not all bars', () => {
  assert.deepEqual(letterbox(image(40, 40, () => [0, 0, 0]), 40, 40), { top: 0, bottom: 0, left: 0, right: 0 });
  assert.deepEqual(letterbox(image(40, 40, () => [20, 20, 20]), 40, 40), { top: 0, bottom: 0, left: 0, right: 0 });
});

test('letterbox tolerates noisy bar pixels (<=2% bright, near-black)', () => {
  const px = image(100, 100, (x, y) => {
    if (y < 10 || y >= 90) return x === 3 || x === 70 ? [60, 60, 60] : [12, 12, 12];
    return [128, 128, 128];
  });
  assert.deepEqual(letterbox(px, 100, 100), { top: 10, bottom: 10, left: 0, right: 0 });
});

test('letterbox caps bars at 25% of each side', () => {
  const px = image(100, 100, (_x, y) => (y < 40 || y >= 60 ? [0, 0, 0] : [128, 128, 128]));
  assert.deepEqual(letterbox(px, 100, 100), { top: 25, bottom: 25, left: 0, right: 0 });
});

test('regionAverages picks the right thirds of the cropped picture', () => {
  // 90x90 picture inside 10-row bars: R lit in the left third, G lit in the top third.
  const w = 90, h = 110;
  const px = image(w, h, (x, y) => {
    if (y < 10 || y >= 100) return [0, 0, 0];
    return [x < 30 ? 255 : 0, y - 10 < 30 ? 255 : 0, 0];
  });
  const r = regionAverages(px, w, h);
  const third = 1 / 3;
  const expected: Record<string, LinearRGB> = {
    full: [third, third, 0], left: [1, third, 0], right: [0, third, 0], top: [third, 1, 0], bottom: [third, 0, 0],
  };
  for (const region of ['full', 'left', 'right', 'top', 'bottom'] as const) {
    expected[region]!.forEach((v, i) => near(r[region][i]!, v, 1e-9));
  }
});

test('smooth: 0 follows instantly, noise keeps the smoothing, no previous copies next', () => {
  const next: LinearRGB = [0.501, 0.5, 0.5];
  const moved = (c: LinearRGB) => (c[0] - 0.5) / 0.001;
  assert.deepEqual(smooth(undefined, next, 0.9), next);
  assert.notEqual(smooth(undefined, next, 0.9), next);
  assert.deepEqual(smooth([0.5, 0.5, 0.5], next, 0), next);
  assert.ok(Math.abs(moved(smooth([0.5, 0.5, 0.5], next, 0.5)) - 0.5) < 0.01);
});

test('smooth: normalized to elapsed time, so feel does not depend on frame rate', () => {
  const moved = (dt: number) => (smooth([0.5, 0.5, 0.5], [0.501, 0.5, 0.5], 0.5, dt)[0] - 0.5) / 0.001;
  assert.ok(Math.abs(moved(0.2) - 0.75) < 0.01);
  assert.ok(Math.abs(moved(0.05) - (1 - Math.sqrt(0.5))) < 0.01);
  assert.equal(moved(NaN), moved(0.1));
});

test('smooth: large jumps bypass smoothing; mid-sized jumps ease off partway', () => {
  assert.deepEqual(smooth([0.01, 0.01, 0.01], [0.8, 0.2, 0.1], 0.95), [0.8, 0.2, 0.1]);
  const moved = (smooth([0.2, 0.2, 0.2], [0.25, 0.2, 0.2], 0.5)[0] - 0.2) / 0.05;
  assert.ok(moved > 0.55 && moved < 1, String(moved));
});

test('toTarget: full-saturation hue, brightness scaled by cap, floor of 1, black neutral', () => {
  assert.deepEqual(toTarget([1, 0, 0], 80), { rgb: 0xff0000, brightness: 80 });
  assert.deepEqual(toTarget([1, 1, 1], 200), { rgb: 0xffffff, brightness: 100 });
  const half = Math.round(linearToSrgb(0.5));
  assert.deepEqual(toTarget([0.5, 0.25, 0], 80), { rgb: (255 << 16) | (half << 8), brightness: 59 });
  assert.deepEqual(toTarget([0.0003, 0, 0], 80), { rgb: 0xff0000, brightness: 1 });
  assert.deepEqual(toTarget([0, 0, 0], 80), { rgb: 0xffffff, brightness: 1 });
});

test('exceedsThreshold: dead band on color and brightness; no previous sends', () => {
  const prev = { rgb: 0x808080, brightness: 50 };
  assert.equal(exceedsThreshold(undefined, prev, 0.03), true);
  assert.equal(exceedsThreshold(prev, prev, 0.03), false);
  // threshold 0.03 -> 7.65 color levels, 3 brightness points
  assert.equal(exceedsThreshold(prev, { rgb: 0x878080, brightness: 50 }, 0.03), false); // 7
  assert.equal(exceedsThreshold(prev, { rgb: 0x888080, brightness: 50 }, 0.03), true); // 8
  assert.equal(exceedsThreshold(prev, { rgb: 0x808080, brightness: 52 }, 0.03), false);
  assert.equal(exceedsThreshold(prev, { rgb: 0x808080, brightness: 47 }, 0.03), true);
});

test('validateSettings merges partial updates and accepts inclusive bounds', () => {
  assert.deepEqual(validateSettings({}, DEFAULT_SYNC_SETTINGS), DEFAULT_SYNC_SETTINGS);
  assert.deepEqual(validateSettings({ updateHz: 3, restore: true, vivid: true, edgeDepth: 0.2 }, DEFAULT_SYNC_SETTINGS), { ...DEFAULT_SYNC_SETTINGS, updateHz: 3, restore: true, vivid: true, edgeDepth: 0.2 });
  assert.doesNotThrow(() => validateSettings({ smoothing: 0, threshold: 0.2, brightnessCap: 1, updateHz: 0.5 }, DEFAULT_SYNC_SETTINGS));
  assert.deepEqual(DEFAULT_SYNC_SETTINGS.restore, false); // base is never mutated
});

test('validateSettings rejects bad values, unknown keys and bad roots', () => {
  const bad: unknown[] = [
    { smoothing: NaN }, { smoothing: Infinity }, { smoothing: 0.96 }, { smoothing: -0.1 }, { smoothing: '0.5' },
    { threshold: 0.001 }, { threshold: 0.3 }, { brightnessCap: 0 }, { brightnessCap: 101 }, { updateHz: 11 }, { updateHz: 0.1 }, { edgeDepth: 0.04 }, { edgeDepth: 0.34 }, { vivid: 1 },
    { bogus: 1 }, { restore: 'yes' }, { restore: 1 }, null, [], 'x', 5,
  ];
  for (const input of bad) assert.throws(() => validateSettings(input, DEFAULT_SYNC_SETTINGS), /Invalid Screen Sync/, JSON.stringify(input));
});

test('validateGrid accepts consistent bounded grids and rejects everything else', () => {
  const good = () => ({ columns: 2, rows: 1, cells: [4, 1, 2, 3, 0.4, 0.1, 0.2, 0.3, 1, 0, 0, 0, 1.05, 0, 0, 0] });
  assert.deepEqual(validateGrid(good()), good());
  const g = sampleGrid(image(96, 54, (x) => (x < 48 ? [255, 0, 0] : [0, 0, 255])), 96, 54);
  assert.deepEqual(validateGrid(g), g);
  const mutate = (fn: (o: { columns: unknown; rows: unknown; cells: any; [k: string]: unknown }) => void) => { const o = good() as never; fn(o); return o; };
  const bad: unknown[] = [
    mutate((o) => { o.extra = 1; }),
    mutate((o) => { o.columns = 31; }),
    mutate((o) => { o.rows = 0; }),
    mutate((o) => { o.columns = 1.5; }),
    mutate((o) => { o.cells.pop(); }),
    mutate((o) => { o.cells[0] = 0; }),            // empty cell
    mutate((o) => { o.cells[0] = 2.5; }),          // fractional count
    mutate((o) => { o.cells[1] = 5; }),            // sum above pixel count
    mutate((o) => { o.cells[2] = NaN; }),
    mutate((o) => { o.cells[3] = -0.1; }),
    mutate((o) => { o.cells[4] = 5; }),            // weight above 1.05 per pixel
    mutate((o) => { o.cells[5] = 0.5; }),          // weighted sum above weight
    mutate((o) => { o.cells[6] = '0'; }),
    mutate((o) => { o.cells = 'abc'; }),
    null, [], 'x',
  ];
  for (const input of bad) assert.throws(() => validateGrid(input), /Invalid frame grid/, JSON.stringify(input));
});

test('edge bands follow the depth setting; thirds do not', () => {
  const g = sampleGrid(image(160, 90, (x) => (x < 32 ? [255, 0, 0] : x >= 128 ? [0, 0, 255] : [128, 128, 128])), 160, 90);
  assert.deepEqual(gridColor(g, 'edgeLeft', 0.15, false), [1, 0, 0]);
  assert.deepEqual(gridColor(g, 'edgeRight', 0.15, false), [0, 0, 1]);
  const deep = gridColor(g, 'edgeLeft', 0.33, false);
  assert.ok(deep[0] < 1 && deep[1] > 0);
  assert.deepEqual(gridColor(g, 'left', 0.05, false), gridColor(g, 'left', 0.33, false));
});

test('corners and half edges pick their quadrant', () => {
  const quad = (x: number, y: number): Rgb => (y < 45 ? (x < 80 ? [255, 0, 0] : [0, 255, 0]) : (x < 80 ? [0, 0, 255] : [255, 255, 0]));
  const c = gridColors(sampleGrid(image(160, 90, quad), 160, 90), 0.2);
  const expect: Array<[keyof typeof c, LinearRGB]> = [
    ['cornerTopLeft', [1, 0, 0]], ['cornerTopRight', [0, 1, 0]], ['cornerBottomLeft', [0, 0, 1]], ['cornerBottomRight', [1, 1, 0]],
    ['edgeTopLeft', [1, 0, 0]], ['edgeTopRight', [0, 1, 0]], ['edgeBottomLeft', [0, 0, 1]], ['edgeBottomRight', [1, 1, 0]],
    ['edgeLeftUpper', [1, 0, 0]], ['edgeLeftLower', [0, 0, 1]], ['edgeRightUpper', [0, 1, 0]], ['edgeRightLower', [1, 1, 0]],
    ['edgeTop', [0.5, 0.5, 0]],
  ];
  for (const [region, rgb] of expect) rgb.forEach((v, i) => near(c[region][i]!, v, 1e-9));
});

test('vivid favors color over white; gray-only pictures keep their color', () => {
  const g = sampleGrid(image(160, 90, (x) => (x < 16 ? [255, 0, 0] : [255, 255, 255])), 160, 90);
  const plain = gridColor(g, 'full', 0.15, false), vivid = gridColor(g, 'full', 0.15, true);
  assert.ok(plain[1] > 0.85);
  assert.ok(vivid[1] < plain[1] / 2 && vivid[0] > 0.99);
  const gray = sampleGrid(image(32, 18, () => [128, 128, 128]), 32, 18);
  gridColor(gray, 'full', 0.15, true).forEach((v) => near(v, srgbToLinear(128)));
});

test('tiny pictures still cover every region', () => {
  const g = sampleGrid(image(4, 2, () => [255, 0, 0]), 4, 2);
  assert.equal(g.columns, 4);
  for (const region of REGIONS) assert.deepEqual(gridColor(g, region, 0.05, false), [1, 0, 0], region);
});

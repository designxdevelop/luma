// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_SYNC_SETTINGS, REGIONS, exceedsThreshold, letterbox, linearToSrgb, regionAverages, smooth, srgbToLinear,
  toTarget, validateSamples, validateSettings, type LinearRGB,
} from '../shared/sync-math';

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
  for (const region of REGIONS) {
    expected[region]!.forEach((v, i) => near(r[region][i]!, v, 1e-9));
  }
});

test('smooth: 0 follows instantly, 0.5 halves the step, no previous copies next', () => {
  const next: LinearRGB = [1, 0.5, 0];
  assert.deepEqual(smooth(undefined, next, 0.9), next);
  assert.notEqual(smooth(undefined, next, 0.9), next);
  assert.deepEqual(smooth([0, 0, 0], next, 0), next);
  assert.deepEqual(smooth([0, 0, 0], next, 0.5), [0.5, 0.25, 0]);
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
  assert.deepEqual(validateSettings({ updateHz: 3, restore: true }, DEFAULT_SYNC_SETTINGS), { ...DEFAULT_SYNC_SETTINGS, updateHz: 3, restore: true });
  assert.doesNotThrow(() => validateSettings({ smoothing: 0, threshold: 0.2, brightnessCap: 1, updateHz: 0.5 }, DEFAULT_SYNC_SETTINGS));
  assert.deepEqual(DEFAULT_SYNC_SETTINGS.restore, false); // base is never mutated
});

test('validateSettings rejects bad values, unknown keys and bad roots', () => {
  const bad: unknown[] = [
    { smoothing: NaN }, { smoothing: Infinity }, { smoothing: 0.96 }, { smoothing: -0.1 }, { smoothing: '0.5' },
    { threshold: 0.001 }, { threshold: 0.3 }, { brightnessCap: 0 }, { brightnessCap: 101 }, { updateHz: 6 }, { updateHz: 0.1 },
    { bogus: 1 }, { restore: 'yes' }, { restore: 1 }, null, [], 'x', 5,
  ];
  for (const input of bad) assert.throws(() => validateSettings(input, DEFAULT_SYNC_SETTINGS), /Invalid Screen Sync/, JSON.stringify(input));
});

test('validateSamples accepts exactly five regions of three values in [0,1]', () => {
  const good = () => ({ full: [0, 0.5, 1], left: [0, 0, 0], right: [1, 1, 1], top: [0.1, 0.2, 0.3], bottom: [0.4, 0.5, 0.6] });
  assert.deepEqual(validateSamples(good()), good());
  const mutate = (fn: (o: Record<string, unknown>) => void) => { const o = good() as Record<string, unknown>; fn(o); return o; };
  const bad: unknown[] = [
    mutate((o) => { delete o.top; }),
    mutate((o) => { o.extra = [0, 0, 0]; }),
    mutate((o) => { o.left = [0, 0]; }),
    mutate((o) => { o.left = [0, 0, 0, 0]; }),
    mutate((o) => { o.left = [0, NaN, 0]; }),
    mutate((o) => { o.left = [0, 1.1, 0]; }),
    mutate((o) => { o.left = [0, -0.1, 0]; }),
    mutate((o) => { o.left = ['0', 0, 0]; }),
    mutate((o) => { o.left = 'abc'; }),
    [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]], null, 'x',
  ];
  for (const input of bad) assert.throws(() => validateSamples(input), /Invalid frame samples/);
});

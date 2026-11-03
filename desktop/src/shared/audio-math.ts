// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Platform-neutral Audio Sync math. Pure functions only (no DOM, Electron or Node):
// compiled as CommonJS for main/tests and as an ES module for the renderer.
//
// The renderer reduces real captured audio (Web Audio AnalyserNode) to one loudness value
// and 8 log-spaced band levels, all 0…1. Only those 9 numbers cross IPC; samples never do.
// Main maps them to per-light color and brightness with a noise gate, slow automatic gain,
// a brightness floor under the cap, and a fast-attack / slow-release envelope that keeps
// full-depth brightness swings well under 3 per second.

import type { AudioOptions, SyncSettings } from './types';
import type { LightTarget } from './sync-math';

export const AUDIO_BANDS = 8;
/** Band edges in Hz: 40 Hz … 16 kHz, log spaced (bass → treble). */
export const AUDIO_EDGES_HZ = Array.from({ length: AUDIO_BANDS + 1 }, (_, i) => 40 * 400 ** (i / AUDIO_BANDS));
export const DEFAULT_AUDIO_OPTIONS: AudioOptions = { style: 'pulse', sensitivity: 1 };
export const AUDIO_LIMITS = { sensitivity: [0.5, 2] } as const;

export const AUDIO_TUNING = {
  /** Normalized loudness/band level below which input counts as silence (≈ −55 dBFS loudness). */
  gate: 0.08,
  /** Brightness never drops below this share of the cap while streaming (and never below 1 %). */
  floorShare: 0.2,
  /** Envelope rise time constant. */
  attackS: 0.05,
  /** Envelope fall time constant at smoothing 0 and at the smoothing maximum (0.95). */
  releaseMinS: 0.25,
  releaseMaxS: 1.2,
  /** Automatic gain: the remembered peak halves this often, so quiet songs still move. */
  agcHalfLifeS: 4,
  /** The remembered peak never falls below this, so hiss is not amplified into motion. */
  agcMinPeak: 0.35,
  /** Hue follows the music this slowly, so color does not flicker. */
  hueS: 0.4,
  /** Bass (band 0) is red; treble (last band) is this hue, a blue-violet. */
  hueSpan: 260,
} as const;

/** dBFS ranges mapped to 0…1. Bands are per-FFT-bin power (Blackman window), loudness is RMS. */
export const BAND_DB: readonly [number, number] = [-90, -20];
export const LEVEL_DB: readonly [number, number] = [-60, 0];

export interface AudioLevels { level: number; bands: number[] }

const clamp01 = (v: number) => (v > 0 ? (v < 1 ? v : 1) : 0);

/** RMS of time-domain samples (−1…1) as 0…1 over LEVEL_DB. Silence and NaN give 0. */
export function rmsLevel(samples: ArrayLike<number>): number {
  let sum = 0, n = 0;
  for (let i = 0; i < samples.length; i++) { const s = samples[i]!; if (Number.isFinite(s)) { sum += s * s; n++; } }
  if (!n || sum <= 0) return 0;
  const db = 10 * Math.log10(sum / n);
  return clamp01((db - LEVEL_DB[0]) / (LEVEL_DB[1] - LEVEL_DB[0]));
}

/**
 * Per-bin dBFS (AnalyserNode.getFloatFrequencyData, bin k at k·sampleRate/fftSize) to 8 band
 * levels: mean power of the bins inside each band, in dB, mapped over BAND_DB. A band with no
 * bin (tiny FFT) borrows its nearest bin, so every band is always defined.
 */
export function bandLevels(db: ArrayLike<number>, sampleRate: number): number[] {
  const bins = db.length, hzPerBin = sampleRate / (2 * bins);
  return Array.from({ length: AUDIO_BANDS }, (_, b) => {
    const lo = Math.max(1, Math.ceil(AUDIO_EDGES_HZ[b]! / hzPerBin)), hi = Math.min(bins - 1, Math.ceil(AUDIO_EDGES_HZ[b + 1]! / hzPerBin) - 1);
    let power = 0, n = 0;
    for (let k = lo; k <= hi; k++) { const v = db[k]!; power += Number.isFinite(v) ? 10 ** (v / 10) : 0; n++; }
    if (!n) { const v = db[Math.min(bins - 1, Math.max(1, Math.round(AUDIO_EDGES_HZ[b]! / hzPerBin)))]!; power = Number.isFinite(v) ? 10 ** (v / 10) : 0; n = 1; }
    if (power <= 0) return 0;
    return clamp01((10 * Math.log10(power / n) - BAND_DB[0]) / (BAND_DB[1] - BAND_DB[0]));
  });
}

/** Strict shape for levels crossing IPC: exactly { level, bands[8] }, every value finite in 0…1. */
export function validateLevels(input: unknown): AudioLevels {
  const invalid = () => new Error('Invalid audio levels.');
  if (typeof input !== 'object' || input === null || Array.isArray(input) || Object.keys(input).length !== 2) throw invalid();
  const { level, bands } = input as Record<string, unknown>;
  const ok = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1;
  if (!ok(level) || !Array.isArray(bands) || bands.length !== AUDIO_BANDS || !bands.every(ok)) throw invalid();
  return { level, bands: [...bands] };
}

/** Merges a partial options update; every present field must be valid. */
export function validateAudioOptions(input: unknown, base: AudioOptions = DEFAULT_AUDIO_OPTIONS): AudioOptions {
  const invalid = () => new Error('Invalid Audio Sync options.');
  if (typeof input !== 'object' || input === null || Array.isArray(input)) throw invalid();
  const next = { ...base };
  for (const [key, value] of Object.entries(input)) {
    if (key === 'style') {
      if (value !== 'pulse' && value !== 'spectrum') throw invalid();
      next.style = value;
    } else if (key === 'sensitivity') {
      if (typeof value !== 'number' || !Number.isFinite(value) || value < AUDIO_LIMITS.sensitivity[0] || value > AUDIO_LIMITS.sensitivity[1]) throw invalid();
      next.sensitivity = value;
    } else throw invalid();
  }
  return next;
}

/** Full-saturation hue (degrees) as 0xRRGGBB. */
export function hueToRgb(hue: number): number {
  const h = (((hue % 360) + 360) % 360) / 60, x = Math.round(255 * (1 - Math.abs((h % 2) - 1)));
  const [r, g, b] = h < 1 ? [255, x, 0] : h < 2 ? [x, 255, 0] : h < 3 ? [0, 255, x] : h < 4 ? [0, x, 255] : h < 5 ? [x, 0, 255] : [255, 0, x];
  return (r << 16) | (g << 8) | b;
}

/** Inclusive brightness range for a cap: floor ≤ brightness ≤ cap, both whole percents ≥ 1. */
export function brightnessRange(brightnessCap: number): [number, number] {
  const cap = Math.max(1, Math.min(100, Math.round(Number.isFinite(brightnessCap) ? brightnessCap : 1)));
  return [Math.max(1, Math.round(cap * AUDIO_TUNING.floorShare)), cap];
}

/**
 * Stateful mapping from analysis frames to light targets.
 * - pulse: every light shares one color from the spectral balance (bass red → treble violet)
 *   and one brightness from loudness.
 * - spectrum: lights are spread bass → treble in selection order; each takes its band's level
 *   as brightness and the band's fixed hue. One light behaves like pulse.
 */
export class AudioMapper {
  private peak: number = AUDIO_TUNING.agcMinPeak;
  private readonly bandPeaks: number[] = new Array<number>(AUDIO_BANDS).fill(AUDIO_TUNING.agcMinPeak);
  private env: number[] = [];
  private hue: Array<number | undefined> = [];

  step(levels: AudioLevels, count: number, settings: Pick<SyncSettings, 'brightnessCap' | 'smoothing'>, options: AudioOptions, dtS = 0.05): LightTarget[] {
    const t = AUDIO_TUNING, dt = Math.max(0.001, Math.min(1, Number.isFinite(dtS) ? dtS : 0.05));
    const decay = 0.5 ** (dt / t.agcHalfLifeS), gain = Math.max(AUDIO_LIMITS.sensitivity[0], Math.min(AUDIO_LIMITS.sensitivity[1], options.sensitivity));
    const norm = (v: number, peak: number) => (v < t.gate ? 0 : clamp01(((v - t.gate) / Math.max(1e-3, peak - t.gate)) * gain));
    this.peak = Math.max(t.agcMinPeak, levels.level, this.peak * decay);
    const loud = norm(levels.level, this.peak);
    const bands = levels.bands.map((v, i) => { this.bandPeaks[i] = Math.max(t.agcMinPeak, v, this.bandPeaks[i]! * decay); return norm(v, this.bandPeaks[i]!); });
    const total = bands.reduce((a, b) => a + b, 0);
    const balanceHue = total > 1e-3 ? (bands.reduce((a, b, i) => a + b * i, 0) / total / (AUDIO_BANDS - 1)) * t.hueSpan : undefined;

    const smoothing = Math.max(0, Math.min(0.95, settings.smoothing)) / 0.95;
    const release = 1 - Math.exp(-dt / (t.releaseMinS + smoothing * (t.releaseMaxS - t.releaseMinS)));
    const attack = 1 - Math.exp(-dt / t.attackS), hueStep = 1 - Math.exp(-dt / t.hueS);
    const [floor, cap] = brightnessRange(settings.brightnessCap);
    const n = Math.max(0, Math.floor(count));
    this.env.length = this.hue.length = n;

    const out: LightTarget[] = [];
    for (let i = 0; i < n; i++) {
      let energy = loud, hueTarget = balanceHue;
      if (options.style === 'spectrum' && n > 1) {
        const p = (i / (n - 1)) * (AUDIO_BANDS - 1), lo = Math.floor(p), hi = Math.min(AUDIO_BANDS - 1, lo + 1), f = p - lo;
        energy = bands[lo]! * (1 - f) + bands[hi]! * f;
        hueTarget = (p / (AUDIO_BANDS - 1)) * t.hueSpan;
      }
      const e = this.env[i] ?? 0;
      this.env[i] = e + (energy > e ? attack : release) * (energy - e);
      const h = this.hue[i];
      // Silence keeps the last color; the first sound sets it at once.
      this.hue[i] = hueTarget === undefined ? h : h === undefined ? hueTarget : h + hueStep * (hueTarget - h);
      out.push({ rgb: hueToRgb(this.hue[i] ?? 0), brightness: Math.max(floor, Math.min(cap, Math.round(floor + (cap - floor) * this.env[i]!))) });
    }
    return out;
  }

  /** Forgets envelopes and color (pause); the gain memory is kept so resuming doesn't jump. */
  reset(): void { this.env = []; this.hue = []; }
}

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Audio Sync: analysis math, level-to-light mapping limits, the shared session controller in
// audio mode, and the capture policy. No audio is captured here: analysis inputs are computed
// test signals (sine samples, constructed spectra), and LAN is a fake writer.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CapabilityCommand, LightDevice, SyncGrid } from '../shared/types';
import type { StreamField } from '../core/stream';
import { SyncController, type SyncHost } from '../main/sync';
import { AUDIO_BANDS, AUDIO_TUNING, AudioMapper, bandLevels, brightnessRange, hueToRgb, rmsLevel, validateAudioOptions, validateLevels, type AudioLevels } from '../shared/audio-math';
import { AudioGrants, audioOnly, audioSupportFor, displayMediaDecision, type DisplayContext, type DisplayRequest } from '../main/audio-capture';

const flush = () => new Promise<void>((r) => setImmediate(r));
const quiet = (): number[] => new Array<number>(AUDIO_BANDS).fill(0);
const lv = (level: number, bands: number[] = quiet()): AudioLevels => ({ level, bands });
const settings = (brightnessCap = 80, smoothing = 0.4) => ({ brightnessCap, smoothing });
const pulse = { style: 'pulse' as const, sensitivity: 1 };
const rgbOf = (c: number) => [(c >> 16) & 255, (c >> 8) & 255, c & 255];

// ---------- analysis ----------

test('rmsLevel: full-scale sine ≈ −3 dBFS, quiet and silent signals fall to 0', () => {
  const sine = (amp: number) => Array.from({ length: 2048 }, (_, i) => amp * Math.sin((2 * Math.PI * 1000 * i) / 48_000));
  assert.ok(Math.abs(rmsLevel(sine(1)) - 0.95) < 0.01, `full scale ${rmsLevel(sine(1))}`);
  assert.ok(Math.abs(rmsLevel(sine(0.1)) - 0.617) < 0.01, '−23 dBFS');
  assert.equal(rmsLevel(sine(0.0005)), 0, '−69 dBFS is below the range');
  assert.equal(rmsLevel(new Array(2048).fill(0)), 0);
  assert.equal(rmsLevel([NaN, Infinity]), 0);
});

test('bandLevels: a bin\'s energy lands in the right log band; silent bins (−Infinity) are 0', () => {
  const bins = 1024, rate = 48_000, hz = rate / (2 * bins);
  const spectrum = (tones: Array<[number, number]>) => { const d = new Array<number>(bins).fill(-Infinity); for (const [f, db] of tones) d[Math.round(f / hz)] = db; return d; };
  const bass = bandLevels(spectrum([[60, -20]]), rate);
  assert.equal(bass.length, AUDIO_BANDS);
  assert.ok(bass[0]! > 0.8 && bass.slice(1).every((v) => v === 0), `bass ${bass}`);
  const hiss = bandLevels(spectrum([[5000, -30]]), rate);
  assert.ok(hiss[6]! > 0.5 && hiss.filter((_, i) => i !== 6).every((v) => v === 0), `5 kHz ${hiss}`);
  assert.deepEqual(bandLevels(new Array(bins).fill(-Infinity), rate), quiet());
  // A tiny FFT still defines every band.
  assert.equal(bandLevels(new Array(16).fill(-40), rate).length, AUDIO_BANDS);
});

test('levels crossing IPC are exactly { level, bands[8] } with finite values in 0…1', () => {
  assert.deepEqual(validateLevels(lv(0.5)), lv(0.5));
  for (const bad of [null, [], 1, {}, { level: 0.5 }, { level: 0.5, bands: quiet(), extra: 1 }, { level: 1.1, bands: quiet() }, { level: NaN, bands: quiet() },
    { level: 0.5, bands: quiet().slice(1) }, { level: 0.5, bands: [...quiet().slice(1), -0.1] }, { level: 0.5, bands: [...quiet().slice(1), '1'] }]) {
    assert.throws(() => validateLevels(bad), /Invalid audio levels/, JSON.stringify(bad));
  }
});

test('audio options merge partially and reject anything out of range', () => {
  assert.deepEqual(validateAudioOptions({ style: 'spectrum' }, pulse), { style: 'spectrum', sensitivity: 1 });
  assert.deepEqual(validateAudioOptions({ sensitivity: 2 }, pulse), { style: 'pulse', sensitivity: 2 });
  for (const bad of [null, [], { style: 'strobe' }, { sensitivity: 0.4 }, { sensitivity: 2.1 }, { sensitivity: NaN }, { color: 1 }]) assert.throws(() => validateAudioOptions(bad, pulse), /Invalid Audio Sync options/);
});

// ---------- mapping limits ----------

test('brightness always stays within floor…cap and colors are full-saturation, for any input', () => {
  let seed = 42;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  for (const style of ['pulse', 'spectrum'] as const) {
    const m = new AudioMapper();
    for (let i = 0; i < 3000; i++) {
      const cap = 1 + Math.floor(rnd() * 100), count = 1 + Math.floor(rnd() * 8);
      const out = m.step(lv(rnd(), quiet().map(() => (rnd() < 0.3 ? 0 : rnd()))), count, settings(cap, rnd() * 0.95), { style, sensitivity: 0.5 + rnd() * 1.5 }, rnd() * 2);
      const [floor] = brightnessRange(cap);
      assert.equal(out.length, count);
      for (const t of out) {
        assert.ok(Number.isInteger(t.brightness) && t.brightness >= floor && t.brightness <= cap && t.brightness >= 1, `cap ${cap}: ${t.brightness}`);
        assert.ok(Number.isInteger(t.rgb) && t.rgb >= 0 && t.rgb <= 0xffffff);
        assert.equal(Math.max(...rgbOf(t.rgb)), 255, 'full saturation, brightness carries loudness');
      }
    }
  }
  assert.deepEqual(brightnessRange(80), [16, 80]);
  assert.deepEqual(brightnessRange(1), [1, 1]);
  assert.deepEqual(brightnessRange(NaN), [1, 1]);
});

test('silence and sub-gate hiss rest at the floor; steady loud music reaches the cap', () => {
  const m = new AudioMapper();
  for (let i = 0; i < 40; i++) assert.equal(m.step(lv(AUDIO_TUNING.gate * 0.9, quiet().fill(0.05)), 1, settings(80), pulse)[0]!.brightness, 16);
  let b = 0;
  for (let i = 0; i < 40; i++) b = m.step(lv(0.9, quiet().fill(0.6)), 1, settings(80), pulse)[0]!.brightness;
  assert.equal(b, 80);
  // Back to silence: fades to the floor, never below it, never off.
  for (let i = 0; i < 200; i++) b = m.step(lv(0), 1, settings(80), pulse)[0]!.brightness;
  assert.equal(b, 16);
});

test('automatic gain: a quiet but steady song still uses the range, and sensitivity scales it', () => {
  const run = (sensitivity: number, level: number) => { const m = new AudioMapper(); let b = 0; for (let i = 0; i < 400; i++) b = m.step(lv(level), 1, settings(100), { style: 'pulse', sensitivity })[0]!.brightness; return b; };
  assert.equal(run(1, 0.45), 100, 'gain adapts down to a quiet peak');
  assert.ok(run(1, 0.25) < run(2, 0.25), 'sensitivity raises a level below the minimum peak');
  assert.ok(run(0.5, 0.25) < run(1, 0.25));
});

test('strobe safety: a 10 Hz on/off input barely moves brightness; a 1 Hz beat swings fully', () => {
  const swing = (periodS: number) => {
    const m = new AudioMapper(), dt = 0.05, seen: number[] = [];
    for (let i = 0; i < 200; i++) {
      const on = Math.floor(i / Math.round(periodS / 2 / dt)) % 2 === 0; // integer steps: no float drift
      const b = m.step(lv(on ? 1 : 0), 1, settings(100, 0), pulse, dt)[0]!.brightness;
      if (i >= 100) seen.push(b);
    }
    return (Math.max(...seen) - Math.min(...seen)) / (100 - 20);
  };
  assert.ok(swing(0.1) < 0.3, `10 Hz swing ${swing(0.1)}`);
  assert.ok(swing(1) > 0.8, `1 Hz swing ${swing(1)}`);
});

test('pulse color follows spectral balance: bass is red, treble is blue-violet; silence keeps the color', () => {
  const m = new AudioMapper();
  const bassOnly = quiet(); bassOnly[0] = 0.9;
  const trebleOnly = quiet(); trebleOnly[7] = 0.9;
  assert.equal(m.step(lv(0.8, bassOnly), 2, settings(), pulse)[0]!.rgb, 0xff0000);
  let rgb = 0;
  for (let i = 0; i < 100; i++) rgb = m.step(lv(0.8, trebleOnly), 2, settings(), pulse)[1]!.rgb;
  assert.equal(rgb, hueToRgb(AUDIO_TUNING.hueSpan));
  assert.equal(hueToRgb(260), 0x5500ff);
  assert.equal(m.step(lv(0), 2, settings(), pulse)[0]!.rgb, rgb, 'silence holds the last color');
});

test('spectrum: lights spread bass → treble in order, each following its own band', () => {
  const m = new AudioMapper(), spectrum = { style: 'spectrum' as const, sensitivity: 1 };
  const bassOnly = quiet(); bassOnly[0] = 0.9;
  let out = m.step(lv(0.8, bassOnly), 3, settings(100), spectrum);
  for (let i = 0; i < 20; i++) out = m.step(lv(0.8, bassOnly), 3, settings(100), spectrum);
  assert.equal(out[0]!.rgb, 0xff0000);
  assert.equal(out[2]!.rgb, hueToRgb(AUDIO_TUNING.hueSpan));
  assert.equal(out[0]!.brightness, 100);
  assert.equal(out[2]!.brightness, 20, 'treble light rests at the floor during a bass note');
  // One light in spectrum behaves like pulse.
  assert.equal(new AudioMapper().step(lv(0.8, bassOnly), 1, settings(100), spectrum)[0]!.rgb, 0xff0000);
});

// ---------- session controller in audio mode ----------

const lan = (id: string, extra: Partial<LightDevice> = {}): LightDevice =>
  ({ id, sku: 'H6008', name: id.toUpperCase(), room: 'Room', ip: `192.168.1.${id.charCodeAt(0)}`, capabilities: [], power: true, brightness: 80, rgb: 0x336699, colorTemperature: 0, online: true, ...extra });

function controller(devices: LightDevice[], opts: { scene?: boolean } = {}) {
  let t = 1000;
  const timers: Array<{ at: number; fn: () => void; dead: boolean }> = [];
  const writes: Array<{ id: string; field: StreamField; value: number; done(): void }> = [];
  const restores: Array<{ id: string; commands: CapabilityCommand[] }> = [];
  const logs: string[] = [];
  const host: SyncHost = {
    devices: () => devices, hasPending: () => false, sceneRunning: () => opts.scene ?? false, lanReady: () => true,
    streamWrite: (id, field, value) => new Promise<void>((done) => writes.push({ id, field, value, done })),
    restore: async (id, commands) => { restores.push({ id, commands }); },
    changed: () => {}, log: (text) => logs.push(text),
  };
  const sync = new SyncController(host, {
    demo: true, captureSupported: false, now: () => t, audioSupport: { system: true, systemExperimental: false, input: true },
    schedule: (fn, ms) => { const x = { at: t + ms, fn, dead: false }; timers.push(x); return () => { x.dead = true; }; },
  });
  const advance = async (ms: number) => { t += ms; for (const x of timers.filter((x) => !x.dead && x.at <= t)) { x.dead = true; x.fn(); } await flush(); };
  return { sync, writes, restores, logs, advance, tick: () => { t += 50; } };
}
const grid: SyncGrid = { columns: 1, rows: 1, cells: [1, 1, 0, 0, 1, 1, 0, 0] };

test('audio session: needs no region, takes only levels, never frames, and is never reported as synthetic', async () => {
  const c = controller([lan('a'), lan('b')]);
  c.sync.setSettings({ brightnessCap: 30 });
  const { token, generation } = c.sync.start([{ id: 'a' }, { id: 'b' }], 'Computer audio', 'audio');
  assert.equal(c.sync.kind, 'audio');
  const view = c.sync.view();
  assert.equal(view.kind, 'audio');
  assert.equal(view.synthetic, false, 'demo screen frames never stand in for audio');
  assert.equal(c.sync.frame(token, generation, 1, grid), false, 'screen frames are refused in an audio session');
  assert.equal(c.sync.levels(token, generation, 1, { level: 2, bands: quiet() }), false, 'malformed levels are dropped');
  assert.equal(c.writes.length, 0);
  assert.equal(c.sync.levels(token, generation, 1, lv(0.9, quiet().fill(0.7))), true);
  assert.equal(c.sync.phase, 'running');
  // The cap is the first thing each light receives.
  assert.deepEqual(c.writes.map((w) => [w.id, w.field]), [['a', 'brightness'], ['b', 'brightness']]);
  assert.ok(c.writes.every((w) => w.value <= 30));
  assert.equal(c.sync.levels(token, generation, 2, lv(0.9)), false, 'faster than 60 per second');
  c.tick();
  assert.equal(c.sync.levels(token, generation, 1, lv(0.9)), false, 'replayed seq');
  assert.match(c.logs[0]!, /^Audio Sync started for 2 lights/);
});

test('audio and screen sessions are exclusive, and scenes block audio', () => {
  const c = controller([lan('a')]);
  const screen = c.sync.start([{ id: 'a', region: 'full' }], 'S');
  assert.equal(c.sync.levels(screen.token, screen.generation, 1, lv(0.5)), false, 'levels are refused in a screen session');
  assert.throws(() => c.sync.start([{ id: 'a' }], 'Computer audio', 'audio'), (e: { status?: number }) => e.status === 409);
  assert.throws(() => controller([lan('a')], { scene: true }).sync.start([{ id: 'a' }], 'Computer audio', 'audio'), /scene is running.*Audio Sync/);
});

test('audio stall stops without restoring; explicit stop restores; options apply live', async () => {
  const c = controller([lan('a')]);
  c.sync.setSettings({ restore: true });
  let s = c.sync.start([{ id: 'a' }], 'Computer audio', 'audio');
  c.sync.levels(s.token, s.generation, 1, lv(0.9));
  for (const w of c.writes) w.done();
  await c.advance(10_000);
  assert.equal(c.sync.phase, 'idle');
  assert.match(c.sync.view().lastStop ?? '', /No audio analysis arrived/);
  assert.equal(c.restores.length, 0);
  s = c.sync.start([{ id: 'a' }], 'Computer audio', 'audio');
  c.sync.setAudio({ style: 'spectrum' });
  assert.equal(c.sync.view().audio.style, 'spectrum');
  assert.throws(() => c.sync.setAudio({ style: 'strobe' }), /Invalid Audio Sync options/);
  c.sync.levels(s.token, s.generation, 1, lv(0.9));
  for (const w of c.writes) w.done();
  await c.sync.stop('Stopped.', true);
  assert.equal(c.restores.length, 1, 'explicit stop restores the confirmed state');
  assert.match(c.logs.at(-1)!, /^Audio Sync stopped/);
});

test('manual control takes a light out of Audio Sync without reshuffling the others', async () => {
  const c = controller([lan('a'), lan('b'), lan('c')]);
  c.sync.setAudio({ style: 'spectrum' });
  const s = c.sync.start([{ id: 'a' }, { id: 'b' }, { id: 'c' }], 'Computer audio', 'audio');
  const treble = quiet(); treble[7] = 0.9;
  c.sync.levels(s.token, s.generation, 1, lv(0.9, treble));
  for (const w of c.writes) w.done();
  await c.sync.exclude('b');
  c.tick();
  c.sync.levels(s.token, s.generation, 2, lv(0.9, treble));
  const lights = c.sync.view().lights;
  assert.equal(lights.find((l) => l.id === 'b')!.status, 'excluded');
  assert.equal(lights.find((l) => l.id === 'c')!.requestedRGB, hueToRgb(AUDIO_TUNING.hueSpan), 'c still maps to treble');
});

// ---------- capture policy ----------

test('display media: screen sessions get only their source, audio sessions only loopback, single use', () => {
  const req: DisplayRequest = { trustedFrame: true, userGesture: true, videoRequested: true, audioRequested: false };
  const screen: DisplayContext = { sessionKind: 'screen', awaiting: true, unlocked: true, realScreen: true, systemAudio: true, screenGrant: { id: 'screen:1:0', name: 'Screen' } };
  assert.deepEqual(displayMediaDecision(req, screen), { kind: 'screen', source: { id: 'screen:1:0', name: 'Screen' } });
  assert.equal(displayMediaDecision({ ...req, audioRequested: true }, screen).kind, 'refuse', 'a screen session never gets audio');
  assert.equal(displayMediaDecision(req, { ...screen, screenGrant: undefined }).kind, 'refuse');
  assert.equal(displayMediaDecision(req, { ...screen, realScreen: false }).kind, 'refuse', 'demo never captures the screen');
  const audio: DisplayContext = { sessionKind: 'audio', awaiting: true, unlocked: true, realScreen: true, systemAudio: true, audioGrant: 'system', screenGrant: { id: 'screen:1:0', name: 'Screen' } };
  assert.deepEqual(displayMediaDecision({ ...req, audioRequested: true }, audio), { kind: 'loopback' });
  assert.equal(displayMediaDecision(req, audio).kind, 'refuse', 'an audio session never gets a video-only screen grant');
  assert.equal(displayMediaDecision({ ...req, audioRequested: true }, { ...audio, audioGrant: 'input' }).kind, 'refuse');
  assert.equal(displayMediaDecision({ ...req, audioRequested: true }, { ...audio, systemAudio: false }).kind, 'refuse');
  for (const bad of [{ trustedFrame: false }, { userGesture: false }, { videoRequested: false }]) assert.equal(displayMediaDecision({ ...req, audioRequested: true, ...bad }, audio).kind, 'refuse');
  for (const bad of [{ awaiting: false }, { unlocked: false }]) assert.equal(displayMediaDecision({ ...req, audioRequested: true }, { ...audio, ...bad }).kind, 'refuse');
});

test('audio grants are single use, per generation and short lived; input permission is audio only', () => {
  let t = 0;
  const g = new AudioGrants({ now: () => t, grantMs: 1000 });
  g.issue('input', 3);
  assert.equal(g.peek(2), undefined);
  assert.equal(g.peek(3), 'input');
  assert.equal(g.consume(3), 'input');
  assert.equal(g.consume(3), undefined, 'single use');
  g.issue('system', 4);
  t = 1001;
  assert.equal(g.consume(4), undefined, 'expired');
  g.issue('system', 5);
  g.revoke();
  assert.equal(g.consume(5), undefined);
  assert.equal(audioOnly(['audio']), true);
  for (const bad of [undefined, [], ['video'], ['audio', 'video']]) assert.equal(audioOnly(bad), false);
});

test('platform support: loopback on Windows, experimental on Linux, input-only on macOS', () => {
  assert.deepEqual(audioSupportFor('win32'), { system: true, systemExperimental: false, input: true });
  assert.deepEqual(audioSupportFor('linux'), { system: true, systemExperimental: true, input: true });
  assert.deepEqual(audioSupportFor('darwin'), { system: false, systemExperimental: false, input: true });
  assert.deepEqual(audioSupportFor('freebsd'), { system: false, systemExperimental: false, input: false });
});

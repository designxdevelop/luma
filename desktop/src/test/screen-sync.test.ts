// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// FramePump's async capture path against fake browser APIs (no real capture): late
// getDisplayMedia/play results after Pause, Stop or a newer Start.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

function deferred<T>() {
  let resolve!: (v: T) => void, reject!: (e: unknown) => void;
  const promise = new Promise<T>((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

class Track extends EventTarget {
  enabled = true;
  stopped = false;
  stop() { this.stopped = true; }
}
const stream = (track: Track) => ({ getVideoTracks: () => [track], getAudioTracks: () => [], getTracks: () => [track] });

const media: Array<ReturnType<typeof deferred<unknown>>> = [];
const plays: Array<ReturnType<typeof deferred<void>>> = [];
const workers: Array<{ onmessage?: (event: { data: unknown }) => void; posts: number }> = [];
let bitmaps = 0;
let autoPlay = true;
Object.assign(globalThis, {
  window: globalThis,
  Worker: class {
    onmessage?: (event: { data: unknown }) => void; onerror?: unknown; posts = 0;
    constructor() { workers.push(this); }
    postMessage() { this.posts++; } terminate() {}
  },
  document: {
    visibilityState: 'visible',
    createElement: () => ({
      muted: false, srcObject: null, readyState: 4, videoWidth: 96, pause() {},
      play: () => { if (autoPlay) return Promise.resolve(); const d = deferred<void>(); plays.push(d); return d.promise; },
    }),
  },
  createImageBitmap: async () => { bitmaps++; return { close() {} }; },
});
Object.defineProperty(globalThis, 'navigator', {
  configurable: true,
  value: { mediaDevices: { getDisplayMedia: () => { const d = deferred<unknown>(); media.push(d); return d.promise; } } },
});

async function setup() {
  const url = pathToFileURL(join(__dirname, '..', 'ui', 'renderer', 'screen-sync.js')).href;
  const { FramePump } = await (new Function('u', 'return import(u)') as (u: string) => Promise<any>)(url);
  const ended: Array<[string, string]> = [];
  const luma = { syncEnded: async (token: string, reason: string) => { ended.push([token, reason]); }, syncFrame: async () => true };
  media.length = 0; plays.length = 0; workers.length = 0; bitmaps = 0; autoPlay = true;
  return { pump: new FramePump(luma), ended };
}
const grant = (token: string, generation = 1) => ({ token, generation, synthetic: false });

test('pause while getDisplayMedia is pending adopts the stream disabled; only the right token resumes', async () => {
  const { pump, ended } = await setup();
  const starting = pump.start(grant('a'), false);
  pump.pause();
  const track = new Track();
  media[0]!.resolve(stream(track));
  await starting;
  assert.equal(track.enabled, false, 'late stream does not go live while paused');
  await wait(300);
  assert.equal(bitmaps, 0, 'no frames sampled while paused');
  pump.resume('other');
  assert.equal(track.enabled, false, 'a stale token cannot resume');
  pump.resume('a');
  assert.equal(track.enabled, true);
  await wait(300);
  assert.ok(bitmaps > 0, 'sampling resumes');
  pump.stop();
  assert.equal(track.stopped, true);
  assert.deepEqual(ended, []);
});

test('stop while getDisplayMedia is pending releases the late stream and reports nothing', async () => {
  const { pump, ended } = await setup();
  const starting = pump.start(grant('a'), false);
  pump.stop();
  const track = new Track();
  media[0]!.resolve(stream(track));
  await starting;
  assert.equal(track.stopped, true);
  assert.equal(pump.live, false);
  await wait(200);
  assert.equal(bitmaps, 0);
  assert.deepEqual(ended, []);
});

test('a superseded start cannot end, or leak into, the newer session', async () => {
  const { pump, ended } = await setup();
  const first = pump.start(grant('a', 1), false);
  const second = pump.start(grant('b', 2), false);
  media[0]!.reject(new Error('denied'));
  await first;
  assert.deepEqual(ended, [], 'old denial does not end session b');
  const lateA = new Track(), b = new Track();
  media[1]!.resolve(stream(b));
  await second;
  assert.equal(pump.token, 'b');
  assert.equal(b.stopped, false);

  // The old grant's track firing late events after a newer start is ignored.
  const third = pump.start(grant('c', 3), false);
  b.dispatchEvent(new Event('ended'));
  b.dispatchEvent(new Event('mute'));
  assert.equal(b.stopped, true, 'starting again released b');
  media[2]!.resolve(stream(lateA));
  await third;
  assert.deepEqual(ended, []);
  assert.equal(pump.token, 'c');
  pump.stop();
});

test('stop while play() is pending releases the track; a late play failure reports nothing and nothing samples', async () => {
  const { pump, ended } = await setup();
  autoPlay = false;
  const starting = pump.start(grant('a'), false);
  const track = new Track();
  media[0]!.resolve(stream(track));
  await wait(0);
  assert.equal(plays.length, 1);
  pump.stop();
  plays[0]!.reject(new Error('aborted'));
  await starting;
  assert.equal(track.stopped, true);
  await wait(200);
  assert.equal(bitmaps, 0);
  assert.deepEqual(ended, []);
});

test('a newer start while play() is pending: the old play failure cannot end it, and only one sampling loop runs', async () => {
  const { pump, ended } = await setup();
  autoPlay = false;
  const first = pump.start(grant('a', 1), false);
  const a = new Track();
  media[0]!.resolve(stream(a));
  await wait(0);
  const second = pump.start(grant('b', 2), false);
  plays[0]!.reject(new Error('aborted'));
  await first;
  assert.deepEqual(ended, [], 'old play failure does not end session b');
  assert.equal(pump.token, 'b');
  assert.equal(a.stopped, true);
  media[1]!.resolve(stream(new Track()));
  await wait(0);
  plays[1]!.resolve();
  await second;
  pump.stop();
});

test('a live session still ends on its own track ending', async () => {
  const { pump, ended } = await setup();
  const starting = pump.start(grant('a'), false);
  const track = new Track();
  media[0]!.resolve(stream(track));
  await starting;
  track.dispatchEvent(new Event('mute'));
  assert.deepEqual(ended, [['a', 'muted']]);
  assert.equal(track.stopped, true);
  assert.equal(pump.live, false);
});

/** Control only the pump's timers; wait() keeps using Node's real timer. */
function pumpTimers() {
  const originalWindow = (globalThis as any).window, originalClear = globalThis.clearTimeout;
  let next = 0;
  const pending = new Map<number, () => void>();
  (globalThis as any).window = { setTimeout: (fn: () => void) => { pending.set(++next, fn); return next; } };
  (globalThis as any).clearTimeout = (id: number) => pending.delete(id);
  return {
    pending,
    fire() { const [id, fn] = pending.entries().next().value!; pending.delete(id); fn(); },
    restore() { (globalThis as any).window = originalWindow; globalThis.clearTimeout = originalClear; },
  };
}

test('a late bitmap or bitmap failure after Stop and Start cannot attach a second timer chain', async () => {
  for (const fail of [false, true]) {
    const { pump } = await setup(), timers = pumpTimers(), originalBitmap = (globalThis as any).createImageBitmap;
    const bitmap = deferred<unknown>(); let closed = false;
    (globalThis as any).createImageBitmap = () => bitmap.promise;
    try {
      const first = pump.start(grant('old'), false);
      media[0]!.resolve(stream(new Track())); await first;
      timers.fire(); // first session is awaiting its bitmap
      pump.stop();
      const second = pump.start(grant('new', 2), false);
      media[1]!.resolve(stream(new Track())); await second;
      assert.equal(timers.pending.size, 1);
      if (fail) bitmap.reject(new Error('source disappeared'));
      else bitmap.resolve({ close: () => { closed = true; } });
      await wait(0);
      assert.equal(closed, !fail, 'stale bitmap is released');
      assert.equal(timers.pending.size, 1, 'only the new session timer remains');
      assert.equal(workers[1]!.posts, 0, 'old bitmap never reaches the new worker');
      pump.stop();
      assert.equal(timers.pending.size, 0, 'Stop removes every timer');
    } finally { pump.stop(); (globalThis as any).createImageBitmap = originalBitmap; timers.restore(); }
  }
});

test('Pause during bitmap conversion discards it without processing it in the worker', async () => {
  const { pump } = await setup(), timers = pumpTimers(), originalBitmap = (globalThis as any).createImageBitmap;
  const bitmap = deferred<unknown>(); let closed = false;
  (globalThis as any).createImageBitmap = () => bitmap.promise;
  try {
    const starting = pump.start(grant('a'), false);
    media[0]!.resolve(stream(new Track())); await starting;
    timers.fire(); pump.pause();
    bitmap.resolve({ close: () => { closed = true; } }); await wait(0);
    assert.equal(closed, true);
    assert.equal(workers[0]!.posts, 0);
    assert.equal(timers.pending.size, 1, 'only the paused sampling timer remains');
  } finally { pump.stop(); (globalThis as any).createImageBitmap = originalBitmap; timers.restore(); }
});

test('a terminated worker callback cannot clear the new session watchdog', async () => {
  const { pump } = await setup(), timers = pumpTimers();
  try {
    const first = pump.start(grant('a'), false);
    media[0]!.resolve(stream(new Track())); await first;
    const oldWorker = workers[0]!;
    const second = pump.start(grant('b', 2), false);
    media[1]!.resolve(stream(new Track())); await second;
    timers.fire(); await wait(0);
    assert.equal(workers[1]!.posts, 1);
    assert.equal(timers.pending.size, 2, 'sample timer and watchdog');
    oldWorker.onmessage!({ data: { seq: 1, regions: {} } });
    assert.equal(timers.pending.size, 2, 'old callback does not touch the watchdog');
  } finally { pump.stop(); timers.restore(); }
});

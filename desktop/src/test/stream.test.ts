// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import test from 'node:test';
import assert from 'node:assert/strict';
import { StreamSender, type StreamField, type StreamOptions } from '../core/stream';

interface Call { id: string; field: StreamField; value: number; resolve(): void; reject(e: unknown): void }

const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

/** StreamSender with a fake clock, a manual scheduler and controllable writes. */
function harness(options: Pick<StreamOptions, 'maxErrors' | 'onFatal'> = {}) {
  let t = 0;
  const timers: { at: number; fn: () => void; dead: boolean }[] = [];
  const calls: Call[] = [];
  const sender = new StreamSender(
    (id, field, value) => new Promise<void>((resolve, reject) => { calls.push({ id, field, value, resolve, reject }); }),
    {
      ...options,
      now: () => t,
      schedule: (fn, ms) => { const timer = { at: t + ms, fn, dead: false }; timers.push(timer); return () => { timer.dead = true; }; },
    },
  );
  /** Moves the clock forward, firing due timers in order, then lets promise chains settle. */
  async function advance(ms: number) {
    const target = t + ms;
    for (;;) {
      const due = timers.filter((x) => !x.dead && x.at <= target).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      due.dead = true;
      t = Math.max(t, due.at);
      due.fn();
      await flush();
    }
    t = target;
    await flush();
  }
  const call = (i: number): Call => { const c = calls[i]; assert.ok(c, `no write #${i}`); return c; };
  const ok = async (i: number) => { call(i).resolve(); await flush(); };
  const fail = async (i: number) => { call(i).reject(new Error('udp')); await flush(); };
  return { sender, calls, call, advance, ok, fail };
}

const sig = (h: ReturnType<typeof harness>) => h.calls.map((c) => `${c.id}:${c.field}=${c.value}`);

test('first push sends the capped brightness first, then color one interval later (no full-scale flash)', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 0x112233, brightness: 10 });
  assert.deepEqual(sig(h), ['a:brightness=10']);
  assert.equal(h.sender.inflight, 1);
  await h.ok(0);
  assert.equal(h.sender.stats.sent, 1);
  await h.advance(199);
  assert.equal(h.calls.length, 1);
  await h.advance(1);
  assert.deepEqual(sig(h), ['a:brightness=10', 'a:colorRgb=1122867']);
});

test('dimming goes before a simultaneous color change; brightening alternates with color', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 1, brightness: 50 });
  await h.ok(0);
  await h.advance(500);
  await h.ok(1); // sent: brightness 50, colorRgb 1
  h.sender.push('a', { rgb: 2, brightness: 20 }); // cap lowered + new color
  await h.advance(500);
  assert.deepEqual(h.calls.at(-1) && [h.calls.at(-1)!.field, h.calls.at(-1)!.value], ['brightness', 20]);
  await h.ok(2);
  await h.advance(500);
  await h.ok(3);
  h.sender.push('a', { rgb: 3, brightness: 40 }); // brighter + new color: alternates (color went last)
  await h.advance(500);
  assert.deepEqual([h.calls.at(-1)!.field, h.calls.at(-1)!.value], ['brightness', 40]);
  await h.ok(4);
  await h.advance(500);
  assert.deepEqual([h.calls.at(-1)!.field, h.calls.at(-1)!.value], ['colorRgb', 3]);
});

test('rapid pushes keep only the latest; superseded targets are counted and never written', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 10, brightness: 1 }); // brightness=1 sent now
  await h.ok(0);
  h.sender.push('a', { rgb: 20, brightness: 1 }); // supersedes unsent color 10
  h.sender.push('a', { rgb: 30, brightness: 1 }); // supersedes color 20
  assert.equal(h.sender.stats.superseded, 2);
  await h.advance(500);
  assert.deepEqual(h.calls.map((c) => [c.field, c.value]), [['brightness', 1], ['colorRgb', 30]]);
  assert.ok(!h.calls.some((c) => c.value === 10 || c.value === 20));
});

test('rate cap: the second send waits one interval; setRate clamps to 0.5..10 Hz', async () => {
  const fast = harness();
  fast.sender.setRate(20); // clamped to 10 Hz = 100 ms
  fast.sender.push('a', { rgb: 1, brightness: 1 });
  await fast.ok(0);
  await fast.advance(99);
  assert.equal(fast.calls.length, 1);
  await fast.advance(1);
  assert.equal(fast.calls.length, 2);

  const slow = harness();
  slow.sender.setRate(0.1); // clamped to 0.5 Hz = 2000 ms
  slow.sender.setRate(NaN); // ignored
  slow.sender.push('a', { rgb: 1, brightness: 1 });
  await slow.ok(0);
  await slow.advance(1999);
  assert.equal(slow.calls.length, 1);
  await slow.advance(1);
  assert.equal(slow.calls.length, 2);
});

test('at most one write in flight per device; pending target goes out after it settles', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 1, brightness: 10 });
  h.sender.push('a', { rgb: 2, brightness: 20 });
  await h.advance(10_000);
  assert.equal(h.calls.length, 1);
  assert.equal(h.sender.inflight, 1);
  await h.ok(0);
  // Brightness went first (unknown before), so the newest color follows; the interval has long passed.
  assert.deepEqual(sig(h), ['a:brightness=10', 'a:colorRgb=2']);
  assert.equal(h.sender.inflight, 1);
});

test('when color and brightness both changed, the fields alternate across slots', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 5, brightness: 50 });
  await h.ok(0);
  await h.advance(500);
  await h.ok(1);
  h.sender.push('a', { rgb: 6, brightness: 60 });
  await h.advance(500);
  await h.ok(2);
  await h.advance(500);
  assert.deepEqual(h.calls.map((c) => c.field), ['brightness', 'colorRgb', 'brightness', 'colorRgb']);
  assert.deepEqual(h.calls.map((c) => c.value), [50, 5, 60, 6]);
});

test('an unchanged target sends nothing and is not counted as superseded', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 5, brightness: 50 });
  await h.ok(0);
  await h.advance(500);
  await h.ok(1);
  h.sender.push('a', { rgb: 5, brightness: 50 });
  await h.advance(10_000);
  assert.equal(h.calls.length, 2);
  assert.equal(h.sender.stats.superseded, 0);
});

test('remove() drops the pending target and resolves only after the in-flight write settles', async () => {
  const h = harness();
  const events: string[] = [];
  h.sender.push('a', { rgb: 1, brightness: 10 });
  h.sender.push('a', { rgb: 2, brightness: 20 }); // pending behind the in-flight write
  const removed = h.sender.remove('a').then(() => events.push('removed'));
  await flush();
  assert.equal(events.length, 0);
  h.call(0).resolve();
  events.push('settled');
  await removed;
  assert.deepEqual(events, ['settled', 'removed']);
  await h.advance(10_000);
  assert.equal(h.calls.length, 1);
  assert.equal(h.sender.inflight, 0);
});

test('remove() cancels a rate-limit timer, and resolves at once when nothing is in flight', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 1, brightness: 10 });
  await h.ok(0); // brightness now waits on a timer
  await h.sender.remove('a');
  await h.advance(10_000);
  assert.equal(h.calls.length, 1);
  await h.sender.remove('unknown');
});

test('stop() waits for every in-flight write, discards pending targets, and ignores later pushes', async () => {
  const h = harness();
  const events: string[] = [];
  h.sender.push('a', { rgb: 1, brightness: 10 });
  h.sender.push('b', { rgb: 3, brightness: 30 });
  h.sender.push('a', { rgb: 2, brightness: 20 });
  const stopped = h.sender.stop().then(() => events.push('stopped'));
  h.sender.push('c', { rgb: 9, brightness: 90 });
  await h.ok(0);
  assert.equal(events.length, 0);
  await h.ok(1);
  await stopped;
  assert.deepEqual(events, ['stopped']);
  h.sender.push('a', { rgb: 7, brightness: 70 });
  await h.advance(10_000);
  assert.deepEqual(sig(h), ['a:brightness=10', 'b:brightness=30']);
});

test('write failures count errors; onFatal fires after maxErrors consecutive failures', async () => {
  const fatal: string[] = [];
  const h = harness({ maxErrors: 3, onFatal: (id) => fatal.push(id) });
  // Warm up so each later push sends exactly one colorRgb write.
  h.sender.push('a', { rgb: 1, brightness: 50 });
  await h.ok(0);
  await h.advance(500);
  await h.ok(1);
  let n = 1;
  const step = async (succeed: boolean) => {
    await h.advance(500);
    h.sender.push('a', { rgb: ++n, brightness: 50 });
    await (succeed ? h.ok(h.calls.length - 1) : h.fail(h.calls.length - 1));
  };

  await step(false);
  await step(false);
  assert.deepEqual(fatal, []);
  await step(true); // success resets the consecutive counter
  await step(false);
  await step(false);
  assert.deepEqual(fatal, []);
  await step(false);
  assert.deepEqual(fatal, ['a']);
  assert.equal(h.sender.stats.errors, 5);
  assert.equal(h.sender.stats.sent, 3);
});

test('devices are independent: one stuck write does not block another', async () => {
  const h = harness();
  h.sender.push('a', { rgb: 1, brightness: 10 }); // never settles
  h.sender.push('b', { rgb: 2, brightness: 20 });
  assert.deepEqual(sig(h), ['a:brightness=10', 'b:brightness=20']);
  assert.equal(h.sender.inflight, 2);
  await h.ok(1);
  await h.advance(500);
  assert.deepEqual(sig(h), ['a:brightness=10', 'b:brightness=20', 'b:colorRgb=2']);
});

test('a second remove() during an in-flight write is still a barrier; onFatal fires once', async () => {
  const fatal: string[] = [];
  const h = harness({ maxErrors: 1, onFatal: (id) => fatal.push(id) });
  const events: string[] = [];
  h.sender.push('a', { rgb: 1, brightness: 10 });
  const first = h.sender.remove('a').then(() => events.push('first'));
  const second = h.sender.remove('a').then(() => events.push('second'));
  await flush();
  assert.deepEqual(events, []);
  await h.ok(0);
  await Promise.all([first, second]);
  assert.deepEqual(events.sort(), ['first', 'second']);

  h.sender.push('b', { rgb: 1, brightness: 10 });
  h.call(1).resolve();
  await h.advance(500);
  await h.fail(2); // a color failure: maxErrors 1 reached once
  h.sender.push('b', { rgb: 2, brightness: 10 });
  await h.advance(500);
  await h.fail(3);
  assert.deepEqual(fatal, ['b'], 'onFatal fires once, at maxErrors');
});

test('a rejected brightness write is fatal at once: no retry and no color for that light', async () => {
  const fatal: string[] = [];
  const h = harness({ maxErrors: 5, onFatal: (id) => fatal.push(id) });
  h.sender.push('a', { rgb: 0xff0000, brightness: 10 });
  assert.deepEqual(sig(h), ['a:brightness=10']);
  await h.fail(0);
  assert.deepEqual(fatal, ['a']);
  h.sender.push('a', { rgb: 0x00ff00, brightness: 5 });
  await h.advance(10_000);
  assert.deepEqual(sig(h), ['a:brightness=10'], 'nothing else is ever sent to that light');
  await h.sender.remove('a');
});

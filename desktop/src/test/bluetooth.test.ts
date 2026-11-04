// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Bluetooth lights controller (main): chooser, the evidenced connection order, readback-gated
// controls, 60 ms pacing and the 20 s silence drop. GATT bytes are faked; no hardware.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BluetoothController } from '../main/bluetooth';
import { frame, power, queryFrame } from '../core/ble';

function fixture() {
  let now = 0;
  const timers: Array<{ at: number; fn: () => void; every?: number; id: number }> = [];
  let nextID = 1;
  const clock = {
    now: () => now,
    setTimeout: ((fn: () => void, ms: number) => { const id = nextID++; timers.push({ at: now + ms, fn, id }); return id; }) as unknown as typeof setTimeout,
    setInterval: ((fn: () => void, ms: number) => { const id = nextID++; timers.push({ at: now + ms, fn, every: ms, id }); return id; }) as unknown as typeof setInterval,
    clearTimeout: ((id: number) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); }) as unknown as typeof clearTimeout,
    clearInterval: ((id: number) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); }) as unknown as typeof clearInterval,
  };
  const advance = (ms: number) => {
    const end = now + ms;
    for (;;) {
      timers.sort((a, b) => a.at - b.at);
      const t = timers[0];
      if (!t || t.at > end) break;
      now = t.at;
      if (t.every) t.at += t.every; else timers.shift();
      t.fn();
    }
    now = end;
  };
  const posts: Array<[string, unknown]> = [];
  const ble = new BluetoothController({ emit: () => {}, post: (c, p) => posts.push([c, p]), supported: true, clock });
  const writes = () => posts.filter(([c]) => c === 'luma:ble-write').map(([, p]) => p as number[]);
  return { ble, posts, writes, advance };
}

/** H6097, Pact 1/1, no encryption flag: the plaintext path with the full profile. */
const plainAd = [0x00, 0x88, 0xec, 0x00, 0x01, 0x01];

async function connect(f: ReturnType<typeof fixture>) {
  let chosen = '';
  await f.ble.handle('scan');
  f.ble.found([{ deviceId: 'a', deviceName: 'Govee_H6097_1A2B' }, { deviceId: 'b', deviceName: 'Some speaker' }], (id) => { chosen = id; });
  assert.deepEqual(f.ble.view().nearby.map((n) => [n.id, n.connectable]), [['a', true]]);
  await f.ble.handle('choose', 'a');
  assert.equal(chosen, 'a');
  assert.equal(await f.ble.handle('secure', { marker: 'absent', advertisement: plainAd, rssi: -60 }), true);
  await f.ble.handle('notifying');
  f.advance(1000);
}

test('connects in order, reads state, and gates controls on readback', async () => {
  const f = fixture();
  await connect(f);
  const v = f.ble.view();
  assert.equal(v.phase, 'ready');
  assert.equal(v.connected?.encryption, 'Not encrypted');
  assert.equal(v.connected?.videoMode, true);
  // Status queries go out paced, power first.
  assert.deepEqual(f.writes()[0], queryFrame('power'));
  assert.ok(f.writes().length >= 5);

  // Power isn't controllable until the light reports it.
  const before = f.writes().length;
  await f.ble.handle('send', { kind: 'power', on: true });
  f.advance(200);
  assert.equal(f.writes().length, before);

  await f.ble.handle('notify', frame([0xaa, 0x01, 0x00]));
  assert.equal(f.ble.view().readback.power, false);
  await f.ble.handle('send', { kind: 'power', on: true });
  f.advance(200);
  assert.deepEqual(f.writes().slice(before), [power(true), queryFrame('power')]);
  await f.ble.handle('notify', frame([0xaa, 0x04, 50]));
  assert.equal(f.ble.view().readback.brightness, 50);
  await assert.rejects(f.ble.handle('send', { kind: 'brightness', value: 0 }), /Invalid value/);
});

test('drops a light that stops answering, and tells the renderer', async () => {
  const f = fixture();
  await connect(f);
  f.advance(26_000);
  const v = f.ble.view();
  assert.equal(v.phase, 'failed');
  assert.equal(v.message, 'The light stopped answering.');
  assert.ok(f.posts.some(([c]) => c === 'luma:ble-disconnect'));
});

test('an unprofiled model is listed but cannot be chosen; scans time out', async () => {
  const f = fixture();
  let cancelled = 'unset';
  await f.ble.handle('scan');
  f.ble.found([{ deviceId: 'x', deviceName: 'Govee_H6008_AB12' }], (id) => { cancelled = id; });
  assert.equal(f.ble.view().nearby[0]?.connectable, false);
  await assert.rejects(f.ble.handle('choose', 'x'), /supported light/);
  f.advance(15_000);
  assert.equal(cancelled, '');
  assert.equal(f.ble.view().phase, 'idle');
});

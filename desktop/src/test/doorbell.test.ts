// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Doorbell alert: engine on a virtual clock, plus Home-level LAN wire evidence through a
// fake UDP light, webhook replay checks, manual takeover, and the relay client.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CapabilityCommand, LightDevice } from '../shared/types';
import { brightness, kelvin, power, rgb } from '../core/model';
import { DoorbellEngine, RelayClient, alertTargets, decodeDoorbell, defaultDoorbell, snapshotOf, type AlertClock, type DoorbellConfig, type Route } from '../core/doorbell';
import { GoveeLan, type UdpSocketLike } from '../core/lan';
import { createApiHandler } from '../core/api';
import { Home } from '../main/home';
import type { SecretStore } from '../main/storage';

const caps = ['powerSwitch', 'brightness', 'colorRgb', 'colorTemperatureK'].map((instance) => ({ type: 'x', instance }));
const light = (id: string, over: Partial<LightDevice> = {}): LightDevice => ({ id, sku: 'H6008', name: id, room: 'Hall', capabilities: caps, power: true, brightness: 60, rgb: 0x112233, colorTemperature: 0, online: true, ...over });

class VirtualClock implements AlertClock {
  t = 0;
  at: Array<[number, () => void]> = [];
  now() { return this.t; }
  date() { return new Date(2026, 10, 2, 12, 0); }
  async sleep(ms: number, signal: AbortSignal) {
    if (signal.aborted) throw new Error('stopped');
    this.t += ms;
    const due = this.at.filter(([t]) => t <= this.t);
    this.at = this.at.filter(([t]) => t > this.t);
    for (const [, action] of due) action();
    await new Promise((resolve) => setImmediate(resolve));
    if (signal.aborted) throw new Error('stopped');
  }
}

function fakeHome(devices: LightDevice[], routes: Record<string, Route> = {}) {
  const clock = new VirtualClock();
  const writes: Array<{ t: number; id: string; command: CapabilityCommand; restore: boolean }> = [];
  const logs: string[] = [];
  const failAfter = new Map<string, number>();
  let restoring = false;
  const apply = (id: string, c: CapabilityCommand) => {
    const d = devices.find((x) => x.id === id)!, n = c.value as number;
    if (c.instance === 'powerSwitch') d.power = n === 1; else if (c.instance === 'brightness') d.brightness = n;
    else if (c.instance === 'colorRgb') { d.rgb = n; d.colorTemperature = 0; } else d.colorTemperature = n;
  };
  const engine = new DoorbellEngine({
    devices: () => devices,
    prepare: async (targets) => targets.map((d) => { try { return { id: d.id, name: d.name, route: routes[d.id] ?? 'lan', snapshot: snapshotOf(d) }; } catch (e) { return { id: d.id, name: d.name, route: 'lan', skip: (e as Error).message }; } }),
    pulse: async (id, command) => {
      if ((failAfter.get(id) ?? Infinity) <= clock.t && !restoring) throw new Error('light offline');
      writes.push({ t: clock.t, id, command, restore: restoring }); apply(id, command);
    },
    restore: async (id, snapshot) => {
      restoring = true;
      try { for (const c of (await import('../core/doorbell')).restoreCommands(snapshot)) { writes.push({ t: clock.t, id, command: c, restore: true }); apply(id, c); } }
      finally { restoring = false; }
      return (await import('../core/doorbell')).snapshotMatches(snapshot, devices.find((d) => d.id === id)!);
    },
    log: (text) => logs.push(text),
    changed: () => {},
  }, clock);
  const configure = (over: Partial<DoorbellConfig> = {}) => { engine.config = { ...defaultDoorbell(), enabled: true, rooms: ['Hall'], durationSeconds: 6, ...over }; };
  const ring = async (id = String(Math.random())) => { const o = engine.trigger(id); await engine.settle(); return o; };
  const pulses = (id: string) => writes.filter((w) => w.id === id && !w.restore);
  const restores = (id: string) => writes.filter((w) => w.id === id && w.restore).map((w) => w.command);
  return { clock, engine, writes, logs, failAfter, configure, ring, pulses, restores, devices };
}

test('doorbell: timed slow pulse, cloud hold, and exact restore including an off white lamp', async () => {
  const f = fakeHome([light('lamp'), light('off', { power: false, brightness: 30, colorTemperature: 2700 }), light('cloud', { rgb: 0xff0000 })], { cloud: 'cloud' });
  f.configure();
  assert.equal(await f.ring('e1'), 'started');
  assert.deepEqual(f.pulses('off').slice(0, 3).map((w) => w.command), [power(true), rgb(0x2f7bff), brightness(100)]);
  assert.deepEqual(f.pulses('lamp').slice(2).map((w) => w.command.value), [20, 100, 20, 100, 20]);
  const lamp = f.pulses('lamp').filter((w) => w.command.instance === 'brightness');
  for (let i = 1; i < lamp.length; i++) assert.ok(lamp[i]!.t - lamp[i - 1]!.t >= 990, 'at most one brightness change per second');
  assert.deepEqual(f.pulses('cloud').map((w) => w.command), [rgb(0x2f7bff), brightness(100)]);
  assert.deepEqual(f.restores('off'), [kelvin(2700), brightness(30), power(false)]);
  assert.deepEqual(f.restores('lamp'), [rgb(0x112233), brightness(60), power(true)]);
  assert.match(f.engine.status, /^Flashed 3 lights; restored 3/);
});

test('doorbell: unknown state is skipped, manual change wins, failed writes still restore', async () => {
  const f = fakeHome([light('nopower', { power: undefined }), light('nocolor', { rgb: undefined, colorTemperature: 0 }), light('a'), light('b'), light('flaky')]);
  f.configure();
  f.failAfter.set('flaky', 2000);
  f.clock.at.push([2500, () => f.engine.yield('a')]);
  await f.ring();
  assert.ok(!f.writes.some((w) => w.id === 'nopower' || w.id === 'nocolor'));
  assert.ok(f.logs.some((l) => l.includes('nopower (power unknown)') && l.includes('nocolor (color unknown)')));
  assert.ok(f.pulses('a').every((w) => w.t < 2500));
  assert.deepEqual(f.restores('a'), []);
  assert.deepEqual(f.restores('b'), [rgb(0x112233), brightness(60), power(true)]);
  assert.ok(f.pulses('flaky').every((w) => w.t < 2000));
  assert.deepEqual(f.restores('flaky'), [rgb(0x112233), brightness(60), power(true)]);
  assert.match(f.engine.status, /1 left as changed during the alert/);
});

test('doorbell: rings coalesce, replays are ignored, cooldown and quiet hours hold', async () => {
  const f = fakeHome([light('a')]);
  f.configure({ cooldownSeconds: 20 });
  assert.equal(f.engine.trigger('e1'), 'started');
  assert.equal(f.engine.trigger('e2'), 'coalesced');
  assert.equal(f.engine.trigger('e1'), 'duplicate');
  await f.engine.settle();
  assert.equal(f.engine.trigger('e3'), 'cooldown');
  f.clock.t += 20_000;
  f.configure({ quietStart: 11 * 60, quietEnd: 13 * 60, quietBrightnessCap: 0 });
  assert.equal(await f.ring(), 'quiet');
  f.configure({ quietStart: 11 * 60, quietEnd: 13 * 60, quietBrightnessCap: 30 });
  const before = f.writes.length;
  assert.equal(await f.ring(), 'started');
  assert.equal(Math.max(...f.writes.slice(before).filter((w) => w.command.instance === 'brightness' && !w.restore).map((w) => w.command.value as number)), 30);
});

test('doorbell: stop restores early; shutdown hands back owed restores; settings are bounded', async () => {
  const f = fakeHome([light('a')]);
  f.configure({ durationSeconds: 30 });
  f.clock.at.push([1500, () => f.engine.stop()]);
  await f.ring();
  assert.ok(f.pulses('a').at(-1)!.t < 2000);
  assert.deepEqual(f.restores('a'), [rgb(0x112233), brightness(60), power(true)]);

  const g = fakeHome([light('a'), light('b')]);
  g.configure({ durationSeconds: 30 });
  let owed: ReturnType<DoorbellEngine['takePendingRestores']> = [];
  g.clock.at.push([3000, () => { owed = g.engine.takePendingRestores(); }]);
  await g.ring();
  assert.deepEqual(owed.map((o) => o.id), ['a', 'b']);
  assert.equal(g.engine.phase, 'idle');

  assert.throws(() => decodeDoorbell({ ...defaultDoorbell(), pulseSeconds: 1 }));
  assert.throws(() => decodeDoorbell({ ...defaultDoorbell(), relayURL: 'http://relay.example' }));
  const heater = light('heater', { deviceType: 'devices.types.heater' });
  assert.deepEqual(alertTargets({ ...defaultDoorbell(), rooms: ['Hall'] }, [heater, light('x')]).map((d) => d.id), ['x']);
});

/** A UDP socket that behaves like one LAN light: applies commands and answers devStatus. */
class LanLight implements UdpSocketLike {
  sent: any[] = [];
  state = { onOff: 1, brightness: 60, color: { r: 0x11, g: 0x22, b: 0x33 }, colorTemInKelvin: 0 };
  private onMessage?: (msg: Buffer, rinfo: { address: string; family: string }) => void;
  bind(_port: number, cb: () => void) { queueMicrotask(cb); }
  on(event: 'message' | 'error', cb: never) { if (event === 'message') this.onMessage = cb; }
  addMembership() {}
  setMulticastTTL() {}
  close() {}
  send(msg: Buffer, _port: number, address: string, cb?: (err: Error | null) => void) {
    const { cmd, data } = JSON.parse(msg.toString('utf8')).msg;
    this.sent.push({ cmd, data });
    if (cmd === 'turn') this.state.onOff = data.value;
    if (cmd === 'brightness') this.state.brightness = data.value;
    if (cmd === 'colorwc') { this.state.color = data.color; this.state.colorTemInKelvin = data.colorTemInKelvin; }
    if (cmd === 'devStatus') setImmediate(() => this.inject({ msg: { cmd: 'devStatus', data: this.state } }, address));
    cb?.(null);
  }
  inject(data: unknown, address: string) { this.onMessage?.(Buffer.from(JSON.stringify(data)), { address, family: 'IPv4' }); }
  wire() { return this.sent.filter((p) => p.cmd !== 'scan').map((p) => p.cmd === 'colorwc' ? `colorwc:${((p.data.color.r << 16) | (p.data.color.g << 8) | p.data.color.b).toString(16)}` : p.cmd === 'devStatus' ? 'devStatus' : `${p.cmd}:${p.data.value}`); }
}

const secrets = (): SecretStore => { const m = new Map<string, string>(); return { available: true, read: (k) => m.get(k), write: (k, v) => void m.set(k, v), delete: (k) => void m.delete(k) }; };

async function lanHome() {
  const socket = new LanLight();
  const clock = new VirtualClock();
  const home = new Home({ demo: false, version: 't', secrets: secrets(), createLan: (h) => new GoveeLan(h, () => socket), doorbellOptions: { clock } });
  await home.discover();
  socket.inject({ msg: { cmd: 'scan', data: { ip: '192.168.1.60', device: 'AA:BB:CC:DD:EE:60', sku: 'H6008' } } }, '192.168.1.60');
  const id = home.confirmedDevices()[0]!.id;
  await new Promise((resolve) => setTimeout(resolve, 5)); // the status reply must be newer than discovery
  home.doorbell.update({ ...defaultDoorbell(), enabled: true, rooms: ['Unassigned'], durationSeconds: 5 });
  return { home, socket, clock, id };
}

test('doorbell on Home: LAN wire shows a fresh status read, slow pulses, exact restore, and a confirming read', async () => {
  const { home, socket } = await lanHome();
  try {
    socket.sent = [];
    assert.equal(home.doorbell.trigger('ring-1'), 'started');
    await home.doorbell.engine.settle();
    assert.deepEqual(socket.wire(), ['devStatus', 'colorwc:2f7bff', 'brightness:100', 'brightness:20', 'brightness:100', 'brightness:20', 'brightness:100', 'colorwc:112233', 'brightness:60', 'turn:1', 'devStatus']);
    assert.match(home.snapshot().doorbell.status, /^Flashed 1 light; restored 1\./);
    const d = home.confirmedDevices()[0]!;
    assert.deepEqual([d.power, d.brightness, d.rgb], [true, 60, 0x112233]);
  } finally { await home.shutdown(); }
});

test('doorbell on Home: a manual control during the alert wins and is not restored over', async () => {
  const { home, socket, clock, id } = await lanHome();
  try {
    clock.at.push([2000, () => { void home.control(id, brightness(10)); }]);
    socket.sent = [];
    home.doorbell.trigger('ring-2');
    await home.doorbell.engine.settle();
    const after = socket.wire().slice(socket.wire().indexOf('brightness:10'));
    assert.ok(!after.some((w) => w.startsWith('colorwc') || w === 'brightness:100' || w === 'brightness:20'), after.join(','));
    assert.match(home.snapshot().doorbell.status, /1 left as changed during the alert/);
  } finally { await home.shutdown(); }
});

test('doorbell webhook route: bearer-protected server hands it eventId and timestamp, replays rejected', async () => {
  const home = new Home({ demo: true, version: 't', doorbellOptions: { clock: new VirtualClock() } });
  try {
    const handler = createApiHandler({ demo: true, devices: () => [], scenes: () => [], runs: () => [], runScene: () => 'x', doorbell: (m, r, b) => home.doorbell.api(m, r, b) });
    const post = (body: unknown, path = '/v1/alerts/doorbell') => handler({ method: 'POST', path, body: Buffer.from(JSON.stringify(body)) });
    const now = Date.now() / 1000;
    assert.equal((await post({ eventId: 'short', timestamp: now })).status, 400);
    assert.equal((await post({ eventId: 'ring-0001', timestamp: now - 600 })).status, 409);
    assert.deepEqual(((await post({ eventId: 'ring-0001', timestamp: now })).body as any).outcome, 'started');
    assert.deepEqual(((await post({ eventId: 'ring-0001', timestamp: now })).body as any).outcome, 'duplicate');
    assert.equal((await post({}, '/v1/alerts/doorbell/stop')).status, 202);
    assert.equal((await handler({ method: 'GET', path: '/v1/alerts/doorbell', body: Buffer.alloc(0) })).status, 200);
    await home.doorbell.engine.settle();
  } finally { await home.shutdown(); }
});

test('relay client: bearer auth, https only, and only fresh well-formed events', async () => {
  const token = 't'.repeat(43);
  const seen: any[] = [];
  const reply = (status: number, body: unknown) => ({ status, json: async () => body });
  let next = reply(200, { events: [{ id: 'm1', type: 'activate', issuedAt: 1_800_000_000 }, { id: 'old', type: 'activate', issuedAt: 1_799_999_000 }, { id: 'x', type: 'shell', issuedAt: 1_800_000_000 }] });
  const client = new RelayClient('https://relay.example/', token, async (url, init) => { seen.push({ url, init }); return next; });
  assert.deepEqual((await client.next(true, new AbortController().signal, 1_800_000_000_000)).map((e) => e.id), ['m1']);
  assert.equal(seen[0].url, 'https://relay.example/hub/next');
  assert.equal(seen[0].init.headers.authorization, `Bearer ${token}`);
  next = reply(401, {});
  await assert.rejects(client.next(true, new AbortController().signal));
  assert.throws(() => new RelayClient('http://relay.example', token));
  assert.throws(() => new RelayClient('https://relay.example', 'short'));
});

test('doorbell controller: a saved IP without a live LAN session is a cloud light, so it holds instead of pulsing', async () => {
  const { DoorbellController } = await import('../main/doorbell');
  const d = light('stale-ip', { ip: '192.168.1.70' });
  const writes: CapabilityCommand[] = [];
  const controller = new DoorbellController({
    demo: false, lights: () => [d], device: () => d, lanReady: () => false, busy: () => undefined,
    read: async () => true, write: async (_id, c) => { writes.push(c); }, log: () => {}, changed: () => {}, clock: new VirtualClock(),
  });
  controller.update({ ...defaultDoorbell(), enabled: true, rooms: ['Hall'], durationSeconds: 10 });
  controller.trigger('ring-stale-ip');
  await controller.engine.settle();
  assert.deepEqual(writes, [rgb(0x2f7bff), brightness(100), rgb(0x112233), brightness(60), power(true)]);
});

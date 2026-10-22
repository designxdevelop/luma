// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Screen Sync session controller and Home integration. No capture happens here: frames
// are synthetic region samples, LAN is a fake UDP socket, and timers are injected.

import assert from 'node:assert/strict';
import { test, type TestContext } from 'node:test';
import type { CapabilityCommand, LightDevice, SyncGrid } from '../shared/types';
import { GoveeLan, type UdpSocketLike } from '../core/lan';
import { brightness, power, rgb } from '../core/model';
import { Home } from '../main/home';
import { EventEmitter } from 'node:events';
import { CaptureGrants, SyncController, restoreCommands, stopOnRendererLoss, type SyncHost } from '../main/sync';
import type { StreamField } from '../core/stream';

const flush = () => new Promise<void>((r) => setImmediate(r));
const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
async function until(cond: () => boolean, what: string, ms = 3000): Promise<void> {
  const end = Date.now() + ms;
  while (!cond()) { if (Date.now() > end) assert.fail(`Timed out waiting for ${what}`); await wait(5); }
}
const color = (r: number, g: number, b: number): SyncGrid => ({ columns: 1, rows: 1, cells: [1, r, g, b, 1, r, g, b] });

// ---------- controller with a fake host ----------

const lan = (id: string, extra: Partial<LightDevice> = {}): LightDevice =>
  ({ id, sku: 'H6008', name: id.toUpperCase(), room: 'Room', ip: `192.168.1.${id.charCodeAt(0)}`, capabilities: [], power: true, brightness: 80, rgb: 0x336699, colorTemperature: 0, online: true, ...extra });

function controller(devices: LightDevice[], opts: { pending?: string[]; scene?: boolean; unseen?: string[] } = {}) {
  let t = 1000;
  const timers: Array<{ at: number; fn: () => void; dead: boolean }> = [];
  const writes: Array<{ id: string; field: StreamField; value: number; done(): void }> = [];
  const restores: Array<{ id: string; commands: CapabilityCommand[] }> = [];
  const logs: string[] = [];
  const host: SyncHost = {
    devices: () => devices,
    hasPending: (id) => opts.pending?.includes(id) ?? false,
    sceneRunning: () => opts.scene ?? false,
    lanReady: (d) => !opts.unseen?.includes(d.id),
    streamWrite: (id, field, value) => new Promise<void>((done) => writes.push({ id, field, value, done })),
    restore: async (id, commands) => { restores.push({ id, commands }); },
    changed: () => {},
    log: (text) => logs.push(text),
  };
  const sync = new SyncController(host, {
    demo: false, captureSupported: true, now: () => t,
    schedule: (fn, ms) => { const x = { at: t + ms, fn, dead: false }; timers.push(x); return () => { x.dead = true; }; },
  });
  const advance = async (ms: number) => {
    t += ms;
    for (const x of timers.filter((x) => !x.dead && x.at <= t)) { x.dead = true; x.fn(); }
    await flush();
  };
  const tick = () => { t += 100; };
  return { sync, writes, restores, logs, advance, tick };
}

test('start refuses ineligible lights, scenes, pending writes and bad selections', () => {
  const devices = [lan('a'), lan('b', { power: false }), lan('c', { ip: undefined, capabilities: [{ type: 'devices.capabilities.color_setting', instance: 'colorRgb' }] }), lan('d'), lan('e')];
  const c = controller(devices, { pending: ['d'], unseen: ['e'] });
  const reasons = Object.fromEntries(c.sync.eligibility().map((e) => [e.id, e.reason ?? 'ok']));
  assert.equal(reasons.a, 'ok');
  assert.match(reasons.b!, /Turn it on first/);
  assert.match(reasons.c!, /Cloud-only/);
  assert.match(reasons.d!, /still being confirmed/);
  assert.match(reasons.e!, /Not seen on your network/);
  for (const id of ['b', 'c', 'd', 'e']) assert.throws(() => c.sync.start([{ id, region: 'full' }], 'S'), (e: { status?: number }) => e.status === 409);
  assert.throws(() => c.sync.start([{ id: 'a', region: 'middle' }], 'S'), /Invalid light selection/);
  assert.throws(() => c.sync.start([{ id: 'a', region: 'full' }, { id: 'a', region: 'left' }], 'S'), /Invalid light selection/);
  assert.throws(() => c.sync.start([], 'S'), /at least one/);
  assert.throws(() => controller([lan('a')], { scene: true }).sync.start([{ id: 'a', region: 'full' }], 'S'), /scene is running/);
  assert.equal(c.sync.phase, 'idle');
});

test('nothing is sent before the first valid frame; stale, malformed, replayed and too-fast frames are rejected', async () => {
  const c = controller([lan('a')]);
  const { token, generation } = c.sync.start([{ id: 'a', region: 'full' }], 'Secret Window Title');
  assert.equal(c.sync.phase, 'starting');
  assert.equal(c.writes.length, 0);
  assert.equal(c.sync.frame('wrong', generation, 1, color(1, 0, 0)), false);
  assert.equal(c.sync.frame(token, generation + 1, 1, color(1, 0, 0)), false);
  assert.equal(c.sync.frame(token, generation, 1, { ...color(1, 0, 0), cells: [1, 2, 0, 0, 1, 2, 0, 0] }), false);
  assert.equal(c.sync.frame(token, generation, 1, { cells: [1, 1, 0, 0, 1, 1, 0, 0] }), false);
  assert.equal(c.writes.length, 0);
  assert.equal(c.sync.frame(token, generation, 1, color(1, 0, 0)), true);
  assert.equal(c.sync.phase, 'running');
  assert.equal(c.writes.length, 1);
  assert.equal(c.sync.frame(token, generation, 2, color(0, 1, 0)), false, 'faster than 60 fps');
  c.tick();
  assert.equal(c.sync.frame(token, generation, 1, color(0, 1, 0)), false, 'replayed seq');
  const stopped = c.sync.stop('Stopped.', true);
  await c.advance(2000); // a datagram that never settles is bounded by the drain timeout
  await stopped;
  c.tick();
  assert.equal(c.sync.frame(token, generation, 5, color(0, 0, 1)), false, 'after stop');
  assert.ok(c.logs.every((l) => !l.includes('Secret Window Title')), 'source titles are not logged');
});

test('first stream write is the capped brightness, never a full-scale color', () => {
  const c = controller([lan('a', { brightness: 80 })]);
  c.sync.setSettings({ brightnessCap: 10 });
  const { token, generation } = c.sync.start([{ id: 'a', region: 'left' }], 'S');
  c.sync.frame(token, generation, 1, color(1, 1, 1));
  assert.deepEqual(c.writes.map((w) => [w.field, w.value]), [['brightness', 10]]);
});

test('lowering the cap is sent even when the change threshold is large', async () => {
  const c = controller([lan('a')]);
  c.sync.setSettings({ brightnessCap: 80, threshold: 0.2, smoothing: 0 });
  const { token, generation } = c.sync.start([{ id: 'a', region: 'full' }], 'S');
  c.sync.frame(token, generation, 1, color(1, 1, 1));
  c.writes[0]!.done();
  await c.advance(500);
  c.writes[1]!.done();
  await flush();
  assert.deepEqual(c.writes.map((w) => [w.field, w.value]), [['brightness', 80], ['colorRgb', 0xffffff]]);
  c.sync.setSettings({ brightnessCap: 75 }); // 5% < 20% threshold, still must apply
  await c.advance(500);
  assert.deepEqual(c.writes.at(-1) && [c.writes.at(-1)!.field, c.writes.at(-1)!.value], ['brightness', 75]);
});

test('manual exclusion waits for the in-flight stream write, including a second rapid call', async () => {
  const c = controller([lan('a'), lan('b')]);
  const { token, generation } = c.sync.start([{ id: 'a', region: 'full' }, { id: 'b', region: 'full' }], 'S');
  c.sync.frame(token, generation, 1, color(1, 0, 0));
  const inflight = c.writes.find((w) => w.id === 'a')!;
  const order: string[] = [];
  const first = c.sync.exclude('a').then(() => order.push('first'));
  const second = c.sync.exclude('a').then(() => order.push('second'));
  await flush();
  assert.equal(order.length, 0, 'neither manual write may go before the stream datagram settles');
  assert.equal(c.sync.isStreaming('a'), false);
  order.push('datagram');
  inflight.done();
  await Promise.all([first, second]);
  assert.equal(order[0], 'datagram');
  const before = c.writes.length;
  c.tick();
  c.sync.frame(token, generation, 2, color(0, 0, 1));
  await c.advance(2000);
  assert.ok(c.writes.slice(before).every((w) => w.id !== 'a'), 'an excluded light gets no more stream writes');
  assert.equal(c.sync.phase, 'running');
});

test('explicit stop drains, then restores last confirmed state in order; auto stops and excluded lights never restore', async () => {
  const c = controller([lan('a', { brightness: 40, rgb: 0x123456, colorTemperature: 0 }), lan('b', { brightness: 60, colorTemperature: 3000 })]);
  c.sync.setSettings({ restore: true });
  const { token, generation } = c.sync.start([{ id: 'a', region: 'full' }, { id: 'b', region: 'full' }], 'S');
  c.sync.frame(token, generation, 1, color(1, 0, 0));
  let stopped = false;
  const stopping = c.sync.stop('Stopped.', true).then(() => { stopped = true; });
  await flush();
  assert.equal(c.restores.length, 0, 'restore waits for in-flight stream writes');
  assert.equal(stopped, false);
  for (const w of c.writes) w.done();
  await stopping;
  assert.deepEqual(c.restores.map((r) => [r.id, r.commands.map((x) => `${x.instance}=${x.value}`)]), [
    ['a', ['brightness=40', `colorRgb=${0x123456}`]],
    ['b', ['brightness=60', 'colorTemperatureK=3000']],
  ]);

  const auto = controller([lan('a')]);
  auto.sync.setSettings({ restore: true });
  auto.sync.start([{ id: 'a', region: 'full' }], 'S');
  await auto.sync.stop('Displays changed.');
  assert.equal(auto.restores.length, 0);

  const manual = controller([lan('a'), lan('b')]);
  manual.sync.setSettings({ restore: true });
  manual.sync.start([{ id: 'a', region: 'full' }, { id: 'b', region: 'full' }], 'S');
  await manual.sync.exclude('a');
  await manual.sync.stop('Stopped.', true);
  assert.deepEqual(manual.restores.map((r) => r.id), ['b']);
});

test('restore never sends power and skips white outside the LAN range', () => {
  assert.deepEqual(restoreCommands({ brightness: 50, colorTemperature: 1500, rgb: 1 }).commands.map((c) => c.instance), ['brightness']);
  assert.match(restoreCommands({ brightness: 50, colorTemperature: 1500 }).skipped ?? '', /cannot be set over LAN/);
  assert.deepEqual(restoreCommands({}).commands, []);
});

test('start timeout and frame stall stop the session without restoring', async () => {
  const c = controller([lan('a')]);
  c.sync.setSettings({ restore: true });
  c.sync.start([{ id: 'a', region: 'full' }], 'S');
  await c.advance(15_000);
  await flush();
  assert.equal(c.sync.phase, 'idle');
  assert.match(c.sync.view().lastStop ?? '', /did not start/);
  const { token, generation } = c.sync.start([{ id: 'a', region: 'full' }], 'S');
  c.sync.frame(token, generation, 1, color(1, 0, 0));
  for (const w of c.writes) w.done();
  await c.advance(10_000);
  await flush();
  assert.equal(c.sync.phase, 'idle');
  assert.match(c.sync.view().lastStop ?? '', /stalled/);
  assert.equal(c.restores.length, 0);
});

test('pause stops sending; resume needs the session token', async () => {
  const c = controller([lan('a')]);
  const { token, generation } = c.sync.start([{ id: 'a', region: 'full' }], 'S');
  c.sync.frame(token, generation, 1, color(1, 0, 0));
  c.writes[0]!.done();
  c.sync.pause();
  c.tick();
  assert.equal(c.sync.frame(token, generation, 2, color(0, 1, 0)), false);
  await c.advance(5000);
  assert.equal(c.writes.length, 1);
  assert.throws(() => c.sync.resume('nope'));
  c.sync.resume(token);
  c.tick();
  assert.equal(c.sync.frame(token, generation, 3, color(0, 1, 0)), true);
});

test('capture grants: explicit list, fresh revalidation, single use, expiry, Wayland no re-enumeration', async () => {
  let t = 0, calls = 0;
  let sources = [{ id: 'screen:0:0', name: 'Display 1', kind: 'screen' as const }, { id: 'window:42:0', name: 'Movie', kind: 'window' as const }];
  const grants = new CaptureGrants(async () => { calls++; return sources; }, { now: () => t });
  assert.equal(calls, 0, 'nothing is enumerated until asked');
  const list = await grants.list();
  assert.equal(list.length, 2);
  assert.ok(list.every((s) => !('id' in s)), 'raw source IDs do not reach the renderer');
  sources = sources.slice(0, 1); // the window closed
  await assert.rejects(grants.resolve(list[1]!.key), /no longer available/);
  const again = await grants.list();
  await grants.resolve(again[0]!.key);
  await assert.rejects(grants.resolve(again[0]!.key), /again/, 'a list is used once');
  const pick = async () => grants.resolve((await grants.list())[0]!.key);
  grants.issue(await pick(), 7);
  assert.equal(grants.consume(6), undefined, 'wrong generation');
  assert.equal(grants.consume(7), undefined, 'single use, even after a failed attempt');
  grants.issue(await pick(), 8);
  t += 10_001;
  assert.equal(grants.consume(8), undefined, 'expired');
  grants.issue(await pick(), 9);
  assert.deepEqual(grants.consume(9), { id: 'screen:0:0', name: 'Display 1' });

  const before = calls;
  const wayland = new CaptureGrants(async () => { calls++; return sources; }, { revalidate: false });
  const picked = await wayland.list();
  await wayland.resolve(picked[0]!.key);
  assert.equal(calls - before, 1, 'the portal picker is not opened a second time');
});

/** An enumerate() whose calls each wait until the test settles them. */
function deferredSources() {
  const pending: Array<(s: Array<{ id: string; name: string; kind: 'screen' | 'window' }>) => void> = [];
  const sources: Array<{ id: string; name: string; kind: 'screen' | 'window' }> = [{ id: 'screen:0:0', name: 'Display 1', kind: 'screen' }];
  return { enumerate: () => new Promise<typeof sources>((r) => pending.push(r)), settle: (i: number) => pending[i]!(sources) };
}

test('capture grants: revoke and newer lists cancel pending list and resolve; nothing is granted after revocation', async () => {
  // list → revoke → enumeration resolves: no usable offers.
  let d = deferredSources();
  let grants = new CaptureGrants(d.enumerate);
  let listing = grants.list();
  grants.revoke();
  d.settle(0);
  await assert.rejects(listing, /cancelled/);

  // Two concurrent lists: only the newest yields offers; the older list's keys never exist.
  d = deferredSources();
  grants = new CaptureGrants(d.enumerate);
  const older = grants.list(), newer = grants.list();
  d.settle(1); d.settle(0);
  await assert.rejects(older, /cancelled/);
  const offers = await newer;
  assert.equal(offers.length, 1);

  // resolve → revoke (lock, display stop) → fresh enumeration resolves: start must not proceed.
  const resolving = grants.resolve(offers[0]!.key);
  grants.revoke();
  d.settle(2);
  await assert.rejects(resolving, /cancelled/);

  // resolve settled, then revoked before the adapter starts the session: current() and issue() refuse.
  listing = grants.list();
  d.settle(3);
  const chosen = grants.resolve((await listing)[0]!.key);
  d.settle(4);
  const source = await chosen;
  grants.revoke();
  assert.throws(() => grants.current(source.epoch), /cancelled/);
  assert.throws(() => grants.issue(source, 1), /cancelled/);
  assert.equal(grants.consume(1), undefined, 'no grant exists after revocation');

  // A new list while resolving also cancels the resolve.
  listing = grants.list();
  d.settle(5);
  const racing = grants.resolve((await listing)[0]!.key);
  const relist = grants.list();
  d.settle(6); d.settle(7);
  await assert.rejects(racing, /cancelled/);
  assert.equal((await relist).length, 1);

  // Wayland (no re-enumeration): revoke after the list was resolved still blocks the grant.
  d = deferredSources();
  const wayland = new CaptureGrants(d.enumerate, { revalidate: false });
  listing = wayland.list();
  d.settle(0);
  const picked = await wayland.resolve((await listing)[0]!.key);
  wayland.revoke();
  assert.throws(() => wayland.issue(picked, 1), /cancelled/);
});

test('renderer reload, navigation, crash, hang or destruction stops even a paused session, without restore', async () => {
  const fire = async (event: string, details?: unknown) => {
    const c = controller([lan('a')]);
    const contents = new EventEmitter();
    let revoked = 0;
    stopOnRendererLoss(contents, () => { revoked++; void c.sync.stop('Renderer lost.'); });
    const { token, generation } = c.sync.start([{ id: 'a', region: 'full' }], 'S');
    c.sync.frame(token, generation, 1, color(1, 0, 0));
    c.writes[0]!.done();
    c.sync.pause();
    contents.emit(event, details);
    contents.emit(event, details); // idempotent
    await c.advance(5000);
    return { c, revoked, token };
  };
  for (const [event, details] of [['did-start-navigation', { isMainFrame: true, isSameDocument: false }], ['render-process-gone', {}], ['unresponsive'], ['destroyed']] as const) {
    const { c, revoked, token } = await fire(event, details);
    assert.equal(revoked, 2, event);
    assert.equal(c.sync.phase, 'idle', `${event}: paused session stopped`);
    assert.equal(c.sync.ownsToken(token), false, `${event}: old token is dead`);
    assert.throws(() => c.sync.resume(token), `${event}: no resume`);
    assert.equal(c.restores.length, 0, `${event}: automatic stop never restores`);
  }
  for (const details of [{ isMainFrame: false, isSameDocument: false }, { isMainFrame: true, isSameDocument: true }]) {
    const { c, revoked } = await fire('did-start-navigation', details);
    assert.equal(revoked, 0);
    assert.equal(c.sync.phase, 'paused', 'subframe and same-document navigations keep the session');
  }
});

// ---------- Home integration (fake LAN socket, demo) ----------

class Socket implements UdpSocketLike {
  sent: Array<{ cmd: string; data: any; address: string; release(): void }> = [];
  hold = false;
  private onMessage?: (msg: Buffer, rinfo: { address: string; family: string }) => void;
  bind(_p: number, cb: () => void) { queueMicrotask(cb); }
  on(event: 'message' | 'error', cb: never) { if (event === 'message') this.onMessage = cb; }
  addMembership() {}
  setMulticastTTL() {}
  send(msg: Buffer, _port: number, address: string, cb?: (err: Error | null) => void) {
    const json = JSON.parse(msg.toString('utf8'));
    const entry = { cmd: json.msg.cmd as string, data: json.msg.data, address, release: () => cb?.(null) };
    this.sent.push(entry);
    if (!this.hold || entry.cmd === 'scan' || entry.cmd === 'devStatus') entry.release();
  }
  close() {}
  inject(data: unknown, address: string) { this.onMessage?.(Buffer.from(JSON.stringify(data)), { address, family: 'IPv4' }); }
}

const IP = '192.168.1.60';
async function lanHome(t: TestContext) {
  const socket = new Socket();
  const home = new Home({
    demo: false, version: 't', captureSupported: true,
    controlOptions: { confirmDelays: [5, 30], expireMs: 300, settleMs: 20 },
    createLan: (handlers) => new GoveeLan(handlers, () => socket),
  });
  t.after(() => home.shutdown());
  await home.discover();
  socket.inject({ msg: { cmd: 'scan', data: { ip: IP, device: 'L1', sku: 'H6008' } } }, IP);
  socket.inject({ msg: { cmd: 'devStatus', data: { onOff: 1, brightness: 40, color: { r: 1, g: 2, b: 3 }, colorTemInKelvin: 0 } } }, IP);
  assert.equal(home.confirmedDevices()[0]?.power, true);
  return { home, socket };
}

test('Home: stream goes over LAN only, without status reads; manual control waits for the datagram', async (t) => {
  const { home, socket } = await lanHome(t);
  const { token, generation } = home.sync.start([{ id: 'L1', region: 'full' }], 'S');
  socket.hold = true;
  const before = socket.sent.length;
  assert.equal(home.sync.frame(token, generation, 1, color(1, 0, 0)), true);
  const streamed = socket.sent.slice(before);
  assert.deepEqual(streamed.map((p) => p.cmd), ['brightness']);
  const manual = home.control('L1', power(false));
  const second = home.control('L1', brightness(20));
  await wait(20);
  assert.ok(!socket.sent.slice(before).some((p) => p.cmd === 'turn'), 'manual write waits for the in-flight stream datagram');
  socket.hold = false;
  streamed[0]!.release();
  await Promise.all([manual, second]);
  // devStatus here belongs to the normal engine writes' confirmation, never to the stream.
  const after = socket.sent.slice(before).map((p) => p.cmd).filter((c) => c !== 'devStatus');
  assert.deepEqual(after.slice(0, 3), ['brightness', 'turn', 'brightness']);
  assert.equal(home.snapshot().sync.lights[0]?.status, 'excluded');
  assert.ok(home.sync.active === false, 'every light taken over manually stops the session');
});

test('Home: start is refused while a light has pending writes; scenes and webhooks are refused while streaming', async (t) => {
  const { home } = await lanHome(t);
  void home.control('L1', brightness(70)).catch(() => {});
  assert.throws(() => home.sync.start([{ id: 'L1', region: 'full' }], 'S'), /still being confirmed/);
  await until(() => home.snapshot().pending.L1 === undefined, 'pending to settle', 2000);
  home.sync.start([{ id: 'L1', region: 'full' }], 'S');
  assert.throws(() => home.runScene({ id: 's', name: 'S', icon: 'sparkles', steps: [{ id: 'x', deviceID: 'L1', command: rgb(1), delayMilliseconds: 0 }] }), (e: { status?: number }) => e.status === 409);
  await home.sync.stop('Stopped.');
});

test('Home: restore is LAN-only and never falls back to cloud', async (t) => {
  const { home, socket } = await lanHome(t);
  home.sync.setSettings({ restore: true });
  const { token, generation } = home.sync.start([{ id: 'L1', region: 'full' }], 'S');
  home.sync.frame(token, generation, 1, color(0, 0, 1));
  await wait(10);
  const before = socket.sent.length;
  await home.sync.stop('Stopped.', true);
  await until(() => socket.sent.slice(before).some((p) => p.cmd === 'colorwc'), 'restore datagrams');
  const restored = socket.sent.slice(before).filter((p) => p.cmd !== 'devStatus');
  assert.deepEqual(restored.map((p) => p.cmd), ['brightness', 'colorwc']);
  assert.equal(restored[0]!.data.value, 40);
  assert.deepEqual(restored[1]!.data.color, { r: 1, g: 2, b: 3 });

  // With LAN gone, restore refuses instead of using cloud.
  await until(() => home.snapshot().pending.L1 === undefined, 'restore confirmation window to end');
  home.sync.start([{ id: 'L1', region: 'full' }], 'S');
  (home as unknown as { lan: GoveeLan }).lan.stop();
  await home.sync.stop('Stopped.', true);
  await until(() => home.snapshot().activity.some((a) => /never uses cloud/.test(a.message)), 'LAN-only refusal');
});

test('demo journey: synthetic frames stream to sample lights without changing confirmed state or saving', async (t) => {
  const home = new Home({ demo: true, version: 't' });
  t.after(() => home.shutdown());
  const before = JSON.stringify(home.confirmedDevices());
  const snap = home.snapshot();
  assert.equal(snap.sync.synthetic, true);
  assert.equal(snap.sync.captureSupported, false);
  const ids = snap.sync.eligibility.filter((e) => e.eligible).map((e) => e.id);
  assert.ok(ids.length > 0);
  const { token, generation } = home.sync.start(ids.map((id, i) => ({ id, region: (['left', 'right', 'full'] as const)[i % 3] })), 'Synthetic film (demo)');
  for (let seq = 1; seq <= 4; seq++) {
    assert.equal(home.sync.frame(token, generation, seq, { columns: 3, rows: 1, cells: [[0.8, 0.1, 0], [0.1 * seq, 0.05, 0.02], [0, 0.2, 0.9]].flatMap((c) => [1, ...c, 1, ...c]) }), true);
    await wait(40);
  }
  await until(() => home.snapshot().sync.stats.sent > 0, 'demo sends');
  const view = home.snapshot().sync;
  assert.equal(view.phase, 'running');
  assert.ok(view.lights.every((l) => l.requestedRGB !== undefined));
  assert.equal(JSON.stringify(home.confirmedDevices()), before, 'stream previews never become confirmed state');
  await home.sync.stop('Stopped.', true);
  assert.equal(home.snapshot().sync.phase, 'idle');
  assert.equal(home.snapshot().canSave, false);
});

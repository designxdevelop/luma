// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Integration tests for the main-process app model (Home). Everything external is a fake:
// credential store (in-memory), disk (fresh tmp dir), Govee cloud (fake fetch), LAN (fake UDP
// socket). The only real I/O is loopback TCP for the webhook server.

import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import type { CapabilityCommand, LightDevice } from '../shared/types';
import type { FetchLike, HttpLike } from '../core/cloud';
import { GoveeLan, type UdpSocketLike } from '../core/lan';
import { LumaError, brightness, kelvin, power, rgb } from '../core/model';
import { minuteKey } from '../core/automation';
import { Home, lanEligible, mergeCapabilities } from '../main/home';
import { HomeStorage, type SecretStore } from '../main/storage';

const KEY = 'synthetic-key-123';
const A = 'AA:BB:CC:DD:EE:01'; // white range 1000…10000, no LAN at first
const B = 'AA:BB:CC:DD:EE:02'; // white range 2000…9000
const A_IP = '192.168.1.50';
const B_IP = '192.168.1.51';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
async function until(cond: () => boolean, what: string, ms = 3000): Promise<void> {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) assert.fail(`Timed out waiting for ${what}`);
    await wait(5);
  }
}

// ---------- fakes ----------

class MemSecrets implements SecretStore {
  readonly map = new Map<string, string>();
  touched = 0;
  constructor(readonly available = true) {}
  read(name: string) { this.touched++; return this.map.get(name); }
  write(name: string, value: string) { this.touched++; this.map.set(name, value); }
  delete(name: string) { this.touched++; this.map.delete(name); }
}

class FakeSocket implements UdpSocketLike {
  sent: Array<{ json: any; port: number; address: string }> = [];
  closed = false;
  private onMessage?: (msg: Buffer, rinfo: { address: string; family: string }) => void;
  bind(_port: number, cb: () => void): void { queueMicrotask(cb); }
  on(event: 'message' | 'error', cb: never): void { if (event === 'message') this.onMessage = cb; }
  addMembership(): void {}
  setMulticastTTL(): void {}
  send(msg: Buffer, port: number, address: string, cb?: (err: Error | null) => void): void {
    this.sent.push({ json: JSON.parse(msg.toString('utf8')), port, address });
    cb?.(null);
  }
  close(): void { this.closed = true; }
  inject(data: unknown, address: string): void {
    this.onMessage?.(Buffer.from(JSON.stringify(data)), { address, family: 'IPv4' });
  }
  cmds(cmd: string, sinceIndex = 0) { return this.sent.slice(sinceIndex).filter((p) => p.json.msg.cmd === cmd); }
}

const scanPacket = (id: string, ip: string) => ({ msg: { cmd: 'scan', data: { ip, device: id, sku: 'H6008' } } });
const statusPacket = (s: { onOff?: number; brightness?: number; rgb?: number; kelvin?: number }) => ({
  msg: { cmd: 'devStatus', data: {
    onOff: s.onOff ?? 1, brightness: s.brightness ?? 40,
    color: { r: ((s.rgb ?? 0x112233) >> 16) & 255, g: ((s.rgb ?? 0x112233) >> 8) & 255, b: (s.rgb ?? 0x112233) & 255 },
    colorTemInKelvin: s.kelvin ?? 0,
  } },
});

const BASE = 'https://openapi.api.govee.com/router/api/v1/';
const T = { onOff: 'devices.capabilities.on_off', range: 'devices.capabilities.range', color: 'devices.capabilities.color_setting' };
const capsFor = (white: [number, number]) => [
  { type: T.onOff, instance: 'powerSwitch', parameters: { dataType: 'ENUM', options: [{ name: 'on', value: 1 }, { name: 'off', value: 0 }] } },
  { type: T.range, instance: 'brightness', parameters: { dataType: 'INTEGER', range: { min: 1, max: 100, precision: 1 }, unit: 'unit.percent' } },
  { type: T.color, instance: 'colorRgb', parameters: { dataType: 'INTEGER', range: { min: 0, max: 16777215, precision: 1 } } },
  { type: T.color, instance: 'colorTemperatureK', parameters: { dataType: 'INTEGER', range: { min: white[0], max: white[1], precision: 1 } } },
];
const reply = (body: unknown, status = 200): HttpLike => ({ status, headers: { get: () => null }, text: async () => JSON.stringify(body) });

interface FakeState { power: number; brightness: number; rgb: number; kelvin: number }
interface Request { path: string; method: string; apiKey?: string; body?: any }

/** Synthetic Govee cloud. Control calls can be held open (slow cloud) and optionally do not change reported state. */
class FakeGovee {
  requests: Request[] = [];
  status = 200;
  autoApply = true;
  state = new Map<string, FakeState>([
    [A, { power: 1, brightness: 40, rgb: 0x112233, kelvin: 0 }],
    [B, { power: 0, brightness: 10, rgb: 0x445566, kelvin: 0 }],
  ]);
  /** Set by a test to hold the device list (a slow connect/reconnect). */
  devicesGate?: Promise<void>;
  private gate?: Promise<void>;
  private open?: () => void;

  hold(): void { this.gate = new Promise<void>((resolve) => { this.open = resolve; }); }
  release(): void { this.open?.(); this.open = undefined; this.gate = undefined; }
  controls() {
    return this.requests.filter((r) => r.path === 'device/control').map((r) => ({ id: r.body.payload.device as string, ...(r.body.payload.capability as CapabilityCommand) }));
  }
  reads(id: string): number { return this.requests.filter((r) => r.path === 'device/state' && r.body.payload.device === id).length; }

  fetch: FetchLike = async (url, init) => {
    const path = url.slice(BASE.length);
    const body = init.body ? JSON.parse(init.body) : undefined;
    this.requests.push({ path, method: init.method, apiKey: init.headers['Govee-API-Key'], body });
    if (this.status !== 200) return reply({}, this.status);
    if (path === 'user/devices') {
      if (this.devicesGate) await this.devicesGate;
      return reply({ code: 200, message: 'success', data: [
        { device: A, sku: 'H6008', deviceName: 'Desk lamp', type: 'devices.types.light', capabilities: capsFor([1000, 10000]) },
        { device: B, sku: 'H6159', deviceName: 'Shelf strip', type: 'devices.types.light', capabilities: capsFor([2000, 9000]) },
      ] });
    }
    const id: string = body?.payload?.device;
    const sku: string = body?.payload?.sku;
    const st = this.state.get(id);
    if (!st) return reply({ code: 400, message: 'unknown device' });
    if (path === 'device/state') {
      return reply({ code: 200, payload: { sku, device: id, capabilities: [
        { type: 'devices.capabilities.online', instance: 'online', state: { value: true } },
        { type: T.onOff, instance: 'powerSwitch', state: { value: st.power } },
        { type: T.range, instance: 'brightness', state: { value: st.brightness } },
        { type: T.color, instance: 'colorRgb', state: { value: st.rgb } },
        { type: T.color, instance: 'colorTemperatureK', state: { value: st.kelvin } },
      ] } });
    }
    if (path === 'device/control') {
      if (this.gate) await this.gate;
      const cap = body.payload.capability as CapabilityCommand;
      if (this.autoApply) this.apply(id, cap);
      return reply({ code: 200, msg: 'success' });
    }
    return reply({}, 404);
  };

  setState(id: string, patch: Partial<FakeState>): void { Object.assign(this.state.get(id)!, patch); }
  private apply(id: string, cap: CapabilityCommand): void {
    const st = this.state.get(id)!;
    const n = cap.value as number;
    if (cap.instance === 'powerSwitch') st.power = n;
    else if (cap.instance === 'brightness') st.brightness = n;
    else if (cap.instance === 'colorRgb') { st.rgb = n; st.kelvin = 0; }
    else if (cap.instance === 'colorTemperatureK') st.kelvin = n;
  }
}

function fixture(t: TestContext, opts: { secretsAvailable?: boolean; seed?: (dir: string) => void } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'luma-home-test-'));
  opts.seed?.(dir);
  const secrets = new MemSecrets(opts.secretsAvailable ?? true);
  const govee = new FakeGovee();
  const socket = new FakeSocket();
  const clipboard: string[] = [];
  const homes: Home[] = [];
  const build = (): Home => {
    const home = new Home({
      demo: false, version: 't', storage: new HomeStorage(dir), secrets, copyToClipboard: (text) => clipboard.push(text),
      cloudOptions: { fetch: govee.fetch, sleep: async () => {}, now: Date.now },
      controlOptions: { confirmDelays: [5, 30, 30, 30, 30], expireMs: 200, settleMs: 50 },
      createLan: (handlers) => new GoveeLan(handlers, () => socket),
    });
    homes.push(home);
    return home;
  };
  const home = build();
  t.after(async () => {
    govee.release();
    for (const h of homes) await h.shutdown();
    rmSync(dir, { recursive: true, force: true });
  });
  return { dir, secrets, govee, socket, clipboard, home, build, file: join(dir, 'home.json') };
}
type Fixture = ReturnType<typeof fixture>;

/** Connected home with both lights read once from the fake cloud. */
async function connected(t: TestContext, opts?: Parameters<typeof fixture>[1]): Promise<Fixture> {
  const f = fixture(t, opts);
  await f.home.connect(KEY);
  await until(() => f.home.confirmedDevices().every((d) => d.brightness !== undefined) && !f.home.snapshot().busy, 'initial cloud state read');
  return f;
}

async function discoverLan(f: Fixture, id: string, ip: string): Promise<void> {
  await f.home.discover();
  f.socket.inject(scanPacket(id, ip), ip);
  assert.equal(f.home.confirmedDevices().find((d) => d.id === id)?.ip, ip);
}

const confirmed = (f: Fixture, id: string): LightDevice => f.home.confirmedDevices().find((d) => d.id === id)!;
const shown = (f: Fixture, id: string): LightDevice => f.home.snapshot().devices.find((d) => d.id === id)!;
const saved = (f: Fixture) => { f.home.persistNow(); return JSON.parse(readFileSync(f.file, 'utf8')); };
const everywhere = (f: Fixture) => JSON.stringify([f.home.snapshot(), existsSync(f.file) ? readFileSync(f.file, 'utf8') : '']);

const sceneInput = (id: string, steps: Array<{ id: string; deviceID: string; command: CapabilityCommand; delayMilliseconds?: number }>) => ({
  id, name: `Scene ${id}`, icon: 'sun', steps: steps.map((s) => ({ delayMilliseconds: 0, ...s })),
});
const quickScene = (id: string, deviceID = A) => sceneInput(id, [{ id: 's1', deviceID, command: power(true) }]);

// ---------- 1. demo isolation ----------

test('demo: sample lights, every real-world feature rejects, controls confirm immediately', async (t) => {
  const home = new Home({ demo: true, version: 't' });
  t.after(() => home.shutdown());
  const snap = home.snapshot();
  assert.equal(snap.demo, true);
  assert.equal(snap.devices.length, 5);
  assert.ok(snap.scenes.length >= 1);
  assert.equal(snap.webhook.available, false);
  assert.equal(snap.canSave, false);
  assert.equal(snap.cloudConnected, false);
  assert.equal(snap.hasSavedKey, false);

  const demo = async (fn: () => unknown) => assert.rejects(async () => { await fn(); }, /Demo mode/);
  await demo(() => home.connect(KEY));
  await demo(() => home.reconnect());
  await demo(() => home.discover());
  await demo(() => home.startWebhook());
  await demo(() => home.setWebhookConfig(9000, false));
  await demo(() => home.rotateToken());
  await demo(() => home.disconnect());
  await demo(() => home.copyToken());

  assert.notEqual(snap.devices.find((d) => d.id === 'demo-floor')!.brightness, 10);
  await home.control('demo-floor', brightness(10));
  const after = home.snapshot();
  assert.equal(after.devices.find((d) => d.id === 'demo-floor')!.brightness, 10);
  assert.equal(home.confirmedDevices().find((d) => d.id === 'demo-floor')!.brightness, 10);
  assert.deepEqual(after.pending, {});

  // A demo scene runs against demo lights only.
  const runID = home.runSavedScene('demo-scene-focus');
  await until(() => home.snapshot().runs.find((r) => r.id === runID)?.status === 'completed', 'demo scene to finish');
  assert.equal(home.confirmedDevices().find((d) => d.id === 'demo-desk')!.brightness, 90);
});

test('demo with a storage folder never writes a home file', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'luma-demo-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const storage = new HomeStorage(join(dir, 'nested'));
  const secrets = new MemSecrets();
  const home = new Home({ demo: true, version: 't', storage, secrets });
  await home.control('demo-bed', power(true));
  home.renameDevice('demo-bed', 'Renamed');
  home.assignRoom('demo-bed', 'Elsewhere');
  home.saveScene({ id: 'mine', name: 'Mine', icon: 'sun', steps: [{ id: 'a', deviceID: 'demo-bed', command: power(false), delayMilliseconds: 0 }] });
  home.persistNow();
  await wait(300); // longer than the persist debounce
  await home.shutdown();
  assert.equal(existsSync(storage.file), false);
  assert.equal(existsSync(join(dir, 'nested')), false);
  assert.deepEqual(readdirSync(dir), []);
  assert.equal(home.snapshot().canSave, false);
  assert.equal(secrets.touched, 0);
});

// ---------- 2. connected journey ----------

test('connect stores the key in the secret store, merges devices and persists without secrets or addresses', async (t) => {
  const f = fixture(t);
  assert.equal(f.home.snapshot().hasSavedKey, false);
  await assert.rejects(f.home.connect('short'), /API key/);
  await f.home.connect(`  ${KEY}\n`);
  await until(() => f.home.confirmedDevices().every((d) => d.brightness !== undefined) && !f.home.snapshot().busy, 'initial state read');

  assert.equal(f.secrets.read('govee-api-key'), KEY);
  // Persisted by connect itself (no persistNow from the test).
  assert.ok(existsSync(f.file));
  const onDisk = JSON.parse(readFileSync(f.file, 'utf8'));
  assert.deepEqual(onDisk.devices.map((d: any) => d.id), [A, B]);
  assert.ok(!JSON.stringify(onDisk).includes(KEY));
  const snap = f.home.snapshot();
  assert.equal(snap.cloudConnected, true);
  assert.equal(snap.hasSavedKey, true);
  assert.deepEqual(snap.devices.map((d) => [d.id, d.name, d.room]), [[A, 'Desk lamp', 'Unassigned'], [B, 'Shelf strip', 'Unassigned']]);
  assert.equal(confirmed(f, A).brightness, 40);
  assert.equal(confirmed(f, A).power, true);
  assert.equal(confirmed(f, B).power, false);
  assert.ok(f.govee.requests.every((r) => r.apiKey === KEY));

  await discoverLan(f, A, A_IP);
  const data = saved(f);
  assert.equal(data.devices.length, 2);
  assert.equal(data.devices[0].brightness, 40);
  const text = readFileSync(f.file, 'utf8');
  assert.ok(!text.includes(KEY), 'API key must not be in home.json');
  assert.ok(!text.includes('"ip"') && !text.includes(A_IP), 'LAN addresses must not be in home.json');
  assert.ok(!JSON.stringify(f.home.snapshot()).includes(KEY), 'API key must not be in the snapshot');
  assert.ok(f.home.snapshot().activity.every((a) => !a.message.includes(KEY)), 'API key must not be in activity');
  assert.ok(f.home.snapshot().activity.some((a) => /Connected Govee cloud/.test(a.message)));
});

test('a saved home reloads, reconnects with the stored key, and disconnect removes the key', async (t) => {
  const f = await connected(t);
  f.home.assignRoom(A, 'Office');
  f.home.persistNow();
  await f.home.shutdown();

  const second = f.build();
  const snap = second.snapshot();
  assert.equal(snap.cloudConnected, false);
  assert.equal(snap.hasSavedKey, true);
  assert.equal(snap.devices.length, 2);
  assert.equal(snap.devices.find((d) => d.id === A)!.room, 'Office');
  assert.equal(snap.devices.find((d) => d.id === A)!.brightness, 40);
  await second.reconnect();
  assert.equal(second.snapshot().cloudConnected, true);
  second.disconnect();
  assert.equal(second.snapshot().cloudConnected, false);
  assert.equal(second.snapshot().hasSavedKey, false);
  assert.equal(f.secrets.read('govee-api-key'), undefined);
});

test('disconnect wins over a connect or reconnect that finishes later', async (t) => {
  const f = fixture(t);
  let open!: () => void;
  f.govee.devicesGate = new Promise<void>((resolve) => { open = resolve; });
  const connecting = f.home.connect(KEY);
  connecting.catch(() => {});
  await until(() => f.govee.requests.length === 1, 'device list request');
  f.home.disconnect();
  open();
  await assert.rejects(connecting, /cancelled/);
  let snap = f.home.snapshot();
  assert.equal(snap.cloudConnected, false);
  assert.equal(snap.hasSavedKey, false);
  assert.equal(snap.busy, false);
  assert.deepEqual(snap.devices, [], 'the cancelled connection adds no lights');
  assert.equal(f.secrets.read('govee-api-key'), undefined);

  // Reconnect with a saved key, disconnected mid-flight.
  f.secrets.write('govee-api-key', KEY);
  f.govee.devicesGate = new Promise<void>((resolve) => { open = resolve; });
  const before = f.govee.requests.length;
  const reconnecting = f.home.reconnect();
  reconnecting.catch(() => {});
  await until(() => f.govee.requests.length > before, 'reconnect device list');
  f.home.disconnect();
  open();
  await assert.rejects(reconnecting, /cancelled/);
  await wait(20);
  snap = f.home.snapshot();
  assert.equal(snap.cloudConnected, false);
  assert.equal(snap.hasSavedKey, false);
  assert.equal(f.govee.requests.length, before + 1, 'no state reads from the cancelled reconnect');
});

test('disconnect aborts a write still waiting in the old client queue', async (t) => {
  const f = await connected(t);
  f.govee.hold();
  const first = f.home.control(A, brightness(60)); // in flight at the fake cloud
  const second = f.home.control(B, brightness(70)); // waiting behind it in the paced account queue
  first.catch(() => {}); second.catch(() => {});
  await until(() => f.govee.controls().length === 1, 'first write sent');
  f.home.disconnect();
  f.govee.release();
  await assert.rejects(second);
  await wait(20);
  assert.deepEqual(f.govee.controls().map((c) => c.id), [A], 'the queued write was never sent');
  assert.equal(f.home.snapshot().pending[B], undefined);
});

test('connect failures store nothing and never echo the key', async (t) => {
  const f = fixture(t);
  f.govee.status = 401;
  await assert.rejects(f.home.connect(KEY), /rejected the API key/);
  assert.equal(f.secrets.map.size, 0);
  const snap = f.home.snapshot();
  assert.equal(snap.cloudConnected, false);
  assert.equal(snap.busy, false);
  assert.equal(snap.devices.length, 0);
  assert.ok(!JSON.stringify(snap).includes(KEY));

  const noStore = fixture(t, { secretsAvailable: false });
  await assert.rejects(noStore.home.connect(KEY), /Secure storage/);
  assert.equal(noStore.govee.requests.length, 0, 'no network call without a safe place to keep the key');
  assert.equal(noStore.home.snapshot().webhook.available, false);
});

// ---------- 3. latest intent ----------

test('latest intent is shown at once while confirmed state, webhook state and home.json keep the old value', async (t) => {
  const f = await connected(t);
  f.govee.autoApply = false;
  f.govee.hold();

  const p1 = f.home.control(A, brightness(70));
  const p2 = f.home.control(A, brightness(100));
  p1.catch(() => {}); p2.catch(() => {});

  const snap = f.home.snapshot();
  assert.equal(snap.devices.find((d) => d.id === A)!.brightness, 100);
  const pending = snap.pending[A]!;
  assert.ok(pending.length > 0);
  assert.deepEqual(pending.filter((p) => p.instance === 'brightness').map((p) => p.value), [100]);
  assert.equal(confirmed(f, A).brightness, 40, 'confirmedDevices (webhook GET) is not the overlay');
  assert.equal(saved(f).devices[0].brightness, 40, 'home.json holds confirmed state only');

  f.govee.release();
  await Promise.all([p1, p2]);
  const sent = f.govee.controls().filter((c) => c.instance === 'brightness').map((c) => c.value);
  assert.equal(sent.at(-1), 100);
  assert.ok(sent.every((v) => v === 70 || v === 100));

  // Cloud accepted the writes but the light still reports 40: nothing is confirmed yet.
  assert.equal(confirmed(f, A).brightness, 40);
  assert.equal(saved(f).devices[0].brightness, 40);
  assert.equal(shown(f, A).brightness, 100);
  assert.ok(f.home.snapshot().pending[A]!.some((p) => p.instance === 'brightness' && p.phase === 'confirming'));

  // A state read that reports 100 confirms it.
  f.govee.setState(A, { brightness: 100 });
  await until(() => confirmed(f, A).brightness === 100 && f.home.snapshot().pending[A] === undefined, 'confirmation read');
  assert.equal(saved(f).devices[0].brightness, 100);
});

test('an unconfirmed request expires back to the last reported value', async (t) => {
  const f = await connected(t);
  f.govee.autoApply = false;
  await f.home.control(A, brightness(90));
  assert.equal(shown(f, A).brightness, 90);
  await until(() => f.home.snapshot().pending[A] === undefined, 'expiry');
  assert.equal(shown(f, A).brightness, 40);
  assert.ok(f.home.snapshot().activity.some((a) => a.isError && /Could not confirm brightness/.test(a.message)));
});

// ---------- 4. routing ----------

test('lanEligible: basic controls in 2000…9000 K only', () => {
  assert.equal(lanEligible(power(true)), true);
  assert.equal(lanEligible(brightness(50)), true);
  assert.equal(lanEligible(rgb(0xff0000)), true);
  assert.equal(lanEligible(kelvin(2000)), true);
  assert.equal(lanEligible(kelvin(9000)), true);
  assert.equal(lanEligible(kelvin(1999)), false);
  assert.equal(lanEligible(kelvin(1500)), false);
  assert.equal(lanEligible(kelvin(9001)), false);
  assert.equal(lanEligible(kelvin(2700.5)), false);
  assert.equal(lanEligible({ type: T.color, instance: 'colorTemperatureK', value: '2700' }), false);
  assert.equal(lanEligible({ type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', value: 1 }), false);
});

test('mergeCapabilities keeps previously loaded options and adds new capabilities', () => {
  const scene = (options: unknown[]) => ({ type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', parameters: { dataType: 'ENUM', options } as any });
  const merged = mergeCapabilities(
    [scene([{ name: 'Old', value: 1 }, { name: 'Shared', value: 2 }])],
    [scene([{ name: 'Shared', value: 2 }, { name: 'New', value: 3 }]), { type: T.onOff, instance: 'powerSwitch' }],
  );
  assert.equal(merged.length, 2);
  assert.deepEqual((merged[0]!.parameters as any).options.map((o: any) => o.name).sort(), ['New', 'Old', 'Shared']);
});

test('basic controls go over LAN; 1500 K goes to the cloud and is confirmed by a cloud state read', async (t) => {
  const f = await connected(t);
  await discoverLan(f, A, A_IP);

  const lanTo = (cmd: string, from = 0) => f.socket.cmds(cmd, from).filter((p) => p.port === 4003 && p.address === A_IP);
  await f.home.control(A, power(false));
  assert.equal(lanTo('turn').at(-1)!.json.msg.data.value, 0);
  await f.home.control(A, brightness(70));
  assert.equal(lanTo('brightness').at(-1)!.json.msg.data.value, 70);
  await f.home.control(A, rgb(0x102030));
  assert.deepEqual(lanTo('colorwc').at(-1)!.json.msg.data, { color: { r: 0x10, g: 0x20, b: 0x30 }, colorTemInKelvin: 0 });
  await f.home.control(A, kelvin(2700));
  assert.equal(lanTo('colorwc').at(-1)!.json.msg.data.colorTemInKelvin, 2700);
  assert.deepEqual(f.govee.controls(), [], 'no basic write used the cloud');

  // One LAN status confirms everything still pending (rgb was superseded by the kelvin write).
  f.socket.inject(statusPacket({ onOff: 0, brightness: 70, rgb: 0x102030, kelvin: 2700 }), A_IP);
  await until(() => f.home.snapshot().pending[A] === undefined, 'LAN confirmation');
  assert.equal(confirmed(f, A).colorTemperature, 2700);

  const sentBefore = f.socket.sent.length;
  const readsBefore = f.govee.reads(A);
  await f.home.control(A, kelvin(1500));
  assert.deepEqual(f.govee.controls().map((c) => [c.id, c.instance, c.value]), [[A, 'colorTemperatureK', 1500]]);
  await until(() => f.govee.reads(A) > readsBefore && f.home.snapshot().pending[A] === undefined, 'cloud confirmation read');
  assert.equal(confirmed(f, A).colorTemperature, 1500);
  assert.deepEqual(f.socket.sent.slice(sentBefore), [], '1500 K never touches LAN, and neither does its confirmation read');

  // The address is runtime-only.
  assert.ok(!JSON.stringify(saved(f)).includes(A_IP));
});

test('a LAN-less light and an out-of-range LAN white both fall back to the cloud', async (t) => {
  const f = await connected(t);
  await discoverLan(f, B, B_IP);
  await f.home.control(A, brightness(55)); // A has no address
  await f.home.control(B, kelvin(2500));  // B has one
  assert.deepEqual(f.govee.controls().map((c) => [c.id, c.instance]), [[A, 'brightness']]);
  assert.equal(f.socket.cmds('colorwc').filter((p) => p.address === B_IP).length, 1);
  await assert.rejects(f.home.control(B, kelvin(1500)), /below the device minimum \(2000\)/);
});

// ---------- 5. LAN status settle ----------

test('a late contradicting LAN status inside settleMs does not undo a confirmation, a later one does', async (t) => {
  const f = await connected(t);
  await discoverLan(f, A, A_IP);

  await f.home.control(A, brightness(70));
  f.socket.inject(statusPacket({ brightness: 70 }), A_IP);
  assert.equal(confirmed(f, A).brightness, 70);
  assert.equal(f.home.snapshot().pending[A], undefined);

  f.socket.inject(statusPacket({ brightness: 40 }), A_IP); // stale packet that was in flight
  assert.equal(confirmed(f, A).brightness, 70);
  assert.equal(shown(f, A).brightness, 70);

  await wait(90); // past settleMs: now it is real telemetry
  f.socket.inject(statusPacket({ brightness: 40 }), A_IP);
  assert.equal(confirmed(f, A).brightness, 40);
});

test('white → RGB inside settleMs over LAN: confirmed mode, capture and webhook state become color', async (t) => {
  const f = await connected(t);
  await discoverLan(f, A, A_IP);
  await f.home.control(A, kelvin(2700));
  f.socket.inject(statusPacket({ rgb: 0x112233, kelvin: 2700 }), A_IP);
  assert.equal(confirmed(f, A).colorTemperature, 2700);
  await f.home.control(A, rgb(0xff0000)); // well within settleMs of the white confirmation
  f.socket.inject(statusPacket({ rgb: 0xff0000, kelvin: 0 }), A_IP);
  assert.equal(f.home.snapshot().pending[A], undefined);
  assert.equal(confirmed(f, A).rgb, 0xff0000);
  assert.equal(confirmed(f, A).colorTemperature, 0);
  f.socket.inject(statusPacket({ rgb: 0x112233, kelvin: 2700 }), A_IP); // late white packet
  assert.equal(confirmed(f, A).colorTemperature, 0);
  const scene = f.home.captureScene('Red', 'sun', [A]);
  assert.deepEqual(scene.steps.map((s) => s.command.instance).filter((i) => i.startsWith('color')), ['colorRgb']);
  assert.equal(scene.steps.find((s) => s.command.instance === 'colorRgb')!.command.value, 0xff0000);
});

// ---------- 6. scenes ----------

test('saveScene rejects invalid scenes and nothing runs or is saved', async (t) => {
  const f = await connected(t);
  const dup = sceneInput('dup', [{ id: 'x', deviceID: A, command: power(true) }, { id: 'x', deviceID: A, command: brightness(20) }]);
  const huge = sceneInput('huge', [{ id: 'x', deviceID: A, command: brightness(1e100) }]);
  const ghost = sceneInput('ghost', [{ id: 'x', deviceID: 'nope', command: power(true) }]);
  assert.throws(() => f.home.saveScene(dup), /unique ID/);
  assert.throws(() => f.home.saveScene(huge), LumaError);
  assert.throws(() => f.home.saveScene(ghost), /no longer connected/);
  assert.throws(() => f.home.saveScene(sceneInput('range', [{ id: 'x', deviceID: A, command: brightness(101) }])), LumaError);
  assert.throws(() => f.home.saveScene(sceneInput('delay', [{ id: 'x', deviceID: A, command: power(true), delayMilliseconds: 60001 }])), /delays/);
  assert.throws(() => f.home.saveScene('not a scene'), LumaError);
  assert.throws(() => f.home.runScene(dup as any), /unique ID/);
  await wait(20);
  assert.deepEqual(f.home.scenes(), []);
  const snap = f.home.snapshot();
  assert.deepEqual(snap.runs, []);
  assert.equal(snap.runningSceneID, undefined);
  assert.deepEqual(f.govee.controls(), []);
  assert.deepEqual(f.socket.cmds('turn'), []);
});

test('captureScene snapshots confirmed values, never pending intents', async (t) => {
  const f = await connected(t);
  f.govee.autoApply = false;
  f.govee.hold();
  const pendingWrite = f.home.control(A, brightness(90));
  pendingWrite.catch(() => {});
  assert.equal(shown(f, A).brightness, 90);

  const scene = f.home.captureScene('Evening', 'moon', [A]);
  assert.ok(UUID.test(scene.id));
  assert.deepEqual(scene.steps.map((s) => [s.deviceID, s.command.instance, s.command.value]), [
    [A, 'powerSwitch', 1], [A, 'brightness', 40], [A, 'colorRgb', 0x112233],
  ]);
  assert.equal(f.home.scenes().length, 1);
  assert.throws(() => f.home.captureScene('Nothing', 'moon', []), /at least one light/);

  // B is off: only its power state is captured.
  const off = f.home.captureScene('Off', 'moon', [B]);
  assert.deepEqual(off.steps.map((s) => [s.command.instance, s.command.value]), [['powerSwitch', 0]]);
  f.govee.release();
  await pendingWrite;
});

test('runSavedScene returns a run ID, a second run is 409, stopScene cancels and later steps are never sent', async (t) => {
  const f = await connected(t);
  f.home.saveScene(sceneInput('slow', [
    { id: 's1', deviceID: A, command: power(true) },
    { id: 's2', deviceID: A, command: brightness(20), delayMilliseconds: 5000 },
    { id: 's3', deviceID: A, command: rgb(0xff0000) },
  ]));
  f.home.saveScene(quickScene('quick', B));
  assert.throws(() => f.home.runSavedScene('missing'), (e: any) => e instanceof LumaError && e.status === 404);

  const runID = f.home.runSavedScene('slow');
  assert.match(runID, UUID);
  assert.equal(f.home.snapshot().runningSceneID, 'slow');
  assert.equal(f.home.snapshot().runs[0]!.status, 'running');
  for (const id of ['slow', 'quick']) {
    assert.throws(() => f.home.runSavedScene(id), (e: any) => e instanceof LumaError && e.status === 409);
  }

  await until(() => f.govee.controls().length === 1, 'step 1 to be sent');
  f.home.stopScene();
  await until(() => f.home.snapshot().runs[0]!.status === 'cancelled' && f.home.snapshot().runningSceneID === undefined, 'cancellation');
  assert.ok(f.home.snapshot().runs[0]!.finishedAt !== undefined);
  await wait(40);
  assert.deepEqual(f.govee.controls().map((c) => c.instance), ['powerSwitch']);
  assert.ok(f.home.snapshot().activity.some((a) => /Scene stopped/.test(a.message)));

  // The runner is free again.
  const next = f.home.runSavedScene('quick');
  await until(() => f.home.snapshot().runs.find((r) => r.id === next)?.status === 'completed', 'next run');
});

test('importScene gives a colliding ID a fresh one; export contains no secrets', async (t) => {
  const f = await connected(t);
  await discoverLan(f, A, A_IP);
  await f.home.rotateToken(); // makes a token (no server) to prove it never leaks into an export
  f.home.saveScene(sceneInput('orig', [{ id: 's1', deviceID: A, command: power(true) }, { id: 's2', deviceID: B, command: brightness(30), delayMilliseconds: 10 }]));
  const exported = f.home.exportScene('orig');
  assert.equal(exported.name, 'Scene orig');
  assert.ok(!exported.json.includes(KEY));
  assert.ok(!exported.json.includes(A_IP));
  const token = f.secrets.read('webhook-token');
  assert.ok(token);
  assert.ok(!exported.json.includes(token));
  assert.deepEqual(Object.keys(JSON.parse(exported.json)).sort(), ['icon', 'id', 'name', 'steps']);
  assert.throws(() => f.home.exportScene('missing'), (e: any) => e.status === 404);

  const imported = f.home.importScene(exported.json);
  assert.notEqual(imported.id, 'orig');
  assert.match(imported.id, UUID);
  assert.equal(f.home.scenes().length, 2);
  assert.deepEqual(imported.steps, f.home.scenes()[0]!.steps);
  assert.notEqual(f.home.importScene(exported.json).id, imported.id);

  f.home.deleteScene('orig');
  assert.equal(f.home.importScene(exported.json).id, 'orig', 'a non-colliding ID is kept');
  assert.throws(() => f.home.importScene('{'), /valid scene/);
  assert.throws(() => f.home.importScene(JSON.stringify({ name: 'x', steps: [{ id: 'a', deviceID: 'nope', command: power(true) }] })), /no longer connected/);
});

// ---------- 7. schedules ----------

test('saveSchedule validates its input', async (t) => {
  const f = await connected(t);
  f.home.saveScene(quickScene('q'));
  const ok = { id: 'sch', sceneID: 'q', hour: 7, minute: 30, weekdays: [2, 4], enabled: true };
  for (const bad of [
    { ...ok, hour: 24 }, { ...ok, minute: 60 }, { ...ok, hour: 1.5 }, { ...ok, weekdays: [0] }, { ...ok, weekdays: [8] },
    { ...ok, weekdays: 'mon' }, { ...ok, sceneID: 'missing' }, { ...ok, sceneID: 7 }, null, 'nope',
  ]) assert.throws(() => f.home.saveSchedule(bad), LumaError, JSON.stringify(bad));
  assert.deepEqual(f.home.snapshot().schedules, []);
  f.home.saveSchedule({ ...ok, weekdays: [4, 2, 4] });
  assert.deepEqual(f.home.snapshot().schedules, [{ id: 'sch', sceneID: 'q', hour: 7, minute: 30, weekdays: [2, 4], enabled: true }]);
  f.home.deleteScene('q');
  assert.deepEqual(f.home.snapshot().schedules, [], 'deleting a scene removes its schedules');
});

test('tickSchedules fires once per minute, again on another day, and keeps lastRunMinute when re-saved', async (t) => {
  const f = await connected(t);
  f.home.saveScene(quickScene('q'));
  f.home.saveSchedule({ id: 'sch', sceneID: 'q', hour: 7, minute: 30, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true });
  const at = (day: number, h = 7, m = 30) => new Date(2026, 9, day, h, m, 0);
  const runs = () => f.home.snapshot().runs.length;
  const settled = async () => until(() => f.home.snapshot().runningSceneID === undefined, 'run to end');

  f.home.tickSchedules(at(20, 7, 29));
  assert.equal(runs(), 0);
  f.home.tickSchedules(at(20));
  assert.equal(runs(), 1);
  f.home.tickSchedules(at(20)); // same minute, scene still running or not
  await settled();
  f.home.tickSchedules(new Date(at(20).getTime() + 30_000));
  assert.equal(runs(), 1);
  assert.ok(!f.home.snapshot().activity.some((a) => /Schedule skipped/.test(a.message)), 'second tick is a no-op, not a 409');
  assert.equal(f.home.snapshot().schedules[0]!.lastRunMinute, minuteKey(at(20)));

  f.home.saveSchedule({ id: 'sch', sceneID: 'q', hour: 7, minute: 30, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: false });
  assert.equal(f.home.snapshot().schedules[0]!.lastRunMinute, minuteKey(at(20)));
  f.home.tickSchedules(at(21));
  assert.equal(runs(), 1, 'disabled schedules do not fire');
  f.home.saveSchedule({ id: 'sch', sceneID: 'q', hour: 7, minute: 30, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true });
  f.home.tickSchedules(at(21));
  assert.equal(runs(), 2);
});

test('a due schedule is skipped and logged while another scene is running', async (t) => {
  const f = await connected(t);
  f.home.saveScene(sceneInput('long', [{ id: 's1', deviceID: A, command: power(true), delayMilliseconds: 5000 }]));
  f.home.saveScene(quickScene('q', B));
  f.home.saveSchedule({ id: 'sch', sceneID: 'q', hour: 6, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true });
  f.home.runSavedScene('long');
  f.home.tickSchedules(new Date(2026, 9, 20, 6, 0, 0));
  const snap = f.home.snapshot();
  assert.ok(snap.activity.some((a) => a.isError && /^Schedule skipped: .*already running/.test(a.message)));
  assert.deepEqual(snap.runs.map((r) => r.sceneID), ['long']);
  f.home.stopScene();
  await until(() => f.home.snapshot().runningSceneID === undefined, 'stop');
});

// ---------- 8. webhook (loopback only) ----------

async function startOnFreePort(home: Home): Promise<number> {
  for (let i = 0; i < 25; i++) {
    const port = 40000 + Math.floor(Math.random() * 20000);
    home.setWebhookConfig(port, false);
    try { await home.startWebhook(); return port; }
    catch (error) { if (!/in use|elevated permission/i.test((error as Error).message)) throw error; }
  }
  throw new Error('no free loopback port found');
}

async function call(port: number, path: string, opts: { token?: string; method?: string; body?: unknown } = {}): Promise<{ status: number; json: any }> {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: opts.method ?? 'GET',
    headers: { ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}), ...(opts.body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });
  return { status: res.status, json: await res.json() };
}

test('webhook: token creation, masking, auth, actions, confirmed-only device state, and rotation', async (t) => {
  const f = await connected(t);
  await discoverLan(f, B, B_IP);
  t.after(() => f.home.stopWebhook());

  assert.throws(() => f.home.setWebhookConfig(80, false), /1024 to 65535/);
  assert.throws(() => f.home.setWebhookConfig('9000', false), /1024 to 65535/);
  assert.throws(() => f.home.setWebhookConfig(1.5, false), /1024 to 65535/);
  assert.throws(() => f.home.setWebhookConfig(65536, false), /1024 to 65535/);
  assert.equal(f.secrets.read('webhook-token'), undefined);
  assert.equal(f.home.snapshot().webhook.available, true);
  assert.equal(f.home.snapshot().webhook.maskedToken, undefined);

  const port = await startOnFreePort(f.home);
  const token = f.secrets.read('webhook-token')!;
  assert.match(token, /^lm_[A-Za-z0-9_-]{40,}$/);
  const webhook = f.home.snapshot().webhook;
  assert.equal(webhook.running, true);
  assert.equal(webhook.allowLAN, false);
  assert.match(webhook.status, /this PC only/);
  assert.ok(webhook.maskedToken && webhook.maskedToken !== token && !webhook.maskedToken.includes(token) && webhook.maskedToken.length < token.length);
  assert.ok(!JSON.stringify(f.home.snapshot()).includes(token));
  assert.throws(() => f.home.setWebhookConfig(port + 1, false), /Stop the server/);

  // auth
  assert.deepEqual(await call(port, '/health', { token }), { status: 200, json: { status: 'ok', demo: false } });
  assert.equal((await call(port, '/health')).status, 401);
  assert.equal((await call(port, '/health', { token: `${token}x` })).status, 401);
  assert.equal((await call(port, '/v1/devices')).status, 401);

  // pending writes are visible in the app but never served over the webhook
  f.govee.hold();
  const slow = f.home.control(A, brightness(99));
  slow.catch(() => {});
  assert.equal(shown(f, A).brightness, 99);
  const devices = await call(port, '/v1/devices', { token });
  assert.equal(devices.status, 200);
  assert.equal(devices.json.find((d: any) => d.id === A).brightness, 40);
  assert.ok(devices.json.every((d: any) => !('ip' in d)));
  assert.ok(!JSON.stringify(devices.json).includes('192.168.'));
  f.govee.release();
  await slow;

  // actions run asynchronously and are pollable
  const accepted = await call(port, '/v1/actions', { token, method: 'POST', body: { target: 'all', power: true } });
  assert.equal(accepted.status, 202);
  assert.match(accepted.json.runID, UUID);
  assert.equal(accepted.json.statusURL, `/v1/runs/${accepted.json.runID}`);
  await until(() => f.home.snapshot().runs.find((r) => r.id === accepted.json.runID)?.status === 'completed', 'webhook run');
  const run = await call(port, accepted.json.statusURL, { token });
  assert.equal(run.status, 200);
  assert.equal(run.json.status, 'completed');
  assert.deepEqual(f.govee.controls().filter((c) => c.instance === 'powerSwitch').map((c) => [c.id, c.value]), [[A, 1]], 'A by cloud');
  assert.equal(f.socket.cmds('turn').filter((p) => p.address === B_IP && p.json.msg.data.value === 1).length, 1, 'B by LAN');
  assert.equal((await call(port, '/v1/runs/nope', { token })).status, 404);
  assert.equal((await call(port, '/v1/actions', { token, method: 'POST', body: { target: 'all' } })).status, 400);
  assert.equal((await call(port, '/v1/actions', { token, method: 'POST', body: { target: 'all', brightness: 1e100 } })).status, 400);

  // clipboard gets the full token, nothing else does
  f.home.copyToken();
  assert.deepEqual(f.clipboard, [token]);
  assert.ok(!JSON.stringify(f.home.snapshot().activity).includes(token));

  // rotation stops the server, changes the token, and the old one stays dead after restart
  await f.home.rotateToken();
  assert.equal(f.home.snapshot().webhook.running, false);
  const rotated = f.secrets.read('webhook-token')!;
  assert.notEqual(rotated, token);
  await assert.rejects(call(port, '/health', { token }));
  const port2 = await startOnFreePort(f.home);
  assert.equal((await call(port2, '/health', { token })).status, 401);
  assert.equal((await call(port2, '/health', { token: rotated })).status, 200);
  assert.ok(!JSON.stringify(f.home.snapshot()).includes(token));
  assert.ok(!JSON.stringify(f.home.snapshot()).includes(rotated));
});

test('webhook: unavailable secure storage and the saved-token hint', async (t) => {
  const f = fixture(t, { secretsAvailable: false });
  await assert.rejects(f.home.startWebhook(), /Secure storage/);
  assert.equal(f.home.snapshot().webhook.running, false);

  const g = fixture(t);
  g.secrets.write('webhook-token', 'lm_savedtokenvalue_0123456789');
  assert.equal(g.home.snapshot().webhook.maskedToken, 'lm_…saved');
  assert.ok(!JSON.stringify(g.home.snapshot()).includes('savedtokenvalue'));
});

// ---------- 9. unreadable home.json ----------

for (const [name, content] of [['garbage', '\u0000not json {{{ ' + KEY.slice(0, 4)], ['wrong version', '{"version":2,"devices":[]}']] as const) {
  test(`unreadable home.json (${name}) is preserved byte-for-byte and saving is disabled`, async (t) => {
    const f = fixture(t, { seed: (dir) => { mkdirSync(dir, { recursive: true }); writeFileSync(join(dir, 'home.json'), content); } });
    const original = readFileSync(f.file);
    assert.equal(f.home.snapshot().canSave, false);
    assert.ok(f.home.snapshot().activity.some((a) => a.isError && /could not be read/.test(a.message)));
    assert.match(f.home.snapshot().notice ?? '', /left untouched/);

    await f.home.connect(KEY);
    await until(() => f.home.confirmedDevices().every((d) => d.brightness !== undefined), 'state read');
    f.home.assignRoom(A, 'Office');
    f.home.renameDevice(B, 'Renamed');
    f.home.saveScene(quickScene('q'));
    await f.home.control(A, brightness(60));
    f.home.persistNow();
    await wait(300); // longer than the persist debounce
    assert.ok(readFileSync(f.file).equals(original), 'unchanged after mutations');
    assert.equal(f.home.snapshot().canSave, false);
    assert.equal(f.home.snapshot().devices.length, 2, 'the session still works in memory');

    await f.home.shutdown();
    assert.ok(readFileSync(f.file).equals(original), 'unchanged after shutdown');
    assert.deepEqual(readdirSync(f.dir), ['home.json'], 'no temp files left behind');
  });
}

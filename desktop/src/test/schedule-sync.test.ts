// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Schedule sync convergence tests. Runner and paired devices are real ScheduleSync /
// Home instances on temp folders with in-memory secrets and a fake clock; the "phone" is
// a bare protocol client built from the same core functions the iOS app ports. One test
// runs over real TLS on loopback to check the token, the pin and the 64 KB framing.

process.env.TZ = 'America/New_York'; // DST rules below assume this zone

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import type { LightScene, SceneSchedule } from '../shared/types';
import {
  SYNC_PATH, applyResponse, base32, buildBatches, certPin, clientView, hubHandle, newClientState, newHubDoc, occurrences, parsePairingCode, stage,
  type ClientState, type SceneWire, type ScheduleWire, type SyncOp, type SyncResponse,
} from '../core/schedule-sync';
import { ScheduleSync, pinnedTransport, sceneToWire, scheduleToWire, type ScheduleSyncDeps, type SyncTransport } from '../main/schedule-sync';
import { Home } from '../main/home';
import { HomeStorage, type SecretStore } from '../main/storage';

class MemSecrets implements SecretStore {
  readonly available = true;
  readonly values = new Map<string, string>();
  read(name: string) { return this.values.get(name); }
  write(name: string, value: string) { this.values.set(name, value); }
  delete(name: string) { this.values.delete(name); }
}

const SCENE = 'A1A1A1A1-0000-4000-8000-000000000001';
const SCHED = 'B2B2B2B2-0000-4000-8000-000000000002';
const scene = (): LightScene => ({ id: SCENE, name: 'Evening', icon: 'moon', steps: [{ id: 'C3C3C3C3-0000-4000-8000-000000000003', deviceID: 'AA:BB', command: { type: 'devices.capabilities.on_off', instance: 'powerSwitch', value: 1 }, delayMilliseconds: 0 }] });
const schedule = (over: Partial<SceneSchedule> = {}): SceneSchedule => ({ id: SCHED, sceneID: SCENE, hour: 7, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true, ...over });
const at = (y: number, mo: number, d: number, h: number, mi: number, s = 0) => new Date(y, mo - 1, d, h, mi, s);

/** A computer: a ScheduleSync over a plain in-memory home. */
function computer(t: TestContext, name: string, opts: { folder?: string; secrets?: MemSecrets; clock: { now: Date }; network: Network; addresses?: string[] }) {
  const folder = opts.folder ?? mkdtempSync(join(tmpdir(), 'luma-ss-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  const home = { scenes: [] as LightScene[], schedules: [] as SceneSchedule[], runs: [] as string[] };
  const secrets = opts.secrets ?? new MemSecrets();
  const deps: ScheduleSyncDeps = {
    folder, secrets, platform: 'windows',
    scenes: () => home.scenes, schedules: () => home.schedules,
    apply: (scenes, schedules) => { home.scenes = scenes; home.schedules = schedules; },
    run: (id) => { home.runs.push(id); return `run-${home.runs.length}`; },
    runStatus: () => 'completed', persistHome: () => undefined, log: () => undefined, changed: () => undefined,
    transport: opts.network.transport, now: () => opts.clock.now, timeZone: () => 'America/New_York', addresses: () => opts.addresses ?? [name],
  };
  const sync = new ScheduleSync(deps);
  (sync as unknown as { saved: { port: number } }).saved.port = 0; // real servers bind an ephemeral port
  // Stand in for the LAN server: the network routes requests for `name` to this instance.
  opts.network.hosts.set(name, sync);
  t.after(() => sync.stop());
  return { sync, home, folder, secrets, deps };
}

/** In-process network. `down` hosts are unreachable; `dropReplies` loses the next N responses after the runner handled them. */
class Network {
  hosts = new Map<string, ScheduleSync>();
  down = new Set<string>();
  dropReplies = 0;
  transport: SyncTransport = async (target, path, body) => {
    const host = this.hosts.get(target.host);
    if (!host || this.down.has(target.host)) throw Object.assign(new Error("Can't reach the runner."), { status: 503 });
    const view = host.view();
    const code = view.runner?.pairingCodes.find((c) => c.includes(`/${target.host}/`));
    const expected = code ? parsePairingCode(code) : undefined;
    if (!expected || expected.pin !== target.pin) throw Object.assign(new Error('pin mismatch'), { status: 495 });
    if (expected.token !== target.token) return { status: 401, body: { error: 'Bearer authentication required' } };
    const response = await host.handle({ method: 'POST', path, body: Buffer.from(JSON.stringify(body)) });
    if (this.dropReplies > 0) { this.dropReplies--; throw Object.assign(new Error('Connection reset'), { status: 503 }); }
    return { status: response.status, body: JSON.parse(JSON.stringify(response.body)) };
  };
}

/** Starts a runner without a real socket: the fake network handles requests. */
async function runner(t: TestContext, name: string, clock: { now: Date }, network: Network, setup?: (home: { scenes: LightScene[]; schedules: SceneSchedule[] }) => void) {
  const c = computer(t, name, { clock, network });
  setup?.(c.home);
  await c.sync.becomeRunner();
  return c;
}
const codeOf = (c: { sync: ScheduleSync }) => c.sync.view().runner!.pairingCodes[0]!;

/** The iPhone/iPad side, using only core functions, as the Swift client does. */
class Phone {
  state: ClientState = newClientState();
  constructor(readonly code: string, readonly network: Network, readonly id = 'D4D4D4D4-0000-4000-8000-000000000004', readonly name = 'iPhone') {}
  async sync(): Promise<{ refusals: ReturnType<typeof applyResponse>; response: SyncResponse }> {
    const target = parsePairingCode(this.code);
    let last: { refusals: ReturnType<typeof applyResponse>; response: SyncResponse } | undefined;
    for (const ops of buildBatches(this.state)) {
      const r = await this.network.transport(target, SYNC_PATH, { protocol: 1, client: { id: this.id, name: this.name, platform: 'ios' }, ...(this.state.hubID ? { hubID: this.state.hubID } : {}), since: this.state.cursor, ops });
      assert.equal(r.status, 200, JSON.stringify(r.body));
      last = { refusals: applyResponse(this.state, ops, r.body as SyncResponse), response: r.body as SyncResponse };
    }
    return last!;
  }
  schedule(): ScheduleWire | undefined { return clientView<ScheduleWire>(this.state, 'schedule').find((s) => s.id === SCHED); }
  edit(change: Partial<ScheduleWire>) { stage(this.state, 'schedule', { ...this.schedule()!, ...change }); }
}

// ---------------- shared vectors (also replayed by the Swift tests) ----------------

test('shared protocol vectors replay identically', () => {
  const v = JSON.parse(readFileSync(join(__dirname, '../../src/test/fixtures/schedule-sync-vectors.json'), 'utf8'));
  for (const b of v.base32) assert.equal(base32(Buffer.from(b.hex, 'hex')), b.b32);
  assert.equal(certPin(Buffer.from(v.certPin.derHex, 'hex')), v.certPin.pin);
  for (const p of v.pairing) {
    if (!p.valid) { assert.throws(() => parsePairingCode(p.code)); continue; }
    const parsed = parsePairingCode(p.code);
    assert.equal(parsed.host, p.host); assert.equal(parsed.port, p.port);
  }
  let doc = newHubDoc(v.hub.hubID);
  for (const step of v.hub.steps) {
    const { doc: next, response } = hubHandle(doc, { protocol: 1, client: step.client, since: 0, ops: step.ops }, { hub: { id: doc.hubID, name: 'Hub', platform: 'windows' }, timeZone: 'UTC', now: 1 });
    doc = next;
    assert.deepEqual(response.results.map((r) => ({ status: r.status, ...(r.rev !== undefined ? { rev: r.rev } : {}) })), step.expect);
  }
  assert.equal(doc.seq, v.hub.finalSeq);
  for (const [key, want] of Object.entries(v.hub.final) as Array<[string, { rev: number; deleted: boolean }]>) {
    assert.equal(doc.records[key]!.rev, want.rev); assert.equal(doc.records[key]!.deleted === true, want.deleted);
  }
});

// ---------------- acceptance ----------------

test('pause from a phone survives a runner restart and blocks the run until it ends', async (t) => {
  const clock = { now: at(2026, 3, 2, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  const phone = new Phone(codeOf(desk), network);
  await phone.sync();
  assert.equal(phone.schedule()?.enabled, true);
  phone.edit({ pausedUntil: at(2026, 3, 3, 12, 0).getTime() }); // pause until tomorrow noon
  const { refusals } = await phone.sync();
  assert.deepEqual(refusals, []);
  await desk.sync.stop();

  // Restart: a new instance reads only what the runner saved before acknowledging.
  network.hosts.delete('desk');
  const restarted = computer(t, 'desk', { folder: desk.folder, secrets: desk.secrets, clock, network });
  await restarted.sync.start().catch(() => undefined);
  assert.equal(restarted.home.schedules[0]?.pausedUntil, at(2026, 3, 3, 12, 0).getTime());
  clock.now = at(2026, 3, 2, 7, 0, 20); restarted.sync.tick(clock.now);
  clock.now = at(2026, 3, 3, 7, 0, 20); restarted.sync.tick(at(2026, 3, 3, 6, 59, 50)); restarted.sync.tick(clock.now);
  assert.deepEqual(restarted.home.runs, [], 'paused occurrences must not run');
  assert.equal(restarted.sync.view().runner!.runs[0]!.status, 'paused');
  restarted.sync.tick(at(2026, 3, 4, 6, 59, 50)); restarted.sync.tick(at(2026, 3, 4, 7, 0, 10));
  assert.deepEqual(restarted.home.runs, [SCENE], 'runs again once the pause ends');
});

test('two computers with the same shared schedule run it once, and a hand-off moves it', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const a = await runner(t, 'a', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  const b = computer(t, 'b', { clock, network });
  await b.sync.pair(codeOf(a));
  assert.equal(b.home.schedules.length, 1, 'the paired computer shows the shared schedule');
  const tickBoth = (d: Date) => { a.sync.tick(d); b.sync.tick(d); };
  tickBoth(at(2026, 6, 1, 6, 59, 50)); tickBoth(at(2026, 6, 1, 7, 0, 5)); tickBoth(at(2026, 6, 1, 7, 0, 35));
  assert.equal(a.home.runs.length + b.home.runs.length, 1);
  assert.equal(a.home.runs.length, 1);

  await b.sync.takeOver();
  assert.equal(a.sync.mayExecute, false, 'old runner retired');
  assert.equal(b.sync.mayExecute, true);
  tickBoth(at(2026, 6, 2, 6, 59, 50)); tickBoth(at(2026, 6, 2, 7, 0, 5));
  assert.equal(a.home.runs.length, 1, 'old runner never runs again');
  assert.equal(b.home.runs.length, 1, 'new runner runs exactly once');
  // Turning sync off on the retired computer turns its schedules off rather than running them locally.
  await a.sync.turnOff();
  assert.equal(a.home.schedules.every((s) => !s.enabled), true);
});

test('a forced take-over runs nothing until the old runner confirms', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const a = await runner(t, 'a', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  const b = computer(t, 'b', { clock, network });
  await b.sync.pair(codeOf(a));
  network.down.add('a');
  await assert.rejects(b.sync.takeOver(false));
  await b.sync.takeOver(true);
  assert.equal(b.sync.mayExecute, false);
  b.sync.tick(at(2026, 6, 1, 6, 59, 50)); b.sync.tick(at(2026, 6, 1, 7, 0, 5));
  assert.equal(b.home.runs.length, 0, 'waiting for the old runner');
  network.down.delete('a');
  await b.sync.syncNow(); // the retry loop
  assert.equal(a.sync.mayExecute, false);
  assert.equal(b.sync.mayExecute, true);
});

test('an offline device cannot resurrect a deleted or re-enable a disabled schedule', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule(), schedule({ id: 'E5E5E5E5-0000-4000-8000-000000000005', hour: 9 })]; });
  const phone = new Phone(codeOf(desk), network);
  const ipad = new Phone(codeOf(desk), network, 'F6F6F6F6-0000-4000-8000-000000000006', 'iPad');
  await phone.sync(); await ipad.sync();
  // While the iPad is offline: the phone disables one schedule and deletes the other.
  phone.edit({ enabled: false });
  stage(phone.state, 'schedule', null, 'E5E5E5E5-0000-4000-8000-000000000005');
  await phone.sync();
  // The offline iPad, with its old copy, edits the time of the first and re-enables the deleted one.
  ipad.edit({ hour: 10, enabled: true });
  stage(ipad.state, 'schedule', { ...clientView<ScheduleWire>(ipad.state, 'schedule').find((s) => s.hour === 9)!, minute: 30 });
  const { refusals } = await ipad.sync();
  assert.equal(refusals.length, 2);
  assert.deepEqual(refusals.map((r) => r.status).sort(), ['conflict', 'conflict']);
  assert.equal(ipad.schedule()?.enabled, false, 'the iPad now shows the runner copy');
  assert.equal(clientView(ipad.state, 'schedule').length, 1, 'deleted stays deleted');
  const shared = desk.home.schedules;
  assert.equal(shared.length, 1); assert.equal(shared[0]!.enabled, false); assert.equal(shared[0]!.hour, 7);
});

test('an edit on the phone reaches the runner and other paired computers', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  const laptop = computer(t, 'laptop', { clock, network });
  await laptop.sync.pair(codeOf(desk));
  const phone = new Phone(codeOf(desk), network);
  await phone.sync();
  phone.edit({ hour: 6, minute: 45, weekdays: [2, 3, 4, 5, 6] });
  await phone.sync();
  assert.equal(desk.home.schedules[0]!.hour, 6);
  await laptop.sync.syncNow();
  assert.deepEqual(laptop.home.schedules.map((s) => [s.hour, s.minute, s.weekdays]), [[6, 45, [2, 3, 4, 5, 6]]]);
  // And the laptop's own edit (a scene rename) reaches the phone.
  laptop.home.scenes[0]!.name = 'Wind down';
  laptop.sync.localChange('scene', SCENE);
  await laptop.sync.syncNow();
  await phone.sync();
  assert.equal(clientView<SceneWire>(phone.state, 'scene')[0]!.name, 'Wind down');
});

test('a runner turned off and on again can be paired again with the same code', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  const laptop = computer(t, 'laptop', { clock, network });
  await laptop.sync.pair(codeOf(desk));
  await desk.sync.turnOff();
  await desk.sync.becomeRunner(); // same token and certificate, new runner identity
  await laptop.sync.pair(codeOf(desk));
  assert.equal(laptop.sync.view().paired?.lastError, undefined);
  assert.equal(laptop.home.schedules.length, 1);
});

test('a lost response is retried without a false conflict', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  const phone = new Phone(codeOf(desk), network);
  await phone.sync();
  phone.edit({ hour: 8 });
  network.dropReplies = 1; // the runner applies it, the phone never hears back
  await assert.rejects(phone.sync());
  assert.equal(desk.home.schedules[0]!.hour, 8);
  const { refusals } = await phone.sync(); // reconnect: same op ID, same answer
  assert.deepEqual(refusals, []);
  assert.equal(Object.keys(phone.state.pending).length, 0);
});

test('a paired computer that lost the runner keeps changes queued and never runs schedules', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  const laptop = computer(t, 'laptop', { clock, network });
  await laptop.sync.pair(codeOf(desk));
  network.down.add('desk');
  laptop.home.schedules[0]!.enabled = false;
  laptop.sync.localChange('schedule', SCHED);
  await laptop.sync.syncNow();
  assert.match(laptop.sync.view().paired!.lastError ?? '', /reach/);
  assert.equal(laptop.sync.view().paired!.unsent, 1);
  laptop.sync.tick(at(2026, 6, 1, 6, 59, 50)); laptop.sync.tick(at(2026, 6, 1, 7, 0, 5));
  assert.equal(laptop.home.runs.length, 0);
  network.down.delete('desk');
  await laptop.sync.syncNow();
  assert.equal(laptop.sync.view().paired!.unsent, 0);
  assert.equal(desk.home.schedules[0]!.enabled, false);
});

test('a restored backup is refused while sharing', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  assert.throws(() => desk.sync.assertMayReplaceAll(), /backup/);
});

test('an unreadable sync file fails closed', (t) => {
  const folder = mkdtempSync(join(tmpdir(), 'luma-ss-'));
  writeFileSync(join(folder, 'schedule-sync.json'), '{nope');
  const c = computer(t, 'x', { folder, clock: { now: new Date() }, network: new Network() });
  assert.equal(c.sync.mayExecute, false);
  assert.equal(c.sync.tick(), true, 'the home scheduler must not run either');
});

// ---------------- time ----------------

test('DST: a skipped local time never runs; a repeated one runs once', () => {
  const s = scheduleToWire(schedule({ hour: 2, minute: 30 }));
  // 2026-03-08 02:30 does not exist in New York.
  assert.deepEqual(occurrences(s, at(2026, 3, 8, 1, 0), at(2026, 3, 8, 4, 0)), []);
  const back = scheduleToWire(schedule({ hour: 1, minute: 30 }));
  // 2026-11-01 01:30 happens twice; both share one key, so the runner's dedupe runs it once.
  const occ = occurrences(back, new Date('2026-11-01T04:00:00Z'), new Date('2026-11-01T08:00:00Z'));
  assert.equal(occ.length, 2);
  assert.equal(new Set(occ.map((o) => o.key)).size, 1);
});

test('late ticks inside the grace window run; longer gaps are reported missed', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  desk.sync.tick(at(2026, 6, 1, 6, 59)); desk.sync.tick(at(2026, 6, 1, 7, 1, 30)); // 90 s late (App Nap)
  assert.equal(desk.home.runs.length, 1);
  desk.sync.tick(at(2026, 6, 2, 6, 50)); desk.sync.tick(at(2026, 6, 2, 7, 20)); // asleep through it
  assert.equal(desk.home.runs.length, 1);
  assert.equal(desk.sync.view().runner!.runs[0]!.status, 'missed');
});

test('a shared schedule due while a scene runs waits for it; past the grace, or disabled meanwhile, it never runs', async (t) => {
  const clock = { now: at(2026, 6, 1, 6, 0) }, network = new Network();
  const desk = await runner(t, 'desk', clock, network, (h) => { h.scenes = [scene()]; h.schedules = [schedule()]; });
  let busy = true;
  desk.deps.sceneRunning = () => busy;
  const report = () => desk.sync.view().runner!.runs[0];
  desk.sync.tick(at(2026, 6, 1, 6, 59, 50)); desk.sync.tick(at(2026, 6, 1, 7, 0, 10)); desk.sync.tick(at(2026, 6, 1, 7, 0, 40));
  assert.deepEqual(desk.home.runs, []);
  assert.equal(report(), undefined, 'reported only once it starts or misses');
  busy = false; clock.now = at(2026, 6, 1, 7, 1, 0);
  desk.sync.runQueued(); desk.sync.runQueued();
  assert.deepEqual(desk.home.runs, [SCENE], 'started once the runner is free, once');
  assert.deepEqual([report()!.status, report()!.occurrence], ['started', '2026-6-1-7-0']);

  busy = true;
  desk.sync.tick(at(2026, 6, 2, 6, 59, 50)); desk.sync.tick(at(2026, 6, 2, 7, 0, 10)); desk.sync.tick(at(2026, 6, 2, 7, 2, 1));
  assert.equal(report()!.status, 'missed');
  assert.match(report()!.detail!, /Another scene was still running 2 min after/);
  busy = false; desk.sync.runQueued();
  assert.equal(desk.home.runs.length, 1);

  busy = true;
  desk.sync.tick(at(2026, 6, 3, 6, 59, 50)); desk.sync.tick(at(2026, 6, 3, 7, 0, 10));
  desk.home.schedules = [schedule({ enabled: false })]; desk.sync.localChange('schedule', SCHED);
  busy = false; clock.now = at(2026, 6, 3, 7, 0, 30); desk.sync.runQueued();
  assert.equal(desk.home.runs.length, 1, 'disabled while waiting: dropped');
  assert.equal(report()!.occurrence, '2026-6-2-7-0');
});

// ---------------- real TLS ----------------

test('real TLS: pin checked before the token is sent, wrong token refused, large first sync is chunked', async (t) => {
  const clock = { now: new Date() };
  const net = new Network();
  const c = computer(t, '127.0.0.1', { clock, network: net, addresses: ['127.0.0.1'] });
  await c.sync.becomeRunner();
  const target = parsePairingCode(codeOf(c));
  assert.notEqual(target.port, 0);
  // Wrong pin: refused locally, before any request bytes.
  await assert.rejects(pinnedTransport({ ...target, pin: 'A'.repeat(26) }, SYNC_PATH, {}), (e: { status?: number }) => e.status === 495);
  // Wrong token: the runner answers 401.
  const bad = await pinnedTransport({ ...target, token: 'B'.repeat(26) }, SYNC_PATH, {});
  assert.equal(bad.status, 401);
  // A phone with many big scenes: several requests, all applied.
  const state = newClientState();
  for (let i = 0; i < 6; i++) {
    const id = `A1A1A1A1-0000-4000-8000-0000000001${String(i).padStart(2, '0')}`;
    const steps = Array.from({ length: 200 }, (_, j) => ({ id: `C3C3C3C3-0000-4000-8${String(i)}00-${String(j).padStart(12, '0')}`, deviceID: 'AA:BB:CC:DD:EE:01', command: { type: 'devices.capabilities.color_setting', instance: 'colorRgb', value: j }, delayMilliseconds: 10 }));
    stage(state, 'scene', sceneToWire({ id, name: `Big ${i}`, icon: 'sparkles', steps }));
  }
  const batches = buildBatches(state);
  assert.ok(batches.length > 1);
  for (const ops of batches) {
    const r = await pinnedTransport(target, SYNC_PATH, { protocol: 1, client: { id: 'D4D4D4D4-0000-4000-8000-000000000004', name: 'iPhone', platform: 'ios' }, since: state.cursor, ...(state.hubID ? { hubID: state.hubID } : {}), ops: ops as SyncOp[] });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(applyResponse(state, ops, r.body as SyncResponse), []);
  }
  assert.equal(c.home.scenes.length, 6);
});

// ---------------- Home integration ----------------

test('Home: a paired computer never runs schedules; the runner runs and the phone pause stops it', async (t) => {
  const network = new Network(), clock = { now: at(2026, 6, 1, 6, 0) };
  const make = (name: string) => {
    const dir = mkdtempSync(join(tmpdir(), 'luma-ss-home-'));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const runs: string[] = [], saves: unknown[] = [];
    const home = new Home({ demo: false, version: 't', storage: new HomeStorage(dir), secrets: new MemSecrets(),
      scheduleSyncOptions: { transport: network.transport, now: () => clock.now, addresses: () => [name], timeZone: () => 'America/New_York' } });
    // Scene execution needs real lights; record the attempt instead.
    (home as unknown as { runSavedScene: (id: string, save?: boolean) => string }).runSavedScene = (id, save) => { runs.push(id); saves.push(save); return 'r'; };
    network.hosts.set(name, home.scheduleSync);
    t.after(() => home.shutdown());
    return { home, runs, saves };
  };
  const desk = make('desk'), laptop = make('laptop');
  const deskHome = desk.home as unknown as { home: { scenes: LightScene[]; schedules: SceneSchedule[] } };
  deskHome.home.scenes = [scene()]; deskHome.home.schedules = [schedule()];
  (desk.home.scheduleSync as unknown as { saved: { port: number } }).saved.port = 0;
  await desk.home.scheduleSync.becomeRunner();
  await laptop.home.scheduleSync.pair(desk.home.snapshot().scheduleSync.runner!.pairingCodes[0]!);
  assert.equal(laptop.home.snapshot().schedules.length, 1);
  for (const d of [at(2026, 6, 1, 6, 59, 50), at(2026, 6, 1, 7, 0, 10)]) { desk.home.tickSchedules(d); laptop.home.tickSchedules(d); }
  assert.deepEqual([desk.runs.length, laptop.runs.length], [1, 0]);
  assert.deepEqual(desk.saves, [false], 'a shared schedule run never replaces the restore point');
  const phone = new Phone(desk.home.snapshot().scheduleSync.runner!.pairingCodes[0]!, network);
  await phone.sync();
  phone.edit({ enabled: false });
  await phone.sync();
  assert.equal(desk.home.snapshot().schedules[0]!.enabled, false);
  for (const d of [at(2026, 6, 2, 6, 59, 50), at(2026, 6, 2, 7, 0, 10)]) desk.home.tickSchedules(d);
  assert.equal(desk.runs.length, 1, 'disabled from the phone: no second run');
  assert.throws(() => desk.home.restoreBackup('{}'), /schedule sync off/);
});

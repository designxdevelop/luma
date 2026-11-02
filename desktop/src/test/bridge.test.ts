// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Headless Luma Bridge: the built CLI (dist/bridge/cli.js) is spawned as a real process on temp
// folders with file secrets, LAN discovery off and an explicit loopback port. A bare protocol client
// (the same core functions the iOS app ports) talks to it over real pinned TLS. No Govee key, no LAN:
// nothing here can reach a light.

import assert from 'node:assert/strict';
import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import {
  SYNC_PATH, applyResponse, buildBatches, certPin, clientView, formatPairingCode, newClientState, parsePairingCode, stage,
  type ClientState, type SceneWire, type ScheduleWire, type SyncResponse,
} from '../core/schedule-sync';
import { pinnedTransport } from '../main/schedule-sync';
import { assertNotAppProfile, defaultDataDir, lockIsLive, startBridge } from '../bridge/bridge';
import { encodeBackup } from '../main/backup';
import { emptyHome } from '../main/storage';
import { serviceDefinition } from '../bridge/cli';

const CLI = join(__dirname, '..', 'bridge', 'cli.js');
const SCENE = 'A1A1A1A1-0000-4000-8000-0000000000B1';
const SCHED = 'B2B2B2B2-0000-4000-8000-0000000000B2';
const posix = process.platform !== 'win32';

const SCHED2 = 'B2B2B2B2-0000-4000-8000-0000000000B6';

function cli(dir: string, args: string[], input?: string): Promise<{ code: number; out: string }> {
  return new Promise((done) => {
    const child = execFile(process.execPath, [CLI, '--data-dir', dir, ...args], { timeout: 30_000, env: { ...process.env, LUMA_BRIDGE_DATA: '' } }, (error, stdout, stderr) =>
      done({ code: error ? Number((error as { code?: number }).code ?? 1) : 0, out: `${stdout}${stderr}` }));
    child.stdin?.end(input ?? '');
  });
}

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address() as { port: number };
  await new Promise((r) => server.close(r));
  return port;
}

/** A configured bridge folder (runner, file secrets, LAN off) and its loopback pairing code. */
async function bridge(t: TestContext) {
  const root = mkdtempSync(join(tmpdir(), 'luma-bridge-test-'));
  t.after(() => { if (posix) chmodSync(join(root, 'data'), 0o700); rmSync(root, { recursive: true, force: true }); });
  const dir = join(root, 'data');
  const port = await freePort();
  const setup = await cli(dir, ['setup', '--secrets', 'file', '--port', String(port)]);
  assert.equal(setup.code, 0, setup.out);
  assert.equal((await cli(dir, ['configure', '--lan', 'off'])).code, 0);
  const secret = (name: string) => Buffer.from(readFileSync(join(dir, 'secrets', name), 'utf8'), 'base64').toString('utf8');
  const token = secret('schedule-sync-token');
  const pin = certPin(new X509Certificate((JSON.parse(secret('schedule-sync-tls')) as { cert: string }).cert).raw);
  return { dir, port, token, pin, code: formatPairingCode({ host: '127.0.0.1', port, pin, token }) };
}

interface Daemon { child: ChildProcess; output: () => string; exited: Promise<number> }
function daemons(t: TestContext) {
  const running: Daemon[] = [];
  t.after(async () => { for (const d of running) { d.child.kill('SIGKILL'); await d.exited; } });
  /** Starts `luma-bridge start`; resolves once it is listening (status heartbeat written) or has exited. */
  return async (dir: string): Promise<Daemon & { code?: number }> => {
    let out = '';
    const child = spawn(process.execPath, [CLI, '--data-dir', dir, 'start'], { stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout!.on('data', (c) => { out += c; }); child.stderr!.on('data', (c) => { out += c; });
    let done = false;
    const exited = new Promise<number>((r) => child.on('exit', (code) => { done = true; r(code ?? 1); }));
    const d = { child, output: () => out, exited };
    running.push(d);
    const ready = (async () => { while (!done && !/running as/.test(out)) await new Promise((r) => setTimeout(r, 50)); })();
    const code = await Promise.race([exited, ready.then(() => undefined)]);
    return { ...d, ...(code === undefined ? {} : { code }) };
  };
}

async function stop(d: Daemon): Promise<number> { d.child.kill('SIGTERM'); return d.exited; }

class Client {
  state: ClientState = newClientState();
  constructor(readonly code: string, readonly id = 'D4D4D4D4-0000-4000-8000-0000000000B4') {}
  async sync(): Promise<number> {
    const target = parsePairingCode(this.code);
    let status = 200;
    for (const ops of buildBatches(this.state)) {
      const r = await pinnedTransport(target, SYNC_PATH, { protocol: 1, client: { id: this.id, name: 'Test iPhone', platform: 'ios' }, ...(this.state.hubID ? { hubID: this.state.hubID } : {}), since: this.state.cursor, ops });
      status = r.status;
      if (r.status !== 200) return r.status;
      applyResponse(this.state, ops, r.body as SyncResponse);
    }
    return status;
  }
  schedule(): ScheduleWire | undefined { return clientView<ScheduleWire>(this.state, 'schedule').find((s) => s.id === SCHED); }
  seed(): void {
    // 03:17 on no weekday nearby is irrelevant: the schedule is paused immediately and no light exists.
    const scene: SceneWire = { id: SCENE, name: 'Bridge test', symbol: 'moon.fill', icon: 'moon', steps: [{ id: 'C3C3C3C3-0000-4000-8000-0000000000B3', deviceID: 'AA:BB:CC:DD:EE:FF:00:11', command: { type: 'devices.capabilities.on_off', instance: 'powerSwitch', value: 1 }, delayMilliseconds: 0 }] };
    stage(this.state, 'scene', scene);
    stage(this.state, 'schedule', { id: SCHED, sceneID: SCENE, hour: 3, minute: 17, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true } satisfies ScheduleWire);
  }
}

/** Every file the bridge wrote outside secrets/, as text. */
function dataText(dir: string): string {
  return readdirSync(dir).filter((f) => f !== 'secrets').map((f) => readFileSync(join(dir, f), 'utf8')).join('\n');
}

test('bridge daemon: paired client edits, pause survives restart, clean shutdown, no secrets in logs or files', async (t) => {
  const b = await bridge(t);
  const start = daemons(t);
  let d = await start(b.dir);
  assert.equal(d.code, undefined, d.output());

  // pairing-code is read-only and works while the daemon holds the lock.
  const codes = await cli(b.dir, ['pairing-code']);
  assert.equal(codes.code, 0, codes.out);

  const phone = new Client(b.code);
  phone.seed();
  assert.equal(await phone.sync(), 200);
  const pausedUntil = Date.now() + 86_400_000;
  stage(phone.state, 'schedule', { ...phone.schedule()!, pausedUntil });
  assert.equal(await phone.sync(), 200);
  const hubID = phone.state.hubID;

  // The status file follows each change within ~200 ms.
  let status = JSON.parse((await cli(b.dir, ['status', '--json'])).out);
  for (let i = 0; i < 20 && !status.status.runner.clients.length; i++) { await new Promise((r) => setTimeout(r, 100)); status = JSON.parse((await cli(b.dir, ['status', '--json'])).out); }
  assert.equal(status.state, 'running');
  assert.equal(status.status.role, 'runner');
  assert.equal(status.status.listening, true);
  assert.ok(status.status.runner.clients.some((c: { name: string }) => c.name === 'Test iPhone'), 'paired device shows with last seen');
  assert.ok(status.status.warnings.some((w: string) => /No lights are reachable/.test(w)), 'missing lights are surfaced, not silent');

  // Another instance, or a state-changing command, is refused while it runs.
  const second = await cli(b.dir, ['start']);
  assert.equal(second.code, 1); assert.match(second.out, /already running/);
  assert.equal((await cli(b.dir, ['configure', '--keep-awake', 'on'])).code, 1);

  assert.equal(await stop(d), 0, d.output());
  assert.ok(!existsSync(join(b.dir, 'bridge.lock')), 'lock released');
  assert.match(d.output(), /Luma Bridge stopped/);
  const stopped = JSON.parse((await cli(b.dir, ['status', '--json'])).out);
  assert.equal(stopped.state, 'stopped');
  assert.equal((await cli(b.dir, ['status'])).code, 3);

  // Restart: same runner identity, the pause is still there.
  d = await start(b.dir);
  assert.equal(d.code, undefined, d.output());
  const again = new Client(b.code, 'E5E5E5E5-0000-4000-8000-0000000000B5');
  assert.equal(await again.sync(), 200);
  assert.equal(again.state.hubID, hubID);
  assert.equal(again.schedule()?.pausedUntil, pausedUntil);

  // Wrong token: 401. Wrong pin: refused before the token is written.
  const target = parsePairingCode(b.code);
  assert.equal((await pinnedTransport({ ...target, token: 'B'.repeat(26) }, SYNC_PATH, {})).status, 401);
  await assert.rejects(pinnedTransport({ ...target, pin: 'A'.repeat(26) }, SYNC_PATH, {}), (e: { status?: number }) => e.status === 495);
  assert.equal(await stop(d), 0);

  const everything = `${d.output()}\n${dataText(b.dir)}`;
  for (const secret of [b.token, b.pin, b.code]) assert.ok(!everything.includes(secret), 'no token, pin or pairing code outside secrets/');
  if (posix) {
    for (const f of readdirSync(b.dir)) if (statSync(join(b.dir, f)).isFile()) assert.equal(statSync(join(b.dir, f)).mode & 0o077, 0, `${f} is owner-only`);
    assert.equal(statSync(b.dir).mode & 0o077, 0);
  }
});

test('bridge refuses to run: not set up, app profile, corrupt state, open secret permissions, port clash', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'luma-bridge-refuse-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const fresh = await cli(join(root, 'fresh'), ['start']);
  assert.equal(fresh.code, 1); assert.match(fresh.out, /Not set up/);

  const electron = join(root, 'electron');
  mkdirSync(electron); writeFileSync(join(electron, 'Local State'), '{}');
  const refused = await cli(electron, ['setup', '--secrets', 'file']);
  assert.equal(refused.code, 1); assert.match(refused.out, /belongs to a Luma app/);
  assert.ok(!existsSync(join(electron, 'bridge.json')), 'nothing written into an app profile');

  const start = daemons(t);
  const b = await bridge(t);
  // A port in use (for example a Luma window running schedules on this computer): exit non-zero.
  const blocker = createServer();
  await new Promise<void>((r) => blocker.listen(b.port, '0.0.0.0', r));
  const clash = await start(b.dir);
  blocker.close();
  assert.equal(clash.code, 1); assert.match(clash.output(), /could not start on port/);
  assert.ok(!existsSync(join(b.dir, 'bridge.lock')), 'lock released after a failed start');

  if (posix) {
    const secretFile = join(b.dir, 'secrets', 'schedule-sync-token');
    chmodSync(secretFile, 0o644);
    const open = await start(b.dir);
    assert.equal(open.code, 1); assert.match(open.output(), /readable by other users/);
    chmodSync(secretFile, 0o600);
  }

  const file = join(b.dir, 'schedule-sync.json');
  writeFileSync(file, '{ damaged');
  const corrupt = await start(b.dir);
  assert.equal(corrupt.code, 1); assert.match(corrupt.output(), /could not be read/);
  assert.equal(readFileSync(file, 'utf8'), '{ damaged', 'damaged state left untouched');
});

test('bridge: storage that stops saving fails closed (503, nothing applied)', { skip: !posix || process.getuid?.() === 0 }, async (t) => {
  const b = await bridge(t);
  const d = await daemons(t)(b.dir);
  assert.equal(d.code, undefined, d.output());
  const phone = new Client(b.code);
  phone.seed();
  assert.equal(await phone.sync(), 200);
  chmodSync(b.dir, 0o500); // no new files: the atomic save cannot write its temp file
  stage(phone.state, 'schedule', { ...phone.schedule()!, hour: 4 });
  assert.equal(await phone.sync(), 503);
  chmodSync(b.dir, 0o700);
  assert.equal(await stop(d), 0);
  const saved = JSON.parse(readFileSync(join(b.dir, 'schedule-sync.json'), 'utf8'));
  assert.equal(saved.runner.records[`schedule:${SCHED}`].value.hour, 3, 'the refused change was not saved');
});

test('bridge: a stale lock from a dead or pre-boot process does not block start', async (t) => {
  assert.equal(lockIsLive({ pid: process.ppid, startedAt: Date.now(), host: 'any' }), true);
  assert.equal(lockIsLive({ pid: process.ppid, startedAt: 1, host: 'any' }), false, 'started before this boot');
  assert.equal(lockIsLive({ pid: process.pid, startedAt: Date.now(), host: 'any' }), false, 'our own PID is a previous run (PID 1 in a container)');
  const b = await bridge(t);
  writeFileSync(join(b.dir, 'bridge.lock'), JSON.stringify({ pid: 2 ** 22 - 7, startedAt: Date.now(), host: require('node:os').hostname() }));
  const d = await daemons(t)(b.dir);
  assert.equal(d.code, undefined, d.output());
  assert.equal(await stop(d), 0);
});

test('bridge: doorbell alert is configurable headless when the build includes it', async (t) => {
  const b = await bridge(t);
  const status = await cli(b.dir, ['alert', 'status']);
  if (/no doorbell alert/.test(status.out)) { t.skip('doorbell alert not in this build'); return; }
  assert.equal(status.code, 0, status.out);
  const enabled = await cli(b.dir, ['alert', 'enable']);
  assert.equal(enabled.code, 0, enabled.out);
  assert.equal(JSON.parse(enabled.out).config.enabled, true);
  const d = await daemons(t)(b.dir);
  assert.equal(d.code, undefined, d.output());
  const s = JSON.parse((await cli(b.dir, ['status', '--json'])).out);
  assert.equal(s.status.doorbell?.enabled, true);
  assert.equal(await stop(d), 0);
});

test('bridge: data folder, app profile guard and service definitions', () => {
  assert.equal(defaultDataDir('linux', {}, '/home/pi'), '/home/pi/.config/luma-bridge');
  assert.equal(defaultDataDir('darwin', {}, '/Users/a'), '/Users/a/Library/Application Support/LumaBridge');
  assert.equal(defaultDataDir('linux', { LUMA_BRIDGE_DATA: '/srv/luma' }, '/home/pi'), '/srv/luma');
  assert.throws(() => assertNotAppProfile('/home/pi/.config/LumaLinux', 'linux', {}, '/home/pi'), /belongs to a Luma app/);
  assert.doesNotThrow(() => assertNotAppProfile('/home/pi/.config/luma-bridge', 'linux', {}, '/home/pi'));
  for (const kind of ['launchd', 'systemd', 'systemd-system', 'windows']) {
    const text = serviceDefinition(kind, '/data dir', '/usr/bin/node', '/opt/luma/bridge/cli.js');
    assert.match(text, /start/); assert.match(text, /\/opt\/luma\/bridge\/cli\.js/); assert.match(text, /data dir/);
    assert.doesNotMatch(text, /User=root/);
  }
  assert.throws(() => serviceDefinition('nope', '/d'));
});

test('bridge: hand-off between two bridges uses the protocol (pair, take-over; old runner retires)', async (t) => {
  const a = await bridge(t);
  const start = daemons(t);
  const da = await start(a.dir);
  assert.equal(da.code, undefined, da.output());
  const phone = new Client(a.code);
  phone.seed();
  assert.equal(await phone.sync(), 200);

  const bDir = join(mkdtempSync(join(tmpdir(), 'luma-bridge-b-')), 'data');
  t.after(() => rmSync(join(bDir, '..'), { recursive: true, force: true }));
  const bPort = await freePort();
  // A fresh folder: pair creates bridge.json itself. The code arrives on stdin, never argv.
  const pair = await cli(bDir, ['pair', '--secrets', 'file', '--port', String(bPort)], a.code);
  assert.equal(pair.code, 0, pair.out);
  assert.equal((await cli(bDir, ['configure', '--lan', 'off'])).code, 0);
  const take = await cli(bDir, ['take-over']);
  assert.equal(take.code, 0, take.out);
  assert.match(take.out, /now run on this bridge/);

  // The old runner saved its retirement: it runs nothing and sends devices on.
  let old = JSON.parse((await cli(a.dir, ['status', '--json'])).out);
  for (let i = 0; i < 20 && !old.status.runner.retiredTo; i++) { await new Promise((r) => setTimeout(r, 100)); old = JSON.parse((await cli(a.dir, ['status', '--json'])).out); }
  assert.ok(old.status.runner.retiredTo, 'old runner shows where schedules went');
  assert.equal(old.status.mayExecute, false);
  assert.equal(await new Client(a.code, 'E5E5E5E5-0000-4000-8000-0000000000B7').sync(), 410);

  const db = await start(bDir);
  assert.equal(db.code, undefined, db.output());
  const s = JSON.parse((await cli(bDir, ['status', '--json'])).out).status;
  assert.equal(s.role, 'runner'); assert.equal(s.mayExecute, true); assert.equal(s.port, bPort); assert.equal(s.listening, true);
  assert.equal(s.schedules, 1); assert.equal(s.scenes, 1);
  assert.equal(await stop(db), 0);
  assert.equal(await stop(da), 0);
});

test('bridge: import a home backup on a fresh folder, then set up', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'luma-bridge-import-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const dir = join(root, 'data');
  const file = join(root, 'home.luma-backup.json');
  writeFileSync(file, encodeBackup({ ...emptyHome(), scenes: [{ id: SCENE, name: 'Evening', icon: 'moon', steps: [{ id: 'C3C3C3C3-0000-4000-8000-0000000000B8', deviceID: 'AA:BB', command: { type: 'devices.capabilities.on_off', instance: 'powerSwitch', value: 1 }, delayMilliseconds: 0 }] }], schedules: [{ id: SCHED, sceneID: SCENE, hour: 3, minute: 17, weekdays: [1], enabled: true }] }));
  const imported = await cli(dir, ['import-backup', file, '--secrets', 'file']);
  assert.equal(imported.code, 0, imported.out);
  assert.match(imported.out, /1 scenes, 1 schedules/);
  const setup = await cli(dir, ['setup', '--port', String(await freePort())]);
  assert.equal(setup.code, 0, setup.out);
  const saved = JSON.parse(readFileSync(join(dir, 'schedule-sync.json'), 'utf8'));
  assert.ok(saved.runner.records[`schedule:${SCHED}`], 'imported schedule is shared by the runner');
});

test('bridge executes shared schedules after a restart: paused stays paused, a missing light fails with a reason', async (t) => {
  const b = await bridge(t);
  const log = () => undefined;
  let runtime = await startBridge({ dataDir: b.dir, version: 'test', log });
  t.after(() => runtime.stop());
  const slot = new Date(Date.now() + 2 * 60_000); slot.setSeconds(0, 0);
  const phone = new Client(b.code);
  phone.seed();
  stage(phone.state, 'schedule', { id: SCHED, sceneID: SCENE, hour: slot.getHours(), minute: slot.getMinutes(), weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true, pausedUntil: Date.now() + 86_400_000 });
  stage(phone.state, 'schedule', { id: SCHED2, sceneID: SCENE, hour: slot.getHours(), minute: slot.getMinutes(), weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true });
  assert.equal(await phone.sync(), 200);
  await runtime.stop();

  runtime = await startBridge({ dataDir: b.dir, version: 'test', log });
  runtime.home.tickSchedules(new Date(slot.getTime() + 30_000)); // 30 s late: inside the 2-minute grace
  const runs = runtime.status().runner!.runs;
  const paused = runs.find((r) => r.scheduleID === SCHED), failed = runs.find((r) => r.scheduleID === SCHED2);
  assert.equal(paused?.status, 'paused');
  assert.equal(failed?.status, 'failed'); // the scene's light isn't known here: refused before any write
  assert.ok(failed?.detail, 'the reason is reported');
  await runtime.stop();
  const again = JSON.parse(readFileSync(join(b.dir, 'schedule-sync.json'), 'utf8'));
  assert.equal(again.runner.runs[SCHED].status, 'paused', 'run reports are saved');
});

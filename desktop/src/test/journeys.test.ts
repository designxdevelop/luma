import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Home } from '../main/home';
import { HomeStorage, emptyHome, type SecretStore } from '../main/storage';
import { demoDevices } from '../main/demo';
import { brightness } from '../core/model';
import { createApiHandler } from '../core/api';
import type { FetchLike } from '../core/cloud';

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
async function until(predicate: () => boolean): Promise<void> {
  for (let n = 0; n < 100 && !predicate(); n++) await sleep(2);
  assert.ok(predicate(), 'Expected asynchronous state transition');
}
function storage(t: { after(fn: () => void): void }): HomeStorage {
  const directory = mkdtempSync(join(tmpdir(), 'luma-journey-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return new HomeStorage(directory);
}
function secrets() {
  const values = new Map<string, string>();
  const store: SecretStore = { available: true, read: name => values.get(name), write: (name, value) => { values.set(name, value); }, delete: name => { values.delete(name); } };
  return { store, values };
}

test('demo journey edits sample lights/scenes/schedules without transport, storage or credential access', async (t) => {
  const disk = storage(t);
  let credentialCalls = 0, networkCalls = 0, storageCalls = 0;
  disk.load = () => { storageCalls++; throw new Error('Forbidden demo read'); };
  disk.save = () => { storageCalls++; throw new Error('Forbidden demo save'); };
  const secretStore: SecretStore = { available: true, read: () => { credentialCalls++; return undefined; }, write: () => { credentialCalls++; }, delete: () => { credentialCalls++; } };
  const app = new Home({ demo: true, version: 'test', storage: disk, secrets: secretStore, cloudOptions: { fetch: async () => { networkCalls++; throw new Error('Forbidden demo network'); } } });
  t.after(() => app.shutdown());
  const id = app.snapshot().devices[0]!.id;
  await app.control(id, brightness(77));
  assert.equal(app.snapshot().devices[0]!.brightness, 77);
  app.assignRoom(id, 'Demo room');
  await app.loadEffects('demo-strip', false);
  const captured = app.captureScene('A sample scene', 'moon', [id]);
  app.saveSchedule({ id: 'schedule', sceneID: captured.id, hour: 12, minute: 30, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true });
  app.tickSchedules(new Date(2026, 9, 16, 12, 30));
  await until(() => !app.snapshot().runningSceneID);
  await assert.rejects(() => app.connect('synthetic-api-key'), /Demo/);
  await assert.rejects(() => app.discover(), /Demo/);
  await assert.rejects(() => app.startWebhook(), /Demo/);
  await assert.rejects(() => app.rotateToken(), /Demo/);
  assert.throws(() => app.copyToken(), /Demo/);
  app.persistNow();
  await app.shutdown();
  assert.deepEqual([networkCalls, credentialCalls, storageCalls], [0, 0, 0]);
  assert.deepEqual(readdirSync(disk.folder), []);
  assert.equal(app.snapshot().webhook.running, false);
});

test('fake connected journey separates immediate100 intent from confirmed40 API/storage and drops old readback', async (t) => {
  const disk = storage(t);
  const device = demoDevices()[0]!;
  delete device.isDemo;
  device.brightness = 40;
  disk.save({ ...emptyHome(), devices: [device] });
  const keyStore = secrets();
  let releaseRead!: () => void;
  let initialReadStarted = false, reads = 0, reportedBrightness = 40;
  const fetch: FetchLike = async (url, init) => {
    if (url.endsWith('/user/devices')) return response({ code: 200, data: [{ device: device.id, sku: device.sku, deviceName: device.name, type: 'devices.types.light', capabilities: device.capabilities }] });
    if (url.endsWith('/device/control')) {
      const body = JSON.parse(init.body!);
      reportedBrightness = body.payload.capability.value;
      return response({ code: 200 });
    }
    reads++;
    const value = reportedBrightness;
    if (reads === 1) { initialReadStarted = true; await new Promise<void>(resolve => { releaseRead = resolve; }); }
    return response({ code: 200, payload: { device: device.id, sku: device.sku, capabilities: [{ instance: 'online', state: { value: true } }, { instance: 'brightness', state: { value } }] } });
  };
  const app = new Home({ demo: false, version: 'test', storage: disk, secrets: keyStore.store, cloudOptions: { fetch, sleep: async () => {} }, controlOptions: { confirmDelays: [1], expireMs: 100 } });
  t.after(() => app.shutdown());
  await app.connect('synthetic-test-api-key');
  await until(() => initialReadStarted);
  const submitted = app.control(device.id, brightness(100));
  assert.equal(app.snapshot().devices[0]!.brightness, 100);
  assert.equal(app.confirmedDevices()[0]!.brightness, 40);
  app.persistNow();
  assert.equal(disk.load().devices[0]!.brightness, 40);
  const handler = createApiHandler({ demo: false, devices: () => app.confirmedDevices(), scenes: () => app.scenes(), runs: () => app.snapshot().runs, runScene: scene => app.runScene(scene) });
  const api = await handler({ method: 'GET', path: '/v1/devices', body: Buffer.alloc(0) });
  assert.equal((api.body as { brightness: number }[])[0]!.brightness, 40);
  releaseRead();
  await submitted;
  assert.equal(app.snapshot().devices[0]!.brightness, 100);
  await until(() => app.confirmedDevices()[0]!.brightness === 100);
  app.persistNow();
  assert.equal(disk.load().devices[0]!.brightness, 100);
});

test('unreadable saved home remains unchanged through construction and shutdown', async (t) => {
  const disk = storage(t);
  const bytes = '{broken home';
  writeFileSync(disk.file, bytes);
  const app = new Home({ demo: false, version: 'test', storage: disk });
  assert.equal(app.snapshot().canSave, false);
  assert.equal(app.snapshot().devices.length, 0);
  assert.match(app.snapshot().notice!, /left untouched/);
  app.persistNow();
  await app.shutdown();
  assert.equal(readFileSync(disk.file, 'utf8'), bytes);
});

test('webhook token stays masked in snapshots and activity; copy happens in host', async (t) => {
  const keyStore = secrets();
  let copied = '';
  const app = new Home({ demo: false, version: 'test', secrets: keyStore.store, copyToClipboard: value => { copied = value; } });
  t.after(() => app.shutdown());
  await app.rotateToken();
  assert.equal(app.snapshot().webhook.running, false);
  const token = keyStore.values.get('webhook-token')!;
  assert.ok(token.length >= 32);
  assert.ok(!JSON.stringify(app.snapshot()).includes(token));
  assert.ok(app.snapshot().webhook.maskedToken?.includes('…'));
  app.copyToken();
  assert.equal(copied, token);
  assert.ok(!JSON.stringify(app.snapshot()).includes(token));
});

function response(body: unknown) { return { status: 200, headers: { get: () => null }, text: async () => JSON.stringify(body) }; }

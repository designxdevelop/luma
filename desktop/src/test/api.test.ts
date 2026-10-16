// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createApiHandler, type AutomationHost } from '../core/api';
import type { HttpRequest, HttpResponse } from '../core/http';
import { LumaError, brightness, kelvin, power, rgb, validateScene } from '../core/model';
import type { AutomationRun, Capability, LightDevice, LightScene } from '../shared/types';

const capabilities = (maxBrightness: number): Capability[] => [
  { type: 'devices.capabilities.on_off', instance: 'powerSwitch' },
  { type: 'devices.capabilities.range', instance: 'brightness', parameters: { dataType: 'INTEGER', range: { min: 1, max: maxBrightness } } },
  { type: 'devices.capabilities.color_setting', instance: 'colorRgb' },
  { type: 'devices.capabilities.color_setting', instance: 'colorTemperatureK', parameters: { dataType: 'INTEGER', range: { min: 2000, max: 9000 } } },
];
const lamp: LightDevice = { id: 'lamp', sku: 'H6001', name: 'Desk Lamp', room: 'Office', ip: '192.168.1.5', capabilities: capabilities(80), power: true, brightness: 50, online: true, lastSeen: 1 };
const strip: LightDevice = { id: 'strip', sku: 'H6159', name: 'Strip', room: 'Den', capabilities: capabilities(100), power: false };
const scene: LightScene = { id: 'scene-1', name: 'Movie', icon: 'sparkles', steps: [{ id: 's1', deviceID: 'lamp', command: power(true), delayMilliseconds: 0 }] };
const run: AutomationRun = { id: 'run-1', sceneID: 'scene-1', name: 'Movie', status: 'completed', startedAt: 1 };

function setup(busy = false) {
  const started: LightScene[] = [];
  const host: AutomationHost = {
    demo: true,
    devices: () => [lamp, strip],
    scenes: () => [scene],
    runs: () => [run],
    runScene(s) {
      validateScene(s, [lamp, strip]);
      if (busy) throw new LumaError('Another sequence is running.', 409);
      started.push(s);
      return 'new-run';
    },
  };
  const handler = createApiHandler(host);
  const call = (method: string, path: string, body?: unknown): Promise<HttpResponse> =>
    handler({ method, path, body: Buffer.from(body === undefined ? '' : typeof body === 'string' ? body : JSON.stringify(body)) } as HttpRequest);
  return { started, call };
}

const errorOf = (r: HttpResponse) => (r.body as { error: string }).error;

test('read routes', async () => {
  const { call } = setup();
  assert.deepEqual(await call('GET', '/health'), { status: 200, body: { status: 'ok', demo: true } });
  const devices = await call('GET', '/v1/devices');
  assert.equal(devices.status, 200);
  const list = devices.body as Record<string, unknown>[];
  assert.deepEqual(list.map((d) => d.id), ['lamp', 'strip']);
  assert.ok(!('ip' in list[0]!), 'ip is not exposed');
  assert.deepEqual((await call('GET', '/v1/scenes')).body, [scene]);
  assert.deepEqual((await call('GET', '/v1/runs')).body, [run]);
  assert.deepEqual(await call('GET', '/v1/runs/run-1'), { status: 200, body: run });
  assert.equal((await call('GET', '/v1/runs/nope')).status, 404);
});

test('routing: unknown paths 404, wrong method 405, bad escapes 400', async () => {
  const { call, started } = setup();
  assert.equal((await call('GET', '/')).status, 404);
  assert.equal((await call('GET', '/v1/nothing')).status, 404);
  assert.equal((await call('GET', '/v1/devices/')).status, 404);
  assert.equal((await call('POST', '/health')).status, 405);
  assert.equal((await call('GET', '/v1/actions')).status, 405);
  assert.equal((await call('GET', '/v1/scenes/scene-1/run')).status, 405);
  assert.equal((await call('POST', '/v1/devices', {})).status, 405);
  assert.equal((await call('POST', '/v1/scenes/%E0%A4%A/run', {})).status, 400);
  assert.equal((await call('GET', '/v1/runs/%')).status, 400);
  assert.equal(started.length, 0);
});

test('scene run', async () => {
  const { call, started } = setup();
  const r = await call('POST', '/v1/scenes/scene-1/run', {});
  assert.equal(r.status, 202);
  const body = r.body as { accepted: boolean; runID: string; statusURL: string; note: string };
  assert.equal(body.accepted, true);
  assert.equal(body.runID, 'new-run');
  assert.equal(body.statusURL, '/v1/runs/new-run');
  assert.match(body.note, /not hardware-confirmed/);
  assert.deepEqual(started, [scene]);
  assert.equal((await call('POST', '/v1/scenes/scene-1/run')).status, 202, 'empty body is fine');
  assert.equal((await call('POST', '/v1/scenes/%73cene-1/run', {})).status, 202, 'percent-decoded id');
  assert.equal((await call('POST', '/v1/scenes/missing/run', {})).status, 404);
  assert.equal((await call('POST', '/v1/scenes/scene-1/run', '{nope')).status, 400);
  assert.equal((await call('POST', '/v1/scenes/scene-1/run', '[]')).status, 400);
  assert.equal(started.length, 3);
});

test('device commands', async () => {
  const { call, started } = setup();
  const command = brightness(40);
  const r = await call('POST', '/v1/devices/lamp/commands', command);
  assert.equal(r.status, 202);
  assert.equal(started.length, 1);
  const s = started[0]!;
  assert.equal(s.name, 'Webhook command');
  assert.equal(s.steps.length, 1);
  assert.deepEqual({ ...s.steps[0]!, id: '' }, { id: '', deviceID: 'lamp', command, delayMilliseconds: 0 });
  assert.match(s.steps[0]!.id, /^[0-9a-f-]{36}$/);

  for (const bad of [
    { ...command, extra: 1 },
    { type: command.type, instance: command.instance },
    { type: 1, instance: 'brightness', value: 1 },
    { type: command.type, instance: 5, value: 1 },
    [],
    'not json',
  ]) assert.equal((await call('POST', '/v1/devices/lamp/commands', bad)).status, 400, JSON.stringify(bad));
  assert.equal((await call('POST', '/v1/devices/lamp/commands', brightness(81))).status, 400, 'out of the lamp range 1..80');
  assert.equal((await call('POST', '/v1/devices/ghost/commands', command)).status, 404);
  assert.equal(started.length, 1);
});

test('actions: all, exact ID, room', async () => {
  const { call, started } = setup();
  assert.equal((await call('POST', '/v1/actions', { target: 'all', power: true, brightness: 40, color: '#FFB870' })).status, 202);
  const all = started[0]!;
  assert.equal(all.name, 'Webhook action');
  assert.deepEqual(all.steps.map((s) => [s.deviceID, s.command]), [
    ['lamp', power(true)], ['strip', power(true)],
    ['lamp', brightness(40)], ['strip', brightness(40)],
    ['lamp', rgb(0xffb870)], ['strip', rgb(0xffb870)],
  ]);
  assert.equal(new Set(all.steps.map((s) => s.id)).size, 6, 'fresh unique step IDs');

  const r = await call('POST', '/v1/actions', { target: 'strip', kelvin: 4000 });
  assert.equal(r.status, 202);
  assert.deepEqual(started[1]!.steps.map((s) => [s.deviceID, s.command]), [['strip', kelvin(4000)]]);
  assert.equal((r.body as { runID: string }).runID, 'new-run');

  assert.equal((await call('POST', '/v1/actions', { target: 'room:Office', power: false })).status, 202);
  assert.deepEqual(started[2]!.steps.map((s) => s.deviceID), ['lamp']);
});

test('invalid actions are rejected before anything runs', async () => {
  const { call, started } = setup();
  const bad: unknown[] = [
    { target: 'all', brightness: 0 },
    { target: 'all', brightness: 1e100 },
    { target: 'all', brightness: 0.5 },
    { target: 'all', color: '#xxyyzz' },
    { target: 'all', color: '#FFFFFF', kelvin: 3000 },
    { target: 'all', power: true, bogus: 1 },
    { power: true },
    { target: 'room:Garage', power: true },
    { target: 'nobody', power: true },
    { target: 'all' },
    '{bad json',
    '[]',
  ];
  for (const body of bad) assert.equal((await call('POST', '/v1/actions', body)).status, 400, JSON.stringify(body));
  // The lamp only goes to 80, so the host's scene validation rejects 90 for "all".
  assert.equal((await call('POST', '/v1/actions', { target: 'all', brightness: 90 })).status, 400);
  assert.equal(started.length, 0);
});

test('busy host maps to 409; unexpected errors are generic 500', async () => {
  const busy = setup(true);
  const r = await busy.call('POST', '/v1/actions', { target: 'all', power: true });
  assert.equal(r.status, 409);
  assert.match(errorOf(r), /running/);

  const boom = createApiHandler({ demo: false, devices: () => [lamp], scenes: () => [], runs: () => [], runScene: () => { throw new Error('db password=hunter2'); } });
  const res = await boom({ method: 'POST', path: '/v1/actions', body: Buffer.from('{"target":"all","power":true}') });
  assert.equal(res.status, 500);
  assert.doesNotMatch(JSON.stringify(res.body), /hunter2/);
});

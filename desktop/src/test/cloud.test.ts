// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { LightDevice } from '../shared/types';
import { GoveeCloud, type FetchLike, type HttpLike } from '../core/cloud';
import { power } from '../core/model';

const KEY = 'SECRETKEY-123';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const device = (id = 'AA:BB', sku = 'H6008'): LightDevice => ({ id, sku, name: 'Lamp', room: 'Unassigned', capabilities: [] });
const http = (body: unknown, status = 200, headers: Record<string, string> = {}): HttpLike => ({
  status,
  headers: { get: (name) => headers[name] ?? null },
  text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
});
const ok = (extra: Record<string, unknown>) => http({ code: 200, message: 'success', ...extra });
const stateReply = (caps: unknown[], id = 'AA:BB', sku = 'H6008') => ok({ payload: { sku, device: id, capabilities: caps } });
const cap = (instance: string, value: unknown) => ({ type: 'x', instance, state: { value } });

interface Call { url: string; method: string; headers: Record<string, string>; body?: string; redirect?: 'error'; at: number }

/** Fake transport and fake clock: sleep advances the clock instantly, so pacing is observable and tests are fast. */
function setup(replies: Array<HttpLike | (() => Promise<HttpLike>) | Error>) {
  let clock = 1_000_000;
  const calls: Call[] = [];
  const sleeps: number[] = [];
  const queue = [...replies];
  const fetch: FetchLike = async (url, init) => {
    calls.push({ url, method: init.method, headers: init.headers, body: init.body, redirect: init.redirect, at: clock });
    const next = queue.shift() ?? ok({});
    if (next instanceof Error) throw next;
    return typeof next === 'function' ? next() : next;
  };
  const cloud = new GoveeCloud(`  ${KEY}\n`, { fetch, now: () => clock, sleep: async (ms) => { sleeps.push(ms); clock += ms; } });
  return { cloud, calls, sleeps, now: () => clock };
}

const tick = () => new Promise<void>((resolve) => setImmediate(resolve));

test('devices: exact request, light filtering, verbatim capabilities', async () => {
  const caps = [{ type: 'devices.capabilities.range', instance: 'brightness', parameters: { dataType: 'INTEGER', range: { min: 1, max: 100, precision: 1 } } }];
  const { cloud, calls } = setup([ok({ data: [
    { device: 'A', sku: 'H6008', deviceName: 'Desk', type: 'devices.types.light', capabilities: caps },
    { device: 'B', sku: 'H7001', type: 'devices.types.socket', capabilities: [] },
    { device: 'C', sku: 'H6159', capabilities: [] },
  ] })]);
  const lights = await cloud.devices();
  assert.deepEqual(lights, [
    { id: 'A', sku: 'H6008', name: 'Desk', room: 'Unassigned', capabilities: caps },
    { id: 'C', sku: 'H6159', name: 'H6159', room: 'Unassigned', capabilities: [] },
  ]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.url, 'https://openapi.api.govee.com/router/api/v1/user/devices');
  assert.equal(calls[0]!.method, 'GET');
  assert.equal(calls[0]!.headers['Govee-API-Key'], KEY);
  assert.equal(calls[0]!.headers['Content-Type'], 'application/json');
  assert.equal(calls[0]!.body, undefined);
});

test('empty API key is rejected before any request', async () => {
  const { calls, ...rest } = setup([]);
  const cloud = new GoveeCloud('   ', { fetch: async () => { throw new Error('should not be called'); }, now: rest.now });
  await assert.rejects(cloud.devices(), { message: 'Add your Govee API key in Settings first.' });
  assert.equal(calls.length, 0);
});

test('401, non-200 body code and missing data are rejected without echoing remote text', async () => {
  const { cloud } = setup([
    http('nope SECRETKEY-123', 401),
    ok({}),
    http({ code: 400, message: 'secret account detail' }),
    http({ message: 'no code' }),
    http('<html>', 200),
    http('x'.repeat(8 * 1024 * 1024 + 1)),
    http('', 500),
  ]);
  await assert.rejects(cloud.devices(), /rejected the API key \(HTTP 401\).*rotated/);
  await assert.rejects(cloud.devices(), /invalid device list/);
  await assert.rejects(cloud.devices(), (e: Error) => e.message === 'Govee rejected the request (400).');
  await assert.rejects(cloud.devices(), /missing code/);
  await assert.rejects(cloud.devices(), /not valid JSON/);
  await assert.rejects(cloud.devices(), /too large/);
  await assert.rejects(cloud.devices(), { message: 'Govee request failed (HTTP 500).' });
});

test('control sends one POST envelope and is never retried, even on 500', async () => {
  const { cloud, calls } = setup([ok({}), http('', 500)]);
  await cloud.control(device(), power(true));
  const first = calls[0]!;
  assert.equal(first.url, 'https://openapi.api.govee.com/router/api/v1/device/control');
  assert.equal(first.method, 'POST');
  const body = JSON.parse(first.body!);
  assert.match(body.requestId, UUID);
  assert.deepEqual(body.payload, { sku: 'H6008', device: 'AA:BB', capability: { type: 'devices.capabilities.on_off', instance: 'powerSwitch', value: 1 } });

  await assert.rejects(cloud.control(device('CC'), power(false)), /HTTP 500/);
  assert.equal(calls.length, 2, 'a failed control must not be retried');
});

test('state parses all four values and stamps lastSeen when online', async () => {
  const { cloud, now } = setup([stateReply([cap('online', true), cap('powerSwitch', 1), cap('brightness', 42), cap('colorRgb', 0x112233), cap('colorTemperatureK', 0)])]);
  const state = await cloud.state(device());
  assert.deepEqual(state, { online: true, lastSeen: now(), power: true, brightness: 42, rgb: 0x112233, colorTemperature: 0 });
});

test('state ignores invalid values and returns only what it read', async () => {
  const { cloud } = setup([stateReply([cap('powerSwitch', 2), cap('brightness', 101), cap('brightness', 'x'), cap('colorRgb', 0x1000000), cap('colorTemperatureK', 999), cap('colorTemperatureK', 6500.5)])]);
  assert.deepEqual(await cloud.state(device()), {});
  const { cloud: c2 } = setup([stateReply([cap('colorTemperatureK', 6500)])]);
  assert.deepEqual(await c2.state(device()), { colorTemperature: 6500 });
});

test('offline state returns only {online:false}', async () => {
  const { cloud, calls } = setup([stateReply([cap('online', false), cap('powerSwitch', 1), cap('brightness', 80)])]);
  assert.deepEqual(await cloud.state(device()), { online: false });
  assert.equal(JSON.parse(calls[0]!.body!).payload.device, 'AA:BB');
  assert.equal(calls[0]!.url.endsWith('/device/state'), true);
});

test('mismatched device identity throws', async () => {
  const { cloud } = setup([stateReply([cap('powerSwitch', 1)], 'OTHER'), stateReply([cap('powerSwitch', 1)], 'AA:BB', 'H9999'), ok({ payload: { device: 'OTHER', sku: 'H6008', capabilities: [] } })]);
  await assert.rejects(cloud.state(device()), /different device/);
  await assert.rejects(cloud.state(device('AA:BB')), /different device model/);
  await assert.rejects(cloud.scenes(device('AA:BB'), false), /different device/);
});

test('scenes: DIY path, options preserved, and the single-capability form', async () => {
  const diy = { type: 'devices.capabilities.dynamic_scene', instance: 'diyScene', parameters: { dataType: 'ENUM', options: [{ name: 'Mine', value: 7 }] } };
  const { cloud, calls } = setup([
    ok({ payload: { sku: 'H6008', device: 'AA:BB', capabilities: [diy] } }),
    ok({ payload: { sku: 'H6008', device: 'AA:BB', capabilities: [] } }),
    ok({ payload: { sku: 'H6008', device: 'AA:BB', type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', value: { id: 1 } } }),
    ok({ payload: { sku: 'H6008', device: 'AA:BB' } }),
  ]);
  assert.deepEqual(await cloud.scenes(device(), true), [diy]);
  assert.equal(calls[0]!.url, 'https://openapi.api.govee.com/router/api/v1/device/diy-scenes');
  assert.deepEqual(await cloud.scenes(device(), false), []);
  assert.equal(calls[1]!.url, 'https://openapi.api.govee.com/router/api/v1/device/scenes');
  assert.deepEqual(await cloud.scenes(device('AA:BB'), false), [{
    type: 'devices.capabilities.dynamic_scene', instance: 'lightScene',
    parameters: { dataType: 'ENUM', options: [{ name: 'lightScene', value: { id: 1 } }] },
  }]);
  await assert.rejects(cloud.scenes(device('AA:BB'), false), /invalid scene capabilities/);
});

test('account spacing: different devices are at least 84 ms apart', async () => {
  const { cloud, calls } = setup([ok({}), ok({}), ok({})]);
  await Promise.all([cloud.control(device('A'), power(true)), cloud.control(device('B'), power(true)), cloud.control(device('C'), power(true))]);
  assert.equal(calls[1]!.at - calls[0]!.at, 84);
  assert.equal(calls[2]!.at - calls[1]!.at, 84);
});

test('two concurrent controls to the same device are serialized and >= 1000 ms apart', async () => {
  const { cloud, calls, sleeps } = setup([ok({}), ok({})]);
  await Promise.all([cloud.control(device(), power(true)), cloud.control(device(), power(false))]);
  assert.equal(calls.length, 2);
  assert.equal(calls[1]!.at - calls[0]!.at, 1000);
  assert.deepEqual(sleeps, [1000]);
  assert.equal(JSON.parse(calls[0]!.body!).payload.capability.value, 1, 'queue order is preserved');
  assert.equal(JSON.parse(calls[1]!.body!).payload.capability.value, 0);
});

test('repeated state reads of the same device are >= 2000 ms apart; other paths only 1000 ms', async () => {
  const { cloud, calls } = setup([stateReply([]), stateReply([]), ok({ payload: { sku: 'H6008', device: 'AA:BB', capabilities: [] } })]);
  await cloud.state(device());
  await cloud.state(device());
  assert.equal(calls[1]!.at - calls[0]!.at, 2000);
  await cloud.scenes(device(), false);
  assert.equal(calls[2]!.at - calls[1]!.at, 1000);
});

test('429 pauses the whole queue for Retry-After and is not retried', async () => {
  const { cloud, calls } = setup([http('', 429, { 'Retry-After': '30' }), ok({}), http('', 429, { 'Retry-After': '1' }), ok({}), http({ code: 429, message: 'slow down' }), ok({})]);
  await assert.rejects(cloud.control(device('A'), power(true)), /rate limit/);
  assert.equal(calls.length, 1, 'not retried');
  await cloud.control(device('B'), power(true)); // a different device is paused too
  assert.equal(calls[1]!.at - calls[0]!.at, 30_000);
  await assert.rejects(cloud.control(device('C'), power(true)), /rate limit/);
  await cloud.control(device('D'), power(true));
  assert.equal(calls[3]!.at - calls[2]!.at, 2000, 'Retry-After is clamped to at least 2 s');
  await assert.rejects(cloud.control(device('E'), power(true)), /rate limit/);
  await cloud.control(device('F'), power(true));
  assert.equal(calls[5]!.at - calls[4]!.at, 60_000, 'a body code 429 pauses for the 60 s default');
});

test('an aborted queued control is never sent, and the queue keeps working', async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const { cloud, calls } = setup([async () => { await gate; return ok({}); }, ok({}), ok({})]);
  const first = cloud.control(device(), power(true));
  await tick();
  assert.equal(calls.length, 1);
  const controller = new AbortController();
  const queued = cloud.control(device(), power(false), controller.signal);
  const queuedResult = assert.rejects(queued, { name: 'AbortError' });
  controller.abort();
  await queuedResult;
  release();
  await first;
  await cloud.control(device('OTHER'), power(true));
  assert.equal(calls.length, 2, 'the aborted request never reached fetch');
  assert.equal(JSON.parse(calls[1]!.body!).payload.device, 'OTHER');
  await assert.rejects(cloud.control(device(), power(true), AbortSignal.abort()), { name: 'AbortError' });
  assert.equal(calls.length, 2);
});

test('a failed request does not break the chain', async () => {
  const { cloud } = setup([new Error('network down'), ok({ data: [] })]);
  await assert.rejects(cloud.devices(), /Could not reach Govee/);
  assert.deepEqual(await cloud.devices(), []);
});

test('every request refuses redirects, and a 3xx response is a non-retried failure', async () => {
  const { cloud, calls } = setup([ok({ data: [] }), stateReply([]), ok({}), http('', 302, { Location: 'https://evil.example/' }), http(`moved ${KEY}`, 307), ok({}), http('', 399)]);
  await cloud.devices();
  await cloud.state(device());
  await cloud.control(device(), power(true));
  const redirected = (promise: Promise<unknown>) => assert.rejects(promise, (e: Error) => {
    assert.equal(e.name, 'LumaError');
    assert.equal(e.message, 'Govee returned an unexpected redirect.');
    assert.equal(e.message.includes('SECRETKEY'), false);
    return true;
  });
  await redirected(cloud.devices());
  await redirected(cloud.control(device('B'), power(true)));
  assert.equal(calls.length, 5, 'a redirect is neither followed nor retried');
  await cloud.control(device('C'), power(true)); // the chain keeps working
  await redirected(cloud.devices());
  assert.equal(calls.length, 7);
  for (const call of calls) assert.equal(call.redirect, 'error');
});

test('the API key never appears in thrown error messages', async () => {
  const { cloud } = setup([
    http(`bad ${KEY}`, 401), http(`bad ${KEY}`, 500), http({ code: 400, message: KEY }), http(`${KEY} not json`),
    new Error(`socket hang up ${KEY}`), http('', 429),
  ]);
  const messages: string[] = [];
  for (let i = 0; i < 6; i++) {
    try { await cloud.devices(); } catch (e) { messages.push((e as Error).message); }
  }
  assert.equal(messages.length, 6);
  for (const message of messages) assert.equal(message.includes('SECRETKEY'), false, message);
});

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { CapabilityCommand, LightDevice } from '../shared/types';
import { ControlEngine, type ControlTransport } from '../core/controls';
import { brightness, power, rgb, kelvin } from '../core/model';

const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

function lamp(): LightDevice {
  return {
    id: 'lamp', sku: 'H-test', name: 'Lamp', room: 'Office', power: true, brightness: 40, rgb: 0, colorTemperature: 3000, online: true,
    capabilities: [
      { type: 'devices.capabilities.on_off', instance: 'powerSwitch' },
      { type: 'devices.capabilities.range', instance: 'brightness', parameters: { dataType: 'INTEGER', range: { min: 1, max: 100, precision: 1 } } },
      { type: 'devices.capabilities.color_setting', instance: 'colorRgb' },
      { type: 'devices.capabilities.color_setting', instance: 'colorTemperatureK', parameters: { dataType: 'INTEGER', range: { min: 2200, max: 6500 } } },
    ],
  };
}

/** A controllable fake transport: each send waits until the test releases it. */
function harness(options: { confirmDelays?: number[]; expireMs?: number } = {}) {
  const device = lamp();
  const sent: CapabilityCommand[] = [];
  const releases: Array<(error?: Error) => void> = [];
  const reads: Array<(state: Partial<LightDevice>) => void> = [];
  const logs: Array<{ message: string; isError?: boolean }> = [];
  const transport: ControlTransport = {
    send: (_d, command) => new Promise((resolve, reject) => {
      sent.push(command);
      releases.push((error) => error ? reject(error) : resolve({ route: 'Cloud accepted' }));
    }),
    read: () => new Promise((resolve) => reads.push(resolve)),
  };
  const engine = new ControlEngine({
    device: (id) => (id === device.id ? device : undefined),
    update: (_id, mutate) => mutate(device),
    changed: () => {},
    log: (message, isError) => logs.push({ message, isError }),
    transport,
  }, { confirmDelays: options.confirmDelays ?? [5], expireMs: options.expireMs ?? 200, settleMs: 100 });
  const shown = () => engine.overlay(device);
  return { device, engine, sent, releases, reads, logs, shown };
}

test('stale cloud read cannot move display or confirmed state backwards (40 → 70 → 100)', async () => {
  const h = harness({ confirmDelays: [5, 5, 5] });
  const first = h.engine.submit('lamp', brightness(70), { coalesce: true });
  await tick();
  assert.equal(h.shown().brightness, 70);
  h.releases[0]!();
  await first;
  await tick(10); // confirmation read for 70 starts with the current revision
  assert.equal(h.reads.length, 1);
  const second = h.engine.submit('lamp', brightness(100), { coalesce: true });
  assert.equal(h.shown().brightness, 100, 'latest intent displays immediately');
  h.reads[0]!({ brightness: 70, online: true }); // reply to the older read arrives late
  await tick();
  assert.equal(h.device.brightness, 40, 'stale read is discarded, confirmed state untouched');
  assert.equal(h.shown().brightness, 100);
  h.releases[1]!();
  await second;
  await tick(10);
  h.reads[1]!({ brightness: 100, online: true });
  await tick();
  assert.equal(h.device.brightness, 100);
  assert.deepEqual(h.engine.pendingFor('lamp'), [], 'confirmation clears the overlay');
  h.engine.stop();
});

test('fast toggles keep submission order; only adjacent unsent writes coalesce', async () => {
  const h = harness();
  const writes = [false, true, false, true].map((on) => h.engine.submit('lamp', power(on), { coalesce: true }).catch(() => {}));
  await tick();
  assert.equal(h.shown().power, true, 'latest display intent');
  assert.equal(h.sent.length, 1);
  h.releases[0]!();
  await tick();
  // off(sent), then on/off/on unsent collapse into the final "on".
  assert.deepEqual(h.sent.map((c) => c.value), [0, 1]);
  h.releases[1]!();
  await Promise.all(writes);
  h.engine.stop();
});

test('coalescing never moves a write across another control', async () => {
  const h = harness();
  const all = [
    h.engine.submit('lamp', brightness(50), { coalesce: true }),
    h.engine.submit('lamp', brightness(60), { coalesce: true }),
    h.engine.submit('lamp', brightness(65), { coalesce: true }),
    h.engine.submit('lamp', rgb(0xff0000), { coalesce: true }),
    h.engine.submit('lamp', brightness(70), { coalesce: true }),
  ].map((p) => p.catch(() => {}));
  for (let i = 0; i < 5; i++) { await tick(); h.releases[i]?.(); }
  await Promise.all(all);
  // 50 was already in flight; 60→65 were adjacent and unsent; 70 stays after the color write.
  assert.deepEqual(h.sent.map((c) => `${c.instance}=${c.value}`), ['brightness=50', 'brightness=65', 'colorRgb=16711680', 'brightness=70']);
  h.engine.stop();
});

test('failure of an older write cannot roll back newer intent; newest failure rolls back', async () => {
  const h = harness();
  const older = h.engine.submit('lamp', brightness(70)).catch((e) => e);
  await tick();
  const newer = h.engine.submit('lamp', brightness(90)).catch((e) => e);
  h.releases[0]!(new Error('HTTP 500'));
  await older;
  assert.equal(h.shown().brightness, 90, 'older failure leaves newest intent');
  assert.equal(h.logs.at(-1)?.isError, undefined);
  await tick();
  h.releases[1]!(new Error('HTTP 500'));
  assert.ok((await newer) instanceof Error);
  assert.equal(h.shown().brightness, 40, 'rolled back to last confirmed');
  assert.equal(h.logs.at(-1)?.isError, true);
  assert.equal(h.sent.length, 2, 'no automatic write retry');
  h.engine.stop();
});

test('unconfirmed overlay expires within the bounded interval', async () => {
  const h = harness({ confirmDelays: [5], expireMs: 40 });
  const write = h.engine.submit('lamp', brightness(80));
  await tick();
  h.releases[0]!();
  await write;
  await tick(15);
  h.reads[0]?.({ brightness: 40, online: true }); // light still reports old value
  assert.equal(h.shown().brightness, 80);
  await tick(60);
  assert.equal(h.shown().brightness, 40);
  assert.match(h.logs.at(-1)!.message, /Could not confirm/);
});

test('delayed LAN status after confirmation does not overwrite latest intent', async () => {
  const h = harness({ confirmDelays: [1000] });
  const write = h.engine.submit('lamp', brightness(100));
  await tick();
  h.releases[0]!();
  await write;
  h.engine.report('lamp', { brightness: 100, online: true }, { lan: true });
  assert.equal(h.device.brightness, 100);
  h.engine.report('lamp', { brightness: 70, online: true }, { lan: true }); // older UDP packet arrives late
  assert.equal(h.device.brightness, 100, 'settle guard ignores contradicting status');
  await tick(120);
  h.engine.report('lamp', { brightness: 55, online: true }, { lan: true });
  assert.equal(h.device.brightness, 55, 'after the settle interval real changes apply');
  h.engine.stop();
});

test('offline cloud state keeps last known values', () => {
  const h = harness();
  h.engine.report('lamp', { online: false, brightness: 99 });
  assert.equal(h.device.brightness, 40);
  assert.equal(h.device.online, false);
});

test('validation happens before anything is queued', async () => {
  const h = harness();
  for (const bad of [brightness(0), brightness(1e100), brightness(0.5), kelvin(9000), kelvin(2100), rgb(-1), { type: 'x', instance: 'powerSwitch', value: 1 }]) {
    await assert.rejects(h.engine.submit('lamp', bad));
  }
  await assert.rejects(h.engine.submit('nope', power(true)));
  assert.equal(h.sent.length, 0);
});

test('cancelling a queued step does not send it and restores the in-flight intent', async () => {
  const h = harness();
  const first = h.engine.submit('lamp', brightness(60));
  await tick();
  const controller = new AbortController();
  const second = h.engine.submit('lamp', brightness(90), { signal: controller.signal });
  controller.abort();
  await assert.rejects(second, { name: 'AbortError' });
  assert.equal(h.shown().brightness, 60);
  h.releases[0]!();
  await first;
  await tick();
  assert.equal(h.sent.length, 1);
  h.engine.stop();
});

test('rgb intent replaces a pending white intent', async () => {
  const h = harness();
  void h.engine.submit('lamp', kelvin(4000)).catch(() => {});
  void h.engine.submit('lamp', rgb(0x00ff00)).catch(() => {});
  const view = h.engine.pendingFor('lamp').map((p) => p.instance);
  assert.deepEqual(view, ['colorRgb']);
  assert.equal(h.shown().colorTemperature, 0);
  h.engine.stop();
});

test('expiry is independent of a read that never resolves', async () => {
  const h = harness({ confirmDelays: [1], expireMs: 20 });
  const write = h.engine.submit('lamp', brightness(80));
  await tick();
  h.releases[0]!();
  await write;
  await tick(60); // reads[0] is never resolved (stuck behind the paced cloud queue)
  assert.equal(h.reads.length, 1);
  assert.deepEqual(h.engine.pendingFor('lamp'), []);
  assert.equal(h.shown().brightness, 40);
  h.reads[0]!({ brightness: 80, online: true }); // late reply after expiry is discarded
  await tick();
  assert.equal(h.device.brightness, 40);
});

test('white → RGB within the LAN settle window leaves confirmed color mode (and back)', async () => {
  const h = harness({ confirmDelays: [1000] });
  const white = h.engine.submit('lamp', kelvin(2700));
  await tick();
  h.releases[0]!();
  await white;
  h.engine.report('lamp', { rgb: 0, colorTemperature: 2700, online: true }, { lan: true });
  assert.equal(h.device.colorTemperature, 2700);
  const red = h.engine.submit('lamp', rgb(0xff0000));
  await tick();
  h.releases[1]!();
  await red;
  h.engine.report('lamp', { rgb: 0xff0000, colorTemperature: 0, online: true }, { lan: true });
  assert.deepEqual(h.engine.pendingFor('lamp'), []);
  assert.equal(h.device.rgb, 0xff0000);
  assert.equal(h.device.colorTemperature, 0, 'Kelvin 0 is not stripped by the superseded white settle guard');
  h.engine.report('lamp', { rgb: 0, colorTemperature: 2700, online: true }, { lan: true }); // late white packet
  assert.equal(h.device.colorTemperature, 0, 'late white packet cannot flip confirmed mode back');
  assert.equal(h.device.rgb, 0xff0000);
  const warm = h.engine.submit('lamp', kelvin(3000));
  await tick();
  h.releases[2]!();
  await warm;
  h.engine.report('lamp', { rgb: 0xff0000, colorTemperature: 3000, online: true }, { lan: true });
  assert.deepEqual(h.engine.pendingFor('lamp'), []);
  assert.equal(h.device.colorTemperature, 3000, 'RGB settle guard (Kelvin 0) does not block white');
  h.engine.stop();
});

test('cached RGB and explicit white telemetry cannot confirm a color write', async () => {
  const h = harness({ confirmDelays: [1000] });
  h.device.rgb = 0xff0000;
  h.device.colorTemperature = 2700;
  const write = h.engine.submit('lamp', rgb(0xff0000));
  await tick();
  h.releases[0]!();
  await write;
  h.engine.report('lamp', { online: true }, { lan: true });
  assert.equal(h.engine.pendingFor('lamp').length, 1, 'online alone is not fresh color confirmation');
  assert.equal(h.device.colorTemperature, 2700);
  h.engine.report('lamp', { rgb: 0xff0000, colorTemperature: 2700, online: true }, { lan: true });
  assert.equal(h.engine.pendingFor('lamp').length, 1, 'remembered RGB while white is not color mode');
  assert.equal(h.device.colorTemperature, 2700, 'explicit telemetry must never be rewritten');
  h.engine.report('lamp', { rgb: 0xff0000, online: true }, { lan: true });
  assert.equal(h.engine.pendingFor('lamp').length, 1, 'missing mode cannot confirm a white-capable light');
  h.engine.report('lamp', { rgb: 0xff0000, colorTemperature: 0, online: true }, { lan: true });
  assert.deepEqual(h.engine.pendingFor('lamp'), []);
  assert.equal(h.device.colorTemperature, 0);
  h.engine.stop();
});

test('fresh RGB on an RGB-only model confirms without inventing white telemetry', async () => {
  const h = harness({ confirmDelays: [1000] });
  h.device.capabilities = h.device.capabilities.filter((c) => c.instance !== 'colorTemperatureK');
  delete h.device.colorTemperature;
  const write = h.engine.submit('lamp', rgb(0xff0000));
  await tick();
  h.releases[0]!();
  await write;
  h.engine.report('lamp', { rgb: 0xff0000, online: true });
  assert.deepEqual(h.engine.pendingFor('lamp'), []);
  assert.equal(h.device.colorTemperature, undefined);
  h.engine.stop();
});

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { JSONValue, LightDevice, LightScene, SceneSchedule, SceneStep } from '../shared/types';
import { brightness, decodeScene, kelvin, power, repairStepIDs, validateCommand, validateScene, validateValue, whiteRange } from '../core/model';
import { SceneRunner, minuteKey, nextOccurrence, shouldRun, validateSchedule } from '../core/automation';

const segmentSchema: JSONValue = { dataType: 'STRUCT', fields: [
  { fieldName: 'segment', dataType: 'Array', elementType: 'INTEGER', elementRange: { min: 0, max: 14 }, size: { min: 1, max: 15 }, required: true },
  { fieldName: 'rgb', dataType: 'INTEGER', range: { min: 0, max: 16777215 }, required: true },
] };
const lamp: LightDevice = { id: 'lamp', sku: 'H-test', name: 'Lamp', room: 'Office', capabilities: [
  { type: 'devices.capabilities.on_off', instance: 'powerSwitch' },
  { type: 'devices.capabilities.range', instance: 'brightness', parameters: { dataType: 'INTEGER', range: { min: 1, max: 80 } } },
  { type: 'devices.capabilities.color_setting', instance: 'colorTemperatureK', parameters: { dataType: 'INTEGER', range: { min: 2700, max: 6500 } } },
  { type: 'devices.capabilities.segment_color_setting', instance: 'segmentedColorRgb', parameters: segmentSchema },
] };
const step = (id: string, command = power(true), delayMilliseconds = 0): SceneStep => ({ id, deviceID: 'lamp', command, delayMilliseconds });
const scene = (steps: SceneStep[], name = 'Evening'): LightScene => ({ id: 's1', name, icon: 'moon', steps });

test('valid scene passes; every invalid shape is rejected before execution', () => {
  validateScene(scene([step('a'), step('b', brightness(80), 1500)]), [lamp]);
  const invalid: LightScene[] = [
    scene([step('a')], ' '),
    scene([]),
    scene([step('a'), step('a')]), // duplicate step IDs
    scene([{ ...step('a'), deviceID: 'missing' }]),
    scene([step('a', power(true), 60_001)]),
    scene([step('a', power(true), 0.5)]),
    scene([step('a', power(true), 1e100)]),
    scene(Array.from({ length: 6 }, (_, i) => step(`d${i}`, power(true), 60_000))), // > 5 minutes total
    scene([step('a', brightness(81))]),
    scene([step('a', brightness(1e100))]),
    scene([step('a', kelvin(2000))]), // below model white bound
    scene([step('a', { type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', value: 1 })]),
    scene(Array.from({ length: 201 }, (_, i) => step(`x${i}`))),
  ];
  for (const s of invalid) assert.throws(() => validateScene(s, [lamp]), Error, JSON.stringify(s).slice(0, 120));
});

test('segment schema: bounds, uniqueness, integers, unknown fields', () => {
  const seg = (segment: unknown[], extra: object = {}) => ({ type: 'devices.capabilities.segment_color_setting', instance: 'segmentedColorRgb', value: { segment, rgb: 255, ...extra } as never });
  validateCommand(seg([0, 14]), lamp);
  for (const bad of [[], [15], [-1], [0.5], ['0'], [Infinity], [NaN], [0, 0], [1e100]]) assert.throws(() => validateCommand(seg(bad), lamp));
  assert.throws(() => validateCommand(seg([1], { surprise: 1 }), lamp));
  assert.throws(() => validateValue({ rgb: 1 }, segmentSchema), /segment/);
});

test('model white bounds come from the advertised range', () => {
  assert.deepEqual(whiteRange(lamp), [2700, 6500]);
  assert.deepEqual(whiteRange({ ...lamp, capabilities: [] }), [2000, 9000]);
  assert.deepEqual(whiteRange({ ...lamp, capabilities: [{ type: 'x', instance: 'colorTemperatureK', parameters: { dataType: 'INTEGER', range: { min: 1e100, max: 5 } } }] }), [2000, 9000], 'nonsense bounds fall back');
});

test('scene JSON import is decoded strictly and validated before use', () => {
  const ok = decodeScene({ name: 'Import', icon: 'sun', steps: [{ id: 'a', deviceID: 'lamp', command: power(true) }], extra: 'dropped' }, [lamp]);
  assert.equal(ok.steps[0]!.delayMilliseconds, 0);
  assert.equal('extra' in ok, false);
  assert.throws(() => decodeScene({ name: 'Bad', steps: [{ id: 'a', deviceID: 'lamp', command: brightness(1e100) }] }, [lamp]));
  assert.throws(() => decodeScene({ name: 'Bad', steps: 'nope' }, [lamp]));
  assert.throws(() => decodeScene('[]', [lamp]));
  assert.throws(() => decodeScene({ name: 'Dup', steps: [{ id: 'a', deviceID: 'lamp', command: power(true) }, { id: 'a', deviceID: 'lamp', command: power(false) }] }, [lamp]));
  const repaired = repairStepIDs(scene([step('a'), step('a'), step('')]));
  assert.equal(new Set(repaired.steps.map((s) => s.id)).size, 3);
  assert.equal(repaired.steps[0]!.id, 'a');
});

test('runner: one sequence at a time, delays honored, cancellation keeps applied steps', async () => {
  const sent: string[] = [];
  let release!: () => void;
  const runner = new SceneRunner({
    send: async (s, signal) => {
      sent.push(s.id);
      if (s.id === 'b') await new Promise<void>((resolve, reject) => { release = resolve; signal.addEventListener('abort', () => reject(Object.assign(new Error('x'), { name: 'AbortError' }))); });
    },
    changed: () => {}, log: () => {},
  });
  const id = runner.start(scene([step('a'), step('b'), step('c', power(false), 5)]));
  assert.throws(() => runner.start(scene([step('z')])), /already running/);
  await new Promise((r) => setTimeout(r, 5));
  runner.stop();
  await new Promise((r) => setTimeout(r, 5));
  const run = runner.runs.find((r) => r.id === id)!;
  assert.equal(run.status, 'cancelled');
  assert.deepEqual(sent, ['a', 'b']);
  assert.equal(runner.runningSceneID, undefined);
  void release;
  const second = runner.start(scene([step('q')]));
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(runner.runs.find((r) => r.id === second)!.status, 'completed');
});

test('runner records failures', async () => {
  const runner = new SceneRunner({ send: async () => { throw new Error('Govee request failed (HTTP 500).'); }, changed: () => {}, log: () => {} });
  const id = runner.start(scene([step('a')]));
  await new Promise((r) => setTimeout(r, 5));
  const run = runner.runs.find((r) => r.id === id)!;
  assert.equal(run.status, 'failed');
  assert.match(run.error!, /HTTP 500/);
});

test('schedules fire once per matching local minute and compute next times', () => {
  const at = new Date(2026, 9, 15, 18, 30, 0); // Thursday local time
  const s: SceneSchedule = { id: 'x', sceneID: 's1', hour: 18, minute: 30, weekdays: [5], enabled: true };
  assert.equal(shouldRun(s, at), true);
  const ran = { ...s, lastRunMinute: minuteKey(at) };
  assert.equal(shouldRun(ran, new Date(at.getTime() + 25_000)), false, 'no duplicate in the same minute');
  assert.equal(shouldRun(ran, new Date(at.getTime() + 60_000)), false, 'missed/late minute skipped');
  assert.equal(shouldRun({ ...s, enabled: false }, at), false);
  assert.equal(shouldRun({ ...s, weekdays: [2] }, at), false);
  assert.deepEqual(nextOccurrence(s, new Date(2026, 9, 15, 18, 31)), new Date(2026, 9, 22, 18, 30));
  assert.deepEqual(nextOccurrence({ ...s, weekdays: [1, 2, 3, 4, 5, 6, 7] }, new Date(2026, 9, 15, 18, 31)), new Date(2026, 9, 16, 18, 30));
  assert.equal(nextOccurrence({ ...s, weekdays: [] }, at), undefined);
  assert.throws(() => validateSchedule({ ...s, hour: 24 }, ['s1']));
  assert.throws(() => validateSchedule({ ...s, minute: 1e100 }, ['s1']));
  assert.throws(() => validateSchedule({ ...s, weekdays: [8] }, ['s1']));
  assert.throws(() => validateSchedule({ ...s, sceneID: 'gone' }, ['s1']));
  assert.deepEqual(validateSchedule({ ...s, weekdays: [3, 1, 3] }, ['s1']).weekdays, [1, 3]);
});

test('Array schemas with advertised options (no elementType) only accept listed members', () => {
  const schema: JSONValue = { fieldName: 'segment', dataType: 'Array', options: [{ value: 0 }, { value: 1 }], required: true };
  validateValue([0, 1], schema);
  assert.throws(() => validateValue([99], schema));
  assert.throws(() => validateValue([], schema), /segment/);
  assert.throws(() => validateValue([0, 0], schema), /unique/);
});

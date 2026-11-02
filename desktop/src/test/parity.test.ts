// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Pure parity modules: segment painter commands, sensor readings, backup format, and the
// light-only boundary for bulk actions.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Capability, JSONValue, LightDevice, SavedHome } from '../shared/types';
import { isLight, paintCommands, segmentSchema } from '../shared/devices';
import { parseReadings, readingLabel } from '../core/readings';
import { parseAction, validateCommand } from '../core/model';
import { applyBackup, decodeBackup, encodeBackup, iconFor, symbolFor } from '../main/backup';
import { emptyHome } from '../main/storage';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const segColor: Capability = { type: 'devices.capabilities.segment_color_setting', instance: 'segmentedColorRgb', parameters: { dataType: 'STRUCT', fields: [
  { fieldName: 'segment', dataType: 'Array', elementType: 'INTEGER', elementRange: { min: 0, max: 14 }, size: { min: 1, max: 4 }, required: true },
  { fieldName: 'rgb', dataType: 'INTEGER', range: { min: 0, max: 16777215 }, required: true },
] } };
const segLevel: Capability = { type: 'devices.capabilities.segment_color_setting', instance: 'segmentedBrightness', parameters: { dataType: 'STRUCT', fields: [
  { fieldName: 'segment', dataType: 'Array', options: [{ value: 3 }, { value: 1 }, { value: 2 }] },
  { fieldName: 'brightness', dataType: 'INTEGER', range: { min: 0, max: 100 }, required: true },
] } };
const strip: LightDevice = { id: 'strip', sku: 'H619A', name: 'Strip', room: 'Den', capabilities: [segColor, segLevel] };

test('segment schema reads ranges, options, value field and per-command limit', () => {
  const color = segmentSchema(segColor)!;
  assert.deepEqual(color.indexes, Array.from({ length: 15 }, (_, i) => i));
  assert.equal(color.valueField, 'rgb');
  assert.equal(color.perCommand, 4);
  const level = segmentSchema(segLevel)!;
  assert.deepEqual(level.indexes, [1, 2, 3]);
  assert.deepEqual(level.valueRange, [0, 100]);
  assert.equal(segmentSchema({ type: 'x', instance: 'segmentedColorRgb', parameters: { dataType: 'STRUCT' } }), undefined);
  assert.equal(segmentSchema({ type: 'x', instance: 'colorRgb' }), undefined);
  // A required field the painter can't fill makes the schema unpaintable rather than half-sent.
  const extra = structuredClone(segColor);
  (extra.parameters as { fields: JSONValue[] }).fields.push({ fieldName: 'mode', dataType: 'ENUM', required: true });
  assert.equal(segmentSchema(extra), undefined);
});

test('paintCommands groups by value, sorts segments, splits at size.max, and every command validates', () => {
  const schema = segmentSchema(segColor)!;
  const paint = new Map([[5, 0xff0000], [0, 0xff0000], [1, 0x00ff00], [2, 0xff0000], [3, 0xff0000], [4, 0xff0000], [9, 0x0000ff]]);
  const commands = paintCommands(schema, paint);
  assert.deepEqual(commands.map((c) => c.value), [
    { segment: [0, 2, 3, 4], rgb: 0xff0000 }, { segment: [1], rgb: 0x00ff00 }, { segment: [5], rgb: 0xff0000 }, { segment: [9], rgb: 0x0000ff },
  ]);
  for (const c of commands) validateCommand(c, strip);
  assert.deepEqual(paintCommands(schema, new Map()), []);
  assert.throws(() => paintCommands(schema, new Map([[15, 1]])), /Segment 15/);
  assert.throws(() => paintCommands(schema, new Map([[0, 0x1000000]])), /rgb must be/);
  assert.throws(() => paintCommands(segmentSchema(segLevel)!, new Map([[1, 101]])), /brightness must be/);
});

test('readings: advertised units, option names, compact JSON; skips controls, online and empty values', () => {
  const caps: Capability[] = [
    { type: 'devices.capabilities.property', instance: 'sensorTemperature', parameters: { unit: 'unit.temperature.fahrenheit' } },
    { type: 'devices.capabilities.work_mode', instance: 'workMode', parameters: { dataType: 'ENUM', options: [{ name: 'Sleep', value: 2 }] } },
  ];
  const reported: JSONValue[] = [
    { instance: 'online', state: { value: true } },
    { instance: 'powerSwitch', state: { value: 1 } },
    { instance: 'sensorTemperature', state: { value: 70.123 } },
    { instance: 'workMode', state: { value: 2 } },
    { instance: 'filterLifeTime', state: { value: { remaining: 80 } } },
    { instance: 'lightScene', state: { value: '' } },
    { instance: 'nightlightToggle', state: { value: '' } },
    { instance: 'noState' },
  ];
  assert.deepEqual(parseReadings(reported, caps, 5).map((r) => [r.label, r.text]), [
    ['Temperature', '70.12 °F'], ['Mode', 'Sleep'], ['Filter life', '{"remaining":80}'],
  ]);
  assert.equal(readingLabel('airPurifierSpeed'), 'Air purifier speed');
});

test('bulk targets mean lights: webhook all and room: skip appliances; an explicit ID still works', () => {
  const lamp: LightDevice = { id: 'lamp', sku: 'H6008', name: 'Lamp', room: 'Den', capabilities: [] };
  const heater: LightDevice = { id: 'heat', sku: 'H7130', name: 'Heater', room: 'Den', capabilities: [], deviceType: 'devices.types.heater' };
  assert.ok(isLight(lamp) && isLight({ deviceType: 'devices.types.light' }) && !isLight(heater));
  assert.deepEqual(parseAction({ target: 'all', power: true }, [lamp, heater]).deviceIDs, ['lamp']);
  assert.deepEqual(parseAction({ target: 'room:Den', power: true }, [lamp, heater]).deviceIDs, ['lamp']);
  assert.deepEqual(parseAction({ target: 'heat', power: true }, [lamp, heater]).deviceIDs, ['heat']);
  assert.throws(() => parseAction({ target: 'all', power: true }, [heater]));
});

test('backup: icon/symbol mapping, strict decode, and Electron output decodes back unchanged', () => {
  assert.equal(symbolFor('moon'), 'moon.stars');
  assert.equal(iconFor('moon.stars'), 'moon');
  assert.equal(iconFor('gamecontroller'), 'party');
  assert.equal(iconFor('unknown.symbol'), 'sparkles');
  const home: SavedHome = { ...emptyHome(), devices: [{ ...strip, customName: 'Strip', ip: '10.0.0.2' }, { id: 'demo', sku: 'D', name: 'Demo', room: 'R', capabilities: [], isDemo: true }],
    scenes: [{ id: 's', name: 'S', icon: 'coffee', steps: [{ id: 'a', deviceID: 'strip', command: { type: 'devices.capabilities.on_off', instance: 'powerSwitch', value: 1 }, delayMilliseconds: 250 }] }],
    schedules: [{ id: 'x', sceneID: 's', hour: 6, minute: 5, weekdays: [1, 7], enabled: false, lastRunMinute: '2026-1-1-6-5' }, { id: 'orphan', sceneID: 'gone', hour: 1, minute: 1, weekdays: [1], enabled: true }] };
  const text = encodeBackup(home, new Date('2026-11-02T12:34:56.789Z'));
  const raw = JSON.parse(text);
  assert.equal(raw.exportedAt, '2026-11-02T12:34:56Z');
  assert.equal(raw.scenes[0].symbol, 'cup.and.saucer');
  assert.equal(raw.schedules.length, 1, 'orphaned schedules are not exported');
  assert.equal(raw.schedules[0].lastRunMinute, undefined);
  assert.deepEqual(raw.lights, [{ id: 'strip', sku: 'H619A', customName: 'Strip', room: 'Den' }], 'no demo lights, no IP');
  const decoded = decodeBackup(text);
  assert.equal(decoded.scenes[0]!.icon, 'coffee');
  assert.equal(decoded.scenes[0]!.steps[0]!.delayMilliseconds, 250);
  assert.equal(decoded.schedules[0]!.sceneID, decoded.scenes[0]!.id);
  const bad = (patch: object) => JSON.stringify({ ...raw, ...patch });
  for (const text of [bad({ format: 'other' }), bad({ version: 2 }), bad({ scenes: [raw.scenes[0], raw.scenes[0]] }), bad({ lights: [{ id: 'a' }] }),
    bad({ scenes: [{ ...raw.scenes[0], steps: [{ ...raw.scenes[0].steps[0], delayMilliseconds: 70_000 }] }] }), 'x'.repeat(9 * 1024 * 1024)]) {
    assert.throws(() => decodeBackup(text));
  }
});

test('a real native backup (Swift HomeBackup encoder output) decodes with icons mapped and schedules kept', () => {
  const text = readFileSync(join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'native-backup.json'), 'utf8');
  const backup = decodeBackup(text);
  assert.ok(backup.scenes.length >= 1 && backup.scenes.every((s) => /^[0-9A-F-]{36}$/.test(s.id)));
  assert.equal(backup.scenes.find((s) => s.name === 'Evening unwind')?.icon, 'moon');
  assert.equal(backup.schedules.length, 1);
  assert.deepEqual(backup.schedules[0]!.weekdays, [2, 3, 4]);
  assert.equal(backup.lights.find((l) => l.id === 'demo-strip')?.customName, 'Sofa glow');
});

test('backup: Mac-length names are shortened, not refused; DreamView drafts survive a Windows/Linux round trip', () => {
  const native = JSON.parse(readFileSync(join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'native-backup.json'), 'utf8'));
  native.scenes[0].name = 'N'.repeat(100);
  native.lights[0].customName = 'C'.repeat(90);
  native.lights[0].room = 'R'.repeat(70);
  native.dreamViewDrafts = { 'demo-tv': { members: [{ deviceID: 'demo-strip', areas: [1, 2] }] }, gone: { members: [] } };
  const decoded = decodeBackup(JSON.stringify(native));
  assert.equal(decoded.scenes[0]!.name.length, 80);
  assert.equal(decoded.lights[0]!.customName!.length, 64);
  assert.equal(decoded.lights[0]!.room.length, 40);
  const home: SavedHome = { ...emptyHome(), devices: [{ id: 'demo-tv', sku: 'Demo TV backlight', name: 'TV', room: 'R', capabilities: [] }] };
  applyBackup(home, decoded);
  assert.deepEqual(home.dreamViewDrafts, { 'demo-tv': { members: [{ deviceID: 'demo-strip', areas: [1, 2] }] } }, 'only drafts for known lights, as on native');
  assert.deepEqual(JSON.parse(encodeBackup(home)).dreamViewDrafts, home.dreamViewDrafts);
  assert.throws(() => decodeBackup(JSON.stringify({ ...native, dreamViewDrafts: { x: { members: [{ deviceID: 'a', areas: [11] }] } } })));
});

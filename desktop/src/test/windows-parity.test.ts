// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Mac/iPhone features ported to Windows/Linux: Govee scene library, tray room power,
// floor plans (native plans.json format) and DreamView partner drafts.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Capability, LightDevice } from '../shared/types';
import { dreamViewMemberLimit, matchScene, matchesQuery, placePin, planSceneApply, roomPower, sceneOptions, sceneRows } from '../shared/library';
import { FloorPlanStore, decodePlans } from '../main/floor-plans';
import { Home } from '../main/home';

const scenes = (options: unknown[], instance = 'lightScene'): Capability => ({ type: 'devices.capabilities.dynamic_scene', instance, parameters: { dataType: 'ENUM', options } as never });
const light = (id: string, room: string, caps: Capability[], extra: Partial<LightDevice> = {}): LightDevice => ({ id, sku: 'H6008', name: id, room, capabilities: caps, ...extra });
const power: Capability = { type: 'devices.capabilities.on_off', instance: 'powerSwitch' };

test('scene options keep Govee order, name unnamed entries and drop exact duplicates', () => {
  const d = light('a', 'Den', [
    scenes([{ name: ' Sunrise ', value: 1 }, { name: 'Sunrise', value: 1 }, { name: 'Sunrise', value: 2 }, { value: 3 }, { name: 'No value' }]),
    scenes([{ name: 'Mine', value: { id: 9 } }], 'diyScene'),
  ]);
  assert.deepEqual(sceneOptions(d).map((o) => [o.kind, o.name, o.value]), [
    ['lightScene', 'Sunrise', 1], ['lightScene', 'Sunrise', 2], ['lightScene', 'Built-in 4', 3], ['diyScene', 'Mine', { id: 9 }],
  ]);
  assert.equal(matchScene('diyScene', 'mine', d)?.value && JSON.stringify(matchScene('diyScene', 'mine', d)!.value), '{"id":9}');
  assert.ok(matchesQuery('Crème brûlée', 'creme BRU'));
  assert.ok(matchesQuery('Anything', '  '));
  assert.ok(!matchesQuery('Forest', 'ocean'));
});

test('room rows count lights per scene name and room apply reports what it skipped', () => {
  const a = light('a', 'Den', [scenes([{ name: 'Aurora', value: 1 }, { name: 'aurora', value: 5 }])]);
  const b = light('b', 'Den', [scenes([{ name: 'AURORA', value: 2 }, { name: 'Forest', value: 3 }])]);
  const c = light('c', 'Den', [scenes([])]);
  assert.deepEqual(sceneRows([a, b, c]).map((r) => [r.name, r.count]), [['Aurora', 2], ['Forest', 1]]);
  assert.equal(sceneRows([a])[0]!.option?.value, 1);
  const plan = planSceneApply('lightScene', 'Forest', [a, b, c]);
  assert.deepEqual(plan.map((p) => p.skipped ?? p.command!.value), ["doesn't list Forest", 3, 'scenes not loaded']);
});

test('tray rooms list lights with a power switch only, Unassigned last', () => {
  const rooms = roomPower([
    light('a', 'Den', [power], { power: true }), light('b', 'Den', [power], { power: false }), light('c', 'Den', []),
    light('heater', 'Den', [power], { deviceType: 'devices.types.heater', power: true }),
    light('d', 'Unassigned', [power]), light('e', 'Attic', []),
  ]);
  assert.deepEqual(rooms, [{ room: 'Attic', ids: [], on: 0 }, { room: 'Den', ids: ['a', 'b'], on: 1 }, { room: 'Unassigned', ids: ['d'], on: 0 }]);
});

test('a light has one place across all floors; positions stay inside the image', () => {
  const plans = [{ id: 'A', name: 'Ground', pins: [{ deviceID: 'x', x: 0.1, y: 0.1 }] }, { id: 'B', name: 'Upstairs', pins: [] }];
  const moved = placePin(plans, 'B', 'x', 1, 0);
  assert.deepEqual(moved.map((p) => p.pins), [[], [{ deviceID: 'x', x: 1, y: 0 }]]);
  assert.throws(() => placePin(plans, 'B', 'x', 1.01, 0));
  assert.throws(() => placePin(plans, 'B', 'x', Number.NaN, 0));
  assert.throws(() => placePin(plans, 'missing', 'x', 0, 0), /not found/);
});

test('native plans.json decodes; any invalid pin rejects the whole file', () => {
  // As Swift's JSONEncoder writes [FloorPlan] (UUID uppercase).
  const native = [{ id: '6F1C6B0E-2C2B-4F5E-9C3A-0F4A7B1D2E3F', name: 'Ground floor', pins: [{ deviceID: 'AA:BB', x: 0.25, y: 0.75 }] }];
  assert.deepEqual(decodePlans(native), native);
  assert.throws(() => decodePlans([{ ...native[0], pins: [{ deviceID: 'AA:BB', x: 1.5, y: 0 }] }]));
  assert.throws(() => decodePlans([{ ...native[0], name: '  ' }]));
  assert.throws(() => decodePlans([native[0], native[0]]));
});

test('floor plan store: owner-only files, re-encoded images, and an unreadable file is preserved', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'luma-floors-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const encode = (data: Buffer) => (data.toString() === 'not an image' ? undefined : Buffer.concat([Buffer.from('PNG:'), data]));
  const store = new FloorPlanStore(dir, encode);
  assert.throws(() => store.add(Buffer.from('not an image')), /PNG or JPEG/);
  const id = store.add(Buffer.from('photo'));
  assert.match(id, /^[0-9A-F-]{36}$/);
  assert.equal(store.image(id)!.toString(), 'PNG:photo');
  store.rename(id, '  Upstairs  ');
  assert.throws(() => store.rename(id, 'x'.repeat(65)));
  store.place(id, 'lamp', 0.5, 0.5);
  const second = store.add(Buffer.from('other'));
  assert.deepEqual(store.list().map((p) => p.name), ['Upstairs', 'Floor 2']);
  store.place(second, 'lamp', 0.2, 0.3);
  assert.deepEqual(store.list().map((p) => p.pins.length), [0, 1]);
  store.replace(second, Buffer.from('new'));
  assert.equal(store.list()[1]!.imageVersion, 2);
  assert.deepEqual(store.list()[1]!.pins, [{ deviceID: 'lamp', x: 0.2, y: 0.3 }]);

  // Reloads in the native shape.
  const saved = JSON.parse(readFileSync(join(dir, 'plans.json'), 'utf8'));
  assert.deepEqual(saved, [{ id, name: 'Upstairs', pins: [] }, { id: second, name: 'Floor 2', pins: [{ deviceID: 'lamp', x: 0.2, y: 0.3 }] }]);
  assert.deepEqual(new FloorPlanStore(dir, encode).list().map((p) => p.id), [id, second]);
  if (process.platform !== 'win32') assert.equal(statSync(join(dir, 'plans.json')).mode & 0o777, 0o600);

  store.delete(second);
  assert.ok(!existsSync(join(dir, `${second}.png`)));

  writeFileSync(join(dir, 'plans.json'), '[{"id": "broken"');
  const damaged = new FloorPlanStore(dir, encode);
  assert.equal(damaged.writable, false);
  assert.throws(() => damaged.add(Buffer.from('photo')), /preserved/);
  assert.equal(readFileSync(join(dir, 'plans.json'), 'utf8'), '[{"id": "broken"');
});

test('demo home: floor plans in memory, pins need a known light', () => {
  const home = new Home({ demo: true, version: 't', floorPlans: new FloorPlanStore(undefined, (d) => d) });
  const id = home.floorPlan((f) => f.add(Buffer.from('img')));
  home.floorPlanPlace(id, 'demo-floor', 0.4, 0.6);
  assert.throws(() => home.floorPlanPlace(id, 'nope', 0.4, 0.6), /not found/);
  assert.deepEqual(home.snapshot().floorPlans[0]!.pins, [{ deviceID: 'demo-floor', x: 0.4, y: 0.6 }]);
  assert.equal(home.snapshot().floorPlansWritable, true);
});

test('DreamView drafts: model member limit, at least one area, never the main light itself', () => {
  const home = new Home({ demo: true, version: 't' });
  const tv = home.snapshot().devices.find((d) => d.id === 'demo-tv')!;
  home.saveDreamViewDraft(tv.id, { members: [{ deviceID: 'demo-strip', areas: [3, 1, 3] }] });
  assert.deepEqual(home.snapshot().dreamViewDrafts[tv.id], { members: [{ deviceID: 'demo-strip', areas: [1, 3] }] });
  assert.throws(() => home.saveDreamViewDraft(tv.id, { members: [{ deviceID: 'demo-strip', areas: [] }] }), /screen area/);
  assert.throws(() => home.saveDreamViewDraft(tv.id, { members: [{ deviceID: tv.id, areas: [1] }] }));
  assert.throws(() => home.saveDreamViewDraft(tv.id, { members: [{ deviceID: 'demo-strip', areas: [11] }] }));
  assert.equal(dreamViewMemberLimit('h6097'), 7);
  assert.equal(dreamViewMemberLimit('H66A0'), 10);
  home.saveDreamViewDraft(tv.id, { members: [] });
  assert.equal(home.snapshot().dreamViewDrafts[tv.id], undefined);
});

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HomeStorage, emptyHome } from '../main/storage';
import { DEFAULT_SYNC_SETTINGS } from '../shared/sync-math';
import { DAY_PRESETS, duplicateScene, filterLights } from '../renderer/preferences';
import type { LightDevice } from '../shared/types';

test('search matches names, rooms and models without case or surrounding whitespace', () => {
  const devices: LightDevice[] = [{ id: '1', name: 'Desk', room: 'Office', sku: 'H123', capabilities: [] }, { id: '2', name: 'Bed', room: 'Bedroom', sku: 'H456', capabilities: [] }];
  assert.deepEqual(filterLights(devices, ' OFFICE ').map(d => d.id), ['1']);
  assert.deepEqual(filterLights(devices, 'h456').map(d => d.id), ['2']);
  assert.equal(filterLights(devices, 'missing').length, 0);
});

test('schedule presets and duplicate preserve content with independent IDs', () => {
  assert.deepEqual(DAY_PRESETS.weekdays, [2, 3, 4, 5, 6]);
  assert.deepEqual(DAY_PRESETS.weekends, [1, 7]);
  assert.equal(DAY_PRESETS.daily.length, 7);
  const original = { id: 'a', name: 'Evening', icon: 'sparkles', steps: [{ id: 'b', deviceID: 'light', command: { type: 'x', instance: 'y', value: 1 }, delayMilliseconds: 0 }] };
  let n = 0; const copy = duplicateScene(original, () => String(++n));
  assert.equal(copy.name, 'Evening Copy'); assert.notEqual(copy.id, original.id); assert.notEqual(copy.steps[0]!.id, original.steps[0]!.id);
  copy.steps[0]!.command.value = 0; assert.equal(original.steps[0]!.command.value, 1);
});

test('appearance and sync settings and assignments survive storage round trip', () => {
  const dir = mkdtempSync(join(tmpdir(), 'luma-prefs-'));
  try {
    const storage = new HomeStorage(dir);
    storage.save({ ...emptyHome(), appearance: 'dark', syncSettings: { ...DEFAULT_SYNC_SETTINGS, vivid: true }, syncAssignments: [{ id: 'a', region: 'edgeLeft', included: true }, { id: 'b', region: 'right', included: false }] });
    const loaded = storage.load();
    assert.equal(loaded.appearance, 'dark'); assert.equal(loaded.syncSettings?.vivid, true);
    assert.deepEqual(loaded.syncAssignments, [{ id: 'a', region: 'edgeLeft', included: true }, { id: 'b', region: 'right', included: false }]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

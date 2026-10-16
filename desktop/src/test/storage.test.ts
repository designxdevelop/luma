import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HomeStorage, emptyHome } from '../main/storage';
import { demoDevices, demoScenes } from '../main/demo';
import type { SavedHome } from '../shared/types';

function fixture(t: { after(fn: () => void): void }) {
  const directory = mkdtempSync(join(tmpdir(), 'luma-storage-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return new HomeStorage(directory);
}
const home = (): SavedHome => ({ ...emptyHome(), devices: demoDevices(), scenes: demoScenes(), schedules: [{ id: 'schedule', sceneID: 'demo-scene-focus', hour: 9, minute: 15, weekdays: [2, 3, 4, 5, 6], enabled: true, lastRunMinute: '2026-10-16-9-15' }] });

test('home round-trip keeps confirmed values and strips runtime/unknown fields', (t) => {
  const storage = fixture(t);
  assert.deepEqual(storage.load(), emptyHome());
  const source = home();
  source.devices[0]!.ip = '192.0.2.20';
  Object.assign(source, { apiKey: 'synthetic-should-not-save', pending: { brightness: 100 } });
  storage.save(source);
  const saved = readFileSync(storage.file, 'utf8');
  assert.equal(saved.includes('synthetic-should-not-save'), false);
  assert.equal(saved.includes('192.0.2.20'), false);
  assert.equal(saved.includes('"online"'), false);
  assert.equal(saved.includes('"isDemo"'), false);
  assert.equal(saved.includes('"pending"'), false);
  const loaded = storage.load();
  assert.equal(loaded.devices[0]!.brightness, 65);
  assert.equal(loaded.devices[0]!.online, undefined);
  assert.deepEqual(loaded.scenes, source.scenes);
  assert.equal(loaded.schedules[0]!.lastRunMinute, '2026-10-16-9-15');
  assert.deepEqual(readdirSync(storage.folder), ['home.json']);
});

test('malformed persisted shapes are rejected before rendering and original bytes survive save attempts', (t) => {
  const storage = fixture(t);
  const edits: ((v: any) => void)[] = [
    v => { v.devices[0].name = 123; },
    v => { v.devices[0].capabilities = [null]; },
    v => { v.scenes[0].steps = [null]; },
    v => { v.scenes[0].steps[0].command.value = 1e100; },
    v => { v.scenes[0].steps[0].delayMilliseconds = -1; },
    v => { v.schedules[0].weekdays = ['Monday']; },
    v => { v.schedules[0].hour = 1e100; },
    v => { v.devices.push(v.devices[0]); },
    v => { v.scenes.push(v.scenes[0]); },
  ];
  for (const edit of edits) {
    const bad = home(); edit(bad);
    const original = JSON.stringify(bad);
    writeFileSync(storage.file, original);
    assert.throws(() => storage.load());
    assert.throws(() => storage.save(emptyHome()));
    assert.equal(readFileSync(storage.file, 'utf8'), original);
  }
});

test('local legacy duplicate/missing step IDs are repaired without changing commands', (t) => {
  const storage = fixture(t);
  const source = home();
  source.scenes[0]!.steps[1]!.id = source.scenes[0]!.steps[0]!.id;
  source.scenes[0]!.steps[2]!.id = '';
  writeFileSync(storage.file, JSON.stringify(source));
  const loaded = storage.load();
  const steps = loaded.scenes[0]!.steps;
  assert.equal(new Set(steps.map(s => s.id)).size, steps.length);
  assert.ok(steps.every(s => s.id));
  assert.deepEqual(steps.map(s => s.command), source.scenes[0]!.steps.map(s => s.command));
});

test('file and nesting limits reject damaged input without replacing it', (t) => {
  const storage = fixture(t);
  writeFileSync(storage.file, ' '.repeat(8 * 1024 * 1024 + 1));
  assert.throws(() => storage.load());
  const source = home();
  let nested: any = {};
  for (let n = 0; n < 15; n++) nested = { nested };
  source.devices[0]!.capabilities[0]!.parameters = nested;
  writeFileSync(storage.file, JSON.stringify(source));
  assert.throws(() => storage.load());
  const bytes = readFileSync(storage.file, 'utf8');
  assert.throws(() => storage.save(emptyHome()));
  assert.equal(readFileSync(storage.file, 'utf8'), bytes);
});

test('validation failure before atomic save preserves a previously good home', (t) => {
  const storage = fixture(t);
  storage.save(home());
  const original = readFileSync(storage.file, 'utf8');
  const invalid = home(); invalid.devices[0]!.brightness = NaN;
  assert.throws(() => storage.save(invalid));
  assert.equal(readFileSync(storage.file, 'utf8'), original);
  // A failed save is recoverable; atomic replacement also works over an existing file.
  const updated = home(); updated.devices[0]!.room = 'New room';
  storage.save(updated);
  assert.equal(storage.load().devices[0]!.room, 'New room');
  assert.deepEqual(readdirSync(storage.folder), ['home.json']);
});

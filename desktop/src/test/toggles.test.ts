// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ToggleIntents } from '../renderer/toggles';

test('effect toggle keeps the latest intent, sends off, and rolls back only on the newest failure', () => {
  const t = new ToggleIntents();
  const k = 'lamp|nightlightToggle';
  assert.equal(t.value(k), false);
  const on = t.request(k, true);
  t.settle(k, on, true, true);
  assert.equal(t.value(k), true, 'stays on across later snapshots/renders');
  const off = t.request(k, false);
  assert.equal(t.value(k), false, 'next click requests off, not on again');
  const on2 = t.request(k, true);
  t.settle(k, off, false, false); // stale failure of an older request
  assert.equal(t.value(k), true);
  t.settle(k, on2, true, false); // newest fails → last successful value
  assert.equal(t.value(k), true);
  const off2 = t.request(k, false);
  t.settle(k, off2, false, true);
  const on3 = t.request(k, true);
  t.settle(k, on3, true, false);
  assert.equal(t.value(k), false, 'rolls back to the last success (off)');
  const fresh = 'lamp|other';
  t.settle(fresh, t.request(fresh, true), true, false);
  assert.equal(t.value(fresh), false, 'no prior success rolls back to off');
});

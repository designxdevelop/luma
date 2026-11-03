// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Byte vectors come from ha-govee-led-ble @ b845c59 tests (`test_h6099.py`,
// `test_h6099_dreamview.py`, `test_govee_encryption.py`). Crypto vectors were
// produced separately with Python `cryptography` from the same algorithm
// description. Ported from LumaCoreTests GoveeBLETests.swift.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DreamView, type DreamViewSetting, GoveeBLEProfile, type Pact, type Query, brightness, color, frame, modelFromLocalName, parseAdvertisement,
  parseStatus, power, queryFrame, reassembleA3, videoMode,
} from '../core/ble';
import { type Failure, GoveeBLESession, type Marker, hex, parseV1Handshake, parseV2Response, seal, v1 } from '../core/ble-crypto';
import { type Member, captureSummary, decodeCapture, encodeGroup, parseGroup } from '../core/ble-capture';

const f = (s: string) => frame(hex(s));
const h = hex;
const range = (lo: number, hi: number) => Array.from({ length: hi - lo }, (_, i) => lo + i);
const failure = (reason: Failure) => (e: unknown) => (e as { failure?: Failure }).failure === reason;
const value = (bytes: number[]): Marker => ({ kind: 'value', bytes });
const absent: Marker = { kind: 'absent' };

test('BLE commands match source vectors', () => {
  assert.deepEqual(power(true), f('330101'));
  assert.deepEqual(brightness(42), f('33042a'));
  assert.deepEqual(color(1, 2, 3, 0x3FFF), f('330515010102030000000000ff3f'));
  assert.deepEqual(color(1, 2, 3, 0x2000), f('3305150101020300000000000020'));
  assert.deepEqual(videoMode('game', false, 42, true, 55), f('33050001082a010237'));
  const queries: [Query, string][] = [['power', 'aa0100'], ['brightness', 'aa0400'], ['colorMode', 'aa0501'], ['firmware', 'aa0600'], ['hardware', 'aa0703']];
  for (const [query, prefix] of queries) assert.deepEqual(queryFrame(query), f(prefix));
  assert.throws(() => brightness(101), { message: 'Brightness must be 0–100.' });
  assert.throws(() => videoMode('movie', true, 0, false, 0), { message: 'Saturation must be 1–100.' });
});

test('BLE status replies parse only what the schema defines', () => {
  assert.deepEqual(parseStatus(f('aa0101')), { kind: 'power', on: true });
  assert.deepEqual(parseStatus(f('aa042a')), { kind: 'brightness', percent: 42 });
  assert.deepEqual(parseStatus(f('aa050001082a010237')), { kind: 'mode', mode: { kind: 'video', source: 'game', wholeScreen: false, saturation: 42, soundEffects: true, softness: 55 } });
  assert.deepEqual(parseStatus(f('aa0515011194')), { kind: 'mode', mode: { kind: 'staticColor', kelvin: 4500 } });
  assert.deepEqual(parseStatus(f('aa05043412')), { kind: 'mode', mode: { kind: 'scene', id: 0x1234 } });
  assert.deepEqual(parseStatus(f('aa050a3412')), { kind: 'mode', mode: { kind: 'other', value: 0x0A } });
  assert.deepEqual(parseStatus(f('aa06' + '312e30322e3033')), { kind: 'firmware', version: '1.02.03' });
  assert.deepEqual(parseStatus(f('aa0703' + '312e3034')), { kind: 'hardware', version: '1.04' });
  assert.equal(parseStatus(f('aa04ff')), undefined);
  assert.equal(parseStatus(f('330101')), undefined);
  assert.equal(parseStatus([...f('aa0101').slice(0, -1), 0]), undefined);
});

test('BLE DreamView module reads and writes', () => {
  assert.deepEqual(DreamView.query('switchGroup'), f('aa600101'));
  const reads: [DreamViewSetting, string][] = [['memberBrightness', 'aa6003'], ['sameBrightness', 'aa6004'], ['memberConnect', 'aa6005'], ['saturation', 'aa6009'], ['videoSettings', 'aa600a'], ['sound', 'aa600b']];
  for (const [setting, prefix] of reads) assert.deepEqual(DreamView.query(setting), f(prefix));
  assert.deepEqual(DreamView.setEnabled(true), f('3360010101'));
  assert.deepEqual(DreamView.setEnabled(false), f('3360010001'));
  assert.deepEqual(DreamView.setSaturation(50), f('33600932'));
  assert.deepEqual(DreamView.setVideo(false, true), f('33600a0101'));
  assert.deepEqual(DreamView.parse(f('aa600aabcd')), { kind: 'videoSettings', applyArea: 0xAB, contentMode: 0xCD });
  assert.deepEqual(DreamView.parse(f('aa600101')), { kind: 'enabled', on: true });
  assert.deepEqual(DreamView.parse(f('aa600b014f')), { kind: 'sound', enabled: true, softness: 79 });
  assert.deepEqual(DreamView.parse(f('aa600501000000000000007f00')), { kind: 'memberConnect', raw: [1, 0, 0, 0, 0, 0, 0, 0, 127, 0] });
  const brightnessReading = DreamView.parse(f('aa6003'));
  assert.ok(brightnessReading?.kind === 'memberBrightness' && brightnessReading.raw.length === 16);
  for (const bad of [f('aa600c'), f('3360010101'), f('aa600d'), f('aa6011'), f('aa6009').slice(0, -1), [...f('aa6009').slice(0, -1), 0xFF], f('aa6109')]) {
    assert.equal(DreamView.parse(bad), undefined);
    assert.equal(parseStatus(bad), undefined);
  }
});

test('BLE advertisement, local name and profile', () => {
  const enc = parseAdvertisement([0x43, 0x88, ...h('ec00010100')]);
  assert.ok(enc?.supportsEncryption === true);
  assert.deepEqual(enc.pact, { type: 1, code: 1 });
  const plain = parseAdvertisement([0x02, 0x88, ...h('ec00020100')]);
  assert.ok(plain?.supportsEncryption === false);
  assert.deepEqual(plain.pact, { type: 2, code: 1 });
  assert.deepEqual(parseAdvertisement([0x01, 0x88, ...h('ec000101')])?.pact, { type: 1, code: 1 });
  assert.equal(parseAdvertisement([0x43, 0x88, 0xEC]), undefined);
  assert.equal(parseAdvertisement([0x4C, 0x00, 0x02, 0x15, 0, 0]), undefined);

  assert.equal(modelFromLocalName('Govee_H6097_1A2B'), 'H6097');
  assert.equal(modelFromLocalName('ihoment_h66a0_ABCD'), 'H66A0');
  assert.equal(modelFromLocalName('GVH5075_1234'), 'H5075');
  assert.equal(modelFromLocalName('H6099_12AB'), 'H6099');
  assert.equal(modelFromLocalName('Living Room Speaker'), undefined);

  const full = GoveeBLEProfile.resolve('H6097', { type: 2, code: 1 })!;
  assert.ok(GoveeBLEProfile.supports(full, 'dreamView') && GoveeBLEProfile.supports(full, 'videoMode') && full.limitation === undefined);
  for (const pact of [undefined, { type: 3, code: 1 }] as (Pact | undefined)[]) {
    const reduced = GoveeBLEProfile.resolve('H6097', pact)!;
    assert.deepEqual(reduced.features, ['power', 'brightness']);
    assert.notEqual(reduced.limitation, undefined);
  }
  const pro = GoveeBLEProfile.resolve('h66a0', undefined)!;
  assert.ok(GoveeBLEProfile.supports(pro, 'dreamView') && !GoveeBLEProfile.supports(pro, 'videoMode') && pro.dreamViewMemberLimit === 10);
  assert.equal(GoveeBLEProfile.resolve('H6127', undefined), undefined);
});

// MARK: Encryption selection (`test_selection_without_probe` and neighbours)

test('BLE encryption selection table matches source', () => {
  const rows: [boolean, Marker, number][] = [
    [false, absent, 0], [true, absent, 1], [false, value([1, 0]), 0], [false, value([2, 0, 0, 0, 0, 0]), 0],
    [true, value([1, 0]), 1], [true, value([2, 0, 0, 0, 0, 0]), 1], [false, value([1, 1]), 1], [true, value([1, 2]), 2],
    [false, value([2, 2, 0, 1, 2, 3]), 2], [false, value([2, 1, 0, 1, 2, 3]), 1],
  ];
  for (const [advertised, marker, version] of rows) {
    const s = new GoveeBLESession();
    s.select(marker, advertised);
    assert.equal(s.version, version);
    if (version === 0) {
      const first = s.startNegotiation(20);
      const encoded = s.encode(power(true));
      assert.ok(s.ready && first === undefined);
      assert.deepEqual(encoded, power(true));
    } else {
      assert.ok(!s.ready);
      assert.throws(() => s.encode(power(true)), failure('notReady'));
    }
  }
  const pact = new GoveeBLESession();
  pact.select(value([2, 2, 0, 1, 2, 3]), false);
  assert.deepEqual(pact.markerPact, { type: 0x0102, code: 3 });
});

test('BLE encryption evidence never falls back to plaintext', () => {
  // A zero marker keeps an earlier connection's requirement.
  for (const version of [1, 2]) {
    for (const zero of [[1, 0], [2, 0, 0, 0, 0, 0]]) {
      const s = new GoveeBLESession();
      s.select(value([1, version]), false);
      s.select(value(zero), false);
      assert.ok(s.version === version && s.requiredVersion === version && !s.ready);
    }
  }
  const unrecognised = [[], [0], [1], [2, 2], [2, 0], [3, 1], [1, 3]];
  for (const marker of unrecognised) {
    const s = new GoveeBLESession();
    assert.throws(() => s.select(value(marker), false), failure('selectionFailed'));
    // Once selection failed, a missing marker isn't treated as plaintext either.
    assert.throws(() => s.select(absent, false), failure('previousSelectionFailed'));
    // Plaintext advertisement may excuse an unreadable marker…
    const excused = new GoveeBLESession();
    excused.select(value(marker), false, true);
    assert.ok(excused.ready && excused.version === 0);
    // …but never over encryption evidence.
    const advertised = new GoveeBLESession();
    assert.throws(() => advertised.select(value(marker), true, true), failure('selectionFailed'));
    const earlier = new GoveeBLESession();
    earlier.select(value([1, 1]), false);
    assert.throws(() => earlier.select(value(marker), false, true), failure('selectionFailed'));
  }
  const failedRead = new GoveeBLESession();
  assert.throws(() => failedRead.select({ kind: 'readFailed' }, false), failure('selectionFailed'));
});

// MARK: Handshakes against independent vectors

function queue(chunks: number[][]): (n: number) => number[] {
  return (n) => {
    const c = chunks.shift();
    assert.ok(c && c.length === n);
    return c;
  };
}

test('BLE V1 transform and handshake', () => {
  const key = range(0, 16);
  assert.deepEqual(v1(f('330101'), key, true), h('71a5d00cbe4136cf6d8a60dec77d07d8e99c40ca'));
  const odd = range(0, 23);
  assert.deepEqual(v1(odd, key, true), h('0a940bb5416ef045f1c39458c653ea5af98d52ea53f70f'));
  assert.deepEqual(v1(h('0a940bb5416ef045f1c39458c653ea5af98d52ea53f70f'), key, false), odd);

  const s = new GoveeBLESession();
  s.random = queue([range(0x20, 0x31), new Array<number>(17).fill(7)]);
  s.select(value([1, 1]), false);
  assert.deepEqual(s.startNegotiation(20), h('a3774dcd1ecce7f1765b45e310b7938e46c17089'));
  const phase2 = s.receive(h('4d59159c56527d09941c0344c948c99166e140b9'));
  assert.ok(phase2.kind === 'write');
  assert.equal(parseV1Handshake(phase2.frame)?.opcode, 2);
  assert.deepEqual(s.receive(h('4d59159c56527d09941c0344c948c99166e140b9')), { kind: 'ignored' });   // duplicate key reply
  assert.deepEqual(s.receive(h('42a3f946a5b02ec277402b74ca634efe66e140ba')), { kind: 'ready' });
  assert.ok(s.encrypted);
  assert.deepEqual(s.encode(power(true)), h('71a5d00cbe4136cf6d8a60dec77d07d8e99c40ca'));
  assert.deepEqual(s.receive(v1(f('aa0101'), key, true)), { kind: 'packet', packet: f('aa0101') });
  assert.deepEqual(s.receive(new Array<number>(20).fill(0x55)), { kind: 'ignored' });
});

test('BLE V2 handshake, seal and replay', () => {
  const iv = range(0, 8), nonce = range(0, 12);
  const small = new GoveeBLESession();
  small.select(value([1, 2]), false);
  assert.throws(() => small.startNegotiation(49), failure('v2NeedsLargerWrites'));

  const s = new GoveeBLESession();
  s.random = queue([iv, nonce]);
  s.select(value([1, 2]), false);
  assert.deepEqual(s.startNegotiation(182), h('e71101000102030405060708090a0b10565850822a740b5ad5601139e0e749919dd22435e3d3643e'));
  assert.deepEqual(s.receive(h('e71100000102030405060708090a0b161810c26a344b1a8cdf4c31936cc20b4a34ae46de183aa540ff1ea4205daeac827c80')), { kind: 'ready' });
  assert.equal(s.deviceSKU, 'H6097');
  assert.deepEqual(s.deviceMAC, h('112233445566'));
  assert.deepEqual(s.encode(power(true)), h('000000022703aecf1ecadcfdbfb6ccf9bcbeb3c9fc8b197427a1fac650fa64ae36cb1944f36a8afb'));
  const reply = h('000000056146a75887c99b728e89ba890486e4f39373393fa62e1af5d93d75b37b5b0e157988052e');
  assert.deepEqual(s.receive(reply), { kind: 'packet', packet: f('aa0101') });
  assert.deepEqual(s.receive(reply), { kind: 'ignored' });
  assert.equal(s.rejectedFrames, 1);
});

test('BLE bad handshake fails closed', () => {
  const s = new GoveeBLESession();
  s.select(absent, true);
  s.startNegotiation(20);
  assert.throws(() => s.receive(f('aa0101')), failure('handshakeRejected'));
  assert.ok(!s.ready && s.requiredVersion === 1);
  assert.throws(() => s.encode(power(true)), failure('notReady'));
});

// MARK: Capture decoding

const sourceMembers: Member[] = [
  { isRGBIC: true, cmdVer: 9, identity: { kind: 'mac', mac: [0x11, 0x22, 0x33, 0x44, 0x55, 0x66] }, areas: [0, 1, 10, 255] },
  { isRGBIC: false, cmdVer: 12, identity: { kind: 'name', name: 'lamp' }, areas: [2] },
];

/** `transport.py fragment_a3` (terminator false), test-only: Luma never sends a group. */
function a3(type: number, body: number[]): number[][] {
  const data = [type, ...body];
  const count = Math.floor((data.length + 2 + 16) / 17);
  const trailing = count === 1;
  const payload = [1, count + (trailing ? 1 : 0), ...data];
  const chunks: number[][] = [];
  for (let i = 0; i < payload.length; i += 17) chunks.push(payload.slice(i, i + 17));
  const frames = chunks.map((c, i) => frame([0xA3, trailing || i !== chunks.length - 1 ? i : 0xFF, ...c]));
  if (trailing) frames.push(frame([0xA3, 0xFF]));
  return frames;
}

const hexOf = (b: number[], upper = false, sep = '') => b.map((x) => x.toString(16).padStart(2, '0')).map((x) => (upper ? x.toUpperCase() : x)).join(sep);

test('BLE group records match source vector', () => {
  const body = encodeGroup(sourceMembers);
  assert.deepEqual(body, h('020100096655443322110400010aff00010c046c616d700102'));
  assert.deepEqual(parseGroup([...body, 0, 0, 0]), sourceMembers);
  assert.deepEqual(parseGroup(h('0101010902c3a9010100'))?.[0]?.identity, { kind: 'name', name: 'é' });
  assert.equal(parseGroup([...body, 1]), undefined);
  assert.equal(parseGroup(body.slice(0, -1)), undefined);
  const envelope = reassembleA3(a3(0x50, body));
  assert.ok(envelope);
  assert.deepEqual(envelope.slice(2, 3 + body.length), [0x50, ...body]);
});

test('BLE plaintext capture yields the group and cmd_ver', () => {
  const text = ['# Govee Home saving a DreamView group', 'N ' + hexOf(f('aa0101')),
    ...a3(0x50, encodeGroup(sourceMembers)).map((fr) => 'W ' + hexOf(fr, true, ':')),
    'N ' + hexOf(f('aa600101'), false, ' ')].join('\n');
  const report = decodeCapture(text);
  assert.equal(report.encryption, 0);
  assert.deepEqual(report.groupUploads, [sourceMembers]);
  assert.deepEqual(report.dreamViewReadings, [{ kind: 'enabled', on: true }]);
  const summary = captureSummary(report);
  assert.ok(summary.includes('cmd_ver 9') && summary.includes('cmd_ver 12'));
  assert.ok(!summary.includes('66') && !summary.includes('lamp'));
});

test('BLE encrypted V2 capture decodes passively', () => {
  const clientIV = range(0, 8);
  const req = h('e71101000102030405060708090a0b10565850822a740b5ad5601139e0e749919dd22435e3d3643e');
  const resp = h('e71100000102030405060708090a0b161810c26a344b1a8cdf4c31936cc20b4a34ae46de183aa540ff1ea4205daeac827c80');
  const id = parseV2Response(resp);
  assert.ok(id);
  let counter = 2;
  const writes = a3(0x50, encodeGroup(sourceMembers)).map((fr) => seal(fr, clientIV, id.key, counter++));
  const notify = seal(f('aa600a0101'), id.deviceIV, id.key, 3);
  const line = (d: string, b: number[]) => d + ' ' + hexOf(b);
  const text = [line('W', req), line('N', resp), ...writes.map((w) => line('W', w)), line('N', notify), line('N', notify), 'W zz', 'N １２'].join('\n');
  const report = decodeCapture(text);
  assert.ok(report.encryption === 2 && report.deviceSKU === 'H6097');
  assert.deepEqual(report.groupUploads.at(-1), sourceMembers);
  assert.deepEqual(report.dreamViewReadings, [{ kind: 'videoSettings', applyArea: 1, contentMode: 1 }]);
  assert.equal(report.undecodable, 3);   // the replayed notification and two malformed lines (one fullwidth digits)
});

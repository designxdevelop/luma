// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { GoveeLan, isUnicastIPv4, lanControlPacket, lanEnvelope, parseLanPacket, type LanPacket, type UdpSocketLike } from '../core/lan';
import { brightness, kelvin, power, rgb } from '../core/model';

const buf = (value: unknown) => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value));
const json = (packet: Buffer) => JSON.parse(packet.toString('utf8'));
const scan = (data: Record<string, unknown>) => buf({ msg: { cmd: 'scan', data } });
const status = (data: Record<string, unknown>) => buf({ msg: { cmd: 'devStatus', data } });
const goodStatus = { onOff: 1, brightness: 50, color: { r: 17, g: 34, b: 51 }, colorTemInKelvin: 0 };

class FakeSocket implements UdpSocketLike {
  sent: Array<{ json: unknown; port: number; address: string }> = [];
  boundPort?: number;
  groups: string[] = [];
  ttl?: number;
  closed = false;
  bindError?: Error;
  sendError?: Error;
  private onMessage?: (msg: Buffer, rinfo: { address: string; family: string }) => void;
  private onError?: (err: Error) => void;
  bind(port: number, cb: () => void): void {
    if (this.bindError) { const err = this.bindError; queueMicrotask(() => this.onError?.(err)); return; }
    this.boundPort = port; queueMicrotask(cb);
  }
  on(event: 'message' | 'error', cb: never): void {
    if (event === 'message') this.onMessage = cb; else this.onError = cb;
  }
  addMembership(group: string): void { this.groups.push(group); }
  setMulticastTTL(ttl: number): void { this.ttl = ttl; }
  send(msg: Buffer, port: number, address: string, cb?: (err: Error | null) => void): void {
    this.sent.push({ json: json(msg), port, address });
    cb?.(this.sendError ?? null);
  }
  close(): void { this.closed = true; }
  inject(msg: Buffer, address: string, family = 'IPv4'): void { this.onMessage?.(msg, { address, family }); }
}

function setup() {
  const socket = new FakeSocket();
  const packets: LanPacket[] = [];
  const errors: string[] = [];
  const lan = new GoveeLan({ onPacket: (p) => packets.push(p), onError: (m) => errors.push(m) }, () => socket);
  return { socket, lan, packets, errors };
}

test('discovery parses identity and invents no state', () => {
  const packet = parseLanPacket(scan({ ip: '192.168.1.20', device: 'AA:BB:CC:DD', sku: 'H6008', bleVersionHard: '3' }), '192.168.1.20');
  assert.deepEqual(packet, { kind: 'discovery', id: 'AA:BB:CC:DD', sku: 'H6008', ip: '192.168.1.20' });
});

test('discovery is rejected on source mismatch, bad identity, non-unicast source', () => {
  const good = { ip: '192.168.1.20', device: 'AA', sku: 'H6008' };
  assert.throws(() => parseLanPacket(scan(good), '192.168.1.21'));
  assert.throws(() => parseLanPacket(scan({ ...good, device: '' }), '192.168.1.20'));
  assert.throws(() => parseLanPacket(scan({ ...good, device: 'x'.repeat(129) }), '192.168.1.20'));
  assert.throws(() => parseLanPacket(scan({ ...good, sku: '' }), '192.168.1.20'));
  assert.throws(() => parseLanPacket(scan({ ...good, sku: 'x'.repeat(33) }), '192.168.1.20'));
  assert.throws(() => parseLanPacket(scan({ ...good, ip: undefined }), '192.168.1.20'));
  assert.throws(() => parseLanPacket(scan({ ...good, ip: '239.255.255.250' }), '239.255.255.250'));
  assert.doesNotThrow(() => parseLanPacket(scan({ ...good, device: 'x'.repeat(128), sku: 'y'.repeat(32) }), '192.168.1.20'));
});

test('status parses power, brightness, rgb and kelvin', () => {
  assert.deepEqual(parseLanPacket(status(goodStatus), '10.0.0.5'), {
    kind: 'status', ip: '10.0.0.5', status: { power: true, brightness: 50, rgb: 0x112233, kelvin: 0 },
  });
  const white = parseLanPacket(status({ ...goodStatus, onOff: 0, colorTemInKelvin: 2700 }), '10.0.0.5');
  assert.deepEqual(white, { kind: 'status', ip: '10.0.0.5', status: { power: false, brightness: 50, rgb: 0x112233, kelvin: 2700 } });
});

test('malformed, out-of-range and oversized packets are rejected', () => {
  const bad = (data: Record<string, unknown>) => assert.throws(() => parseLanPacket(status(data), '10.0.0.5'), /Invalid LAN datagram/);
  bad({ ...goodStatus, onOff: 2 });
  bad({ ...goodStatus, brightness: 101 });
  bad({ ...goodStatus, brightness: -1 });
  bad({ ...goodStatus, color: { r: 256, g: 0, b: 0 } });
  bad({ ...goodStatus, color: { r: 0, g: 0 } });
  bad({ ...goodStatus, color: undefined });
  bad({ ...goodStatus, colorTemInKelvin: 1999 });
  bad({ ...goodStatus, colorTemInKelvin: 9001 });
  bad({ ...goodStatus, brightness: 50.5 });
  bad({ ...goodStatus, brightness: '50' });
  bad({ ...goodStatus, onOff: 1e100 });
  assert.throws(() => parseLanPacket(buf('not json'), '10.0.0.5'));
  assert.throws(() => parseLanPacket(buf({ msg: { cmd: 'other', data: {} } }), '10.0.0.5'));
  assert.throws(() => parseLanPacket(buf({ msg: { cmd: 'devStatus' } }), '10.0.0.5'));
  assert.throws(() => parseLanPacket(Buffer.alloc(8193, 0x20), '10.0.0.5'));
  assert.throws(() => parseLanPacket(status(goodStatus), '127.0.0.1'));
});

test('isUnicastIPv4', () => {
  for (const ip of ['192.168.1.20', '10.0.0.1', '1.2.3.4', '223.255.255.255', '172.16.0.9']) assert.equal(isUnicastIPv4(ip), true, ip);
  // Leading zeros are rejected on purpose: they are ambiguous (octal on some stacks).
  for (const ip of ['239.255.255.250', '127.0.0.1', '0.0.0.0', '0.1.2.3', '224.0.0.1', '255.255.255.255', 'example.com', '256.1.1.1', '01.2.3.4', '1.2.3', '1.2.3.4.5', '1.2.3.', '', ' 1.2.3.4', '1.2.3.4 ', '1.2.3.-4', '1.2.3.0x4', '::1'])
    assert.equal(isUnicastIPv4(ip), false, JSON.stringify(ip));
});

test('lanEnvelope shape', () => {
  assert.deepEqual(json(lanEnvelope('devStatus', {})), { msg: { cmd: 'devStatus', data: {} } });
});

test('control packet bytes', () => {
  assert.deepEqual(json(lanControlPacket(power(true))), { msg: { cmd: 'turn', data: { value: 1 } } });
  assert.deepEqual(json(lanControlPacket(power(false))), { msg: { cmd: 'turn', data: { value: 0 } } });
  assert.deepEqual(json(lanControlPacket(brightness(100))), { msg: { cmd: 'brightness', data: { value: 100 } } });
  assert.deepEqual(json(lanControlPacket(rgb(0x112233))), { msg: { cmd: 'colorwc', data: { color: { r: 17, g: 34, b: 51 }, colorTemInKelvin: 0 } } });
  assert.deepEqual(json(lanControlPacket(kelvin(2700))), { msg: { cmd: 'colorwc', data: { color: { r: 0, g: 0, b: 0 }, colorTemInKelvin: 2700 } } });
  assert.equal(lanControlPacket(rgb(0x112233)).toString(), '{"msg":{"cmd":"colorwc","data":{"color":{"r":17,"g":34,"b":51},"colorTemInKelvin":0}}}');
  assert.deepEqual(json(lanControlPacket(rgb(0xffffff))).msg.data.color, { r: 255, g: 255, b: 255 });
});

test('control packet rejects unsupported commands and values', () => {
  const throws = (command: Parameters<typeof lanControlPacket>[0]) => assert.throws(() => lanControlPacket(command), /cloud/i);
  throws(brightness(0));
  throws(brightness(101));
  throws(brightness(0.5));
  throws(kelvin(1999));
  throws(kelvin(9001));
  throws(rgb(-1));
  throws(rgb(0x1000000));
  throws(rgb(1e100));
  throws({ ...power(true), value: 2 });
  throws({ ...brightness(50), value: NaN });
  throws({ ...brightness(50), value: '50' });
  throws({ ...brightness(50), value: null });
  throws({ ...rgb(1), type: 'devices.capabilities.on_off' });
  throws({ type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', value: 3 });
  throws({ type: 'devices.capabilities.segment_color_setting', instance: 'segmentedColorRgb', value: {} });
});

test('start binds 4002, joins the multicast group, and is idempotent', async () => {
  const { socket, lan } = setup();
  assert.equal(lan.running, false);
  await Promise.all([lan.start(), lan.start()]);
  await lan.start();
  assert.equal(lan.running, true);
  assert.equal(socket.boundPort, 4002);
  assert.deepEqual(socket.groups, ['239.255.255.250']);
  assert.equal(socket.ttl, 1);
  lan.stop();
  assert.equal(lan.running, false);
  assert.equal(socket.closed, true);
});

test('discover multicasts a scan to 239.255.255.250:4001', async () => {
  const { socket, lan } = setup();
  assert.throws(() => lan.discover(), /Start LAN/);
  await lan.start();
  lan.discover();
  assert.deepEqual(socket.sent, [{ json: { msg: { cmd: 'scan', data: { account_topic: 'reserve' } } }, port: 4001, address: '239.255.255.250' }]);
});

test('a discovery reply is reported and triggers devStatus to ip:4003', async () => {
  const { socket, lan, packets } = setup();
  await lan.start();
  socket.inject(scan({ ip: '192.168.1.20', device: 'AA:BB', sku: 'H6008' }), '192.168.1.20');
  assert.deepEqual(packets, [{ kind: 'discovery', id: 'AA:BB', sku: 'H6008', ip: '192.168.1.20' }]);
  assert.deepEqual(socket.sent, [{ json: { msg: { cmd: 'devStatus', data: {} } }, port: 4003, address: '192.168.1.20' }]);
  socket.inject(status(goodStatus), '192.168.1.20');
  assert.equal(packets[1]?.kind, 'status');
  assert.equal(socket.sent.length, 1, 'a status reply does not trigger another request');
});

test('noise datagrams are ignored', async () => {
  const { socket, lan, packets, errors } = setup();
  await lan.start();
  socket.inject(buf('M-SEARCH * HTTP/1.1\r\n\r\n'), '192.168.1.9');
  socket.inject(Buffer.from([0, 0, 0x84, 0, 0, 1]), '192.168.1.9');
  socket.inject(scan({ ip: '192.168.1.99', device: 'AA', sku: 'H6008' }), '192.168.1.20'); // spoofed source
  socket.inject(scan({ ip: '::1', device: 'AA', sku: 'H6008' }), '::1', 'IPv6');
  socket.inject(Buffer.alloc(9000, 0x7b), '192.168.1.9');
  socket.inject(status(goodStatus), '127.0.0.1');
  assert.deepEqual(packets, []);
  assert.deepEqual(errors, []);
  assert.deepEqual(socket.sent, []);
});

test('a throwing packet handler is reported, never thrown out of the socket callback', async () => {
  const socket = new FakeSocket();
  const errors: string[] = [];
  const lan = new GoveeLan({ onPacket: () => { throw new Error('boom'); }, onError: (m) => errors.push(m) }, () => socket);
  await lan.start();
  assert.doesNotThrow(() => socket.inject(status(goodStatus), '10.0.0.5'));
  assert.deepEqual(errors, ['Could not process a LAN packet.']);
});

test('requestStatus and control send to ip:4003 and validate input', async () => {
  const { socket, lan, errors } = setup();
  await lan.start();
  lan.requestStatus('192.168.1.20');
  await lan.control('192.168.1.20', rgb(0x112233));
  assert.deepEqual(socket.sent.map((s) => [s.port, s.address]), [[4003, '192.168.1.20'], [4003, '192.168.1.20']]);
  assert.deepEqual((socket.sent[1]!.json as { msg: { cmd: string } }).msg.cmd, 'colorwc');
  assert.throws(() => lan.requestStatus('239.255.255.250'), /IPv4/);
  assert.equal(socket.sent.length, 2);
  assert.deepEqual(errors, []);
});

test('control rejects (not throws) on caller mistakes, without sending or calling onError', async () => {
  const { socket, lan, errors } = setup();
  await assert.rejects(lan.control('192.168.1.20', power(true)), /Start LAN/); // not started
  await lan.start();
  let pending: Promise<void> | undefined;
  assert.doesNotThrow(() => { pending = lan.control('example.com', power(true)); });
  await assert.rejects(pending!, /no valid LAN address/);
  await assert.rejects(lan.control('192.168.1.20', { type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', value: 1 }), /cloud/i);
  assert.equal(socket.sent.length, 0);
  assert.deepEqual(errors, []);
  lan.stop();
  await assert.rejects(lan.control('192.168.1.20', power(true)), /Start LAN/); // stopped
});

test('control resolves on send success and rejects with a safe LumaError on send failure', async () => {
  const { socket, lan, errors } = setup();
  await lan.start();
  await lan.control('192.168.1.20', power(true));
  assert.equal(socket.sent.length, 1);
  socket.sendError = Object.assign(new Error('secret detail 192.168.1.20'), { code: 'EHOSTUNREACH' });
  await assert.rejects(lan.control('192.168.1.20', power(true)), (e: Error) => e.name === 'LumaError' && e.message === 'Could not send to the light over LAN: EHOSTUNREACH');
  socket.sendError = new Error('no code, secret detail');
  await assert.rejects(lan.control('192.168.1.20', power(true)), { message: 'Could not send to the light over LAN: unknown error' });
  socket.send = () => { throw new Error('sync boom'); };
  await assert.rejects(lan.control('192.168.1.20', power(true)), /Could not send to the light over LAN/);
  assert.deepEqual(errors, [], 'control failures are not double-reported to onError');
});

test('requestStatus send errors still go to onError, not out of the call', async () => {
  const { socket, lan, errors } = setup();
  await lan.start();
  socket.sendError = Object.assign(new Error('secret detail'), { code: 'EHOSTUNREACH' });
  assert.doesNotThrow(() => lan.requestStatus('192.168.1.20'));
  assert.deepEqual(errors, ['Could not send a LAN packet (EHOSTUNREACH).']);
});

test('LAN color temperature supports only 2000–9000 K; the rest must go to cloud', () => {
  for (const k of [1000, 1500, 1999, 9001, 9500, 10000]) assert.throws(() => lanControlPacket(kelvin(k)), /cloud/i, String(k));
  for (const k of [2000, 9000]) assert.doesNotThrow(() => lanControlPacket(kelvin(k)), String(k));
});

test('EADDRINUSE gives an actionable error and the class stays restartable', async () => {
  const socket = new FakeSocket();
  socket.bindError = Object.assign(new Error('bind EADDRINUSE 0.0.0.0:4002'), { code: 'EADDRINUSE' });
  const sockets = [socket, new FakeSocket()];
  const lan = new GoveeLan({ onPacket: () => {}, onError: () => {} }, () => sockets.shift()!);
  await assert.rejects(lan.start(), /4002.*already in use.*Home Assistant/);
  assert.equal(lan.running, false);
  assert.equal(socket.closed, true);
  await lan.start(); // the next attempt uses a fresh socket and succeeds
  assert.equal(lan.running, true);
});

test('a multicast membership failure rejects start and closes the socket', async () => {
  const socket = new FakeSocket();
  socket.addMembership = () => { throw Object.assign(new Error('no route'), { code: 'ENODEV' }); };
  const lan = new GoveeLan({ onPacket: () => {}, onError: () => {} }, () => socket);
  await assert.rejects(lan.start(), /Could not start LAN control \(ENODEV\)/);
  assert.equal(lan.running, false);
  assert.equal(socket.closed, true);
});

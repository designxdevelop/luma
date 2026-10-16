// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createConnection, createServer, type AddressInfo } from 'node:net';
import { BODY_LIMIT, HEADER_LIMIT, RequestParser, WebhookServer, type HttpRequest, type ParseResult } from '../core/http';

const TOKEN = 'unit-test-bearer-token';

function request(method = 'POST', opts: { path?: string; body?: Buffer; extra?: string; auth?: string | null } = {}): Buffer {
  const { path = '/v1/scenes/test/run', body = Buffer.from('{}'), extra = '', auth = `Bearer ${TOKEN}` } = opts;
  let head = `${method} ${path} HTTP/1.1\r\nHost: localhost\r\n`;
  if (auth !== null) head += `Authorization: ${auth}\r\n`;
  if (method === 'POST') head += `Content-Type: application/json\r\nContent-Length: ${body.length}\r\n`;
  head += `${extra}\r\n`;
  return method === 'POST' ? Buffer.concat([Buffer.from(head), body]) : Buffer.from(head);
}

const parse = (bytes: Buffer): ParseResult => new RequestParser(TOKEN).append(bytes);
const status = (bytes: Buffer): number | undefined => {
  const r = parse(bytes);
  return r.kind === 'failure' ? r.response.status : undefined;
};

test('every split of a UTF-8 POST yields incomplete then the exact body', () => {
  const body = Buffer.from('{"name":"Café 💡"}');
  const data = request('POST', { body });
  for (let split = 1; split < data.length; split++) {
    const parser = new RequestParser(TOKEN);
    assert.equal(parser.append(data.subarray(0, split)).kind, 'incomplete', `split ${split}`);
    const result = parser.append(data.subarray(split));
    assert.equal(result.kind, 'request', `split ${split}`);
    if (result.kind === 'request') {
      assert.equal(result.request.method, 'POST');
      assert.equal(result.request.path, '/v1/scenes/test/run');
      assert.deepEqual(result.request.body, body);
    }
  }
});

test('auth failures are decided at header completion, before the body', () => {
  for (const auth of [null, 'Bearer wrong', `Bearer ${TOKEN}-more`, `Bearer ${TOKEN.slice(1)}`, `Basic ${TOKEN}`]) {
    const bytes = request('POST', { body: Buffer.alloc(500, 32), auth });
    const headersOnly = bytes.subarray(0, bytes.indexOf('\r\n\r\n') + 4);
    const r = new RequestParser(TOKEN).append(headersOnly);
    assert.equal(r.kind === 'failure' ? r.response.status : r.kind, 401, String(auth));
  }
  assert.equal(status(request('GET', { path: '/health', auth: null })), 401);
  assert.equal(status(request('GET', { path: '/health' })) , undefined);
  assert.equal(parse(request('GET', { path: '/health' })).kind, 'request');
  const r = new RequestParser('').append(request('GET', { path: '/health', auth: 'Bearer ' }));
  assert.equal(r.kind === 'failure' ? r.response.status : r.kind, 401, 'empty token never authenticates');
});

test('query strings and unsafe paths are rejected', () => {
  for (const path of [`/health?token=${TOKEN}`, '/health#x', '//evil', 'health', '/a\\b', '/a%20b?']) {
    assert.equal(status(request('GET', { path })), 400, path);
  }
});

test('malformed Content-Length values', () => {
  for (const value of ['-1', '+2', '2,2', '2 2', '1x', '']) {
    const bytes = Buffer.from(`POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\nContent-Length: ${value}\r\n\r\n{}`);
    assert.equal(status(bytes), 400, JSON.stringify(value));
  }
  const huge = Buffer.from(`POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\nContent-Length: 999999999999999999999999999999\r\n\r\n{}`);
  assert.equal(status(huge), 413);
});

test('smuggling and unsupported framing', () => {
  assert.equal(status(request('POST', { extra: 'content-length: 2\r\n' })), 400);
  assert.equal(status(request('POST', { extra: `Authorization: Bearer ${TOKEN}\r\n` })), 400);
  assert.equal(status(request('POST', { extra: 'Transfer-Encoding: chunked\r\n' })), 400);
  assert.equal(status(request('POST', { extra: 'Expect: 100-continue\r\n' })), 400);
  assert.equal(status(request('POST', { extra: 'Upgrade: websocket\r\n' })), 400);
  assert.equal(status(request('POST', { extra: ' Host: injected\r\n' })), 400);
  assert.equal(status(request('POST', { extra: 'Host: second\r\n' })), 400);
  assert.equal(status(request('OPTIONS')), 405);
  assert.equal(status(request('DELETE')), 405);
  assert.equal(status(Buffer.concat([request(), request('GET')])), 400);
  assert.equal(status(Buffer.from(`GET / HTTP/1.1\r\nAuthorization: Bearer ${TOKEN}\r\n\r\n`)), 400, 'Host required');
  assert.equal(status(Buffer.from(`GET / HTTP/1.0\r\nHost: x\r\nAuthorization: Bearer ${TOKEN}\r\n\r\n`)), 400);
  assert.equal(status(request('GET', { extra: 'Content-Length: 2\r\n' }) ), 400, 'GET with a body');
});

test('POST content negotiation and body encoding', () => {
  const textPlain = Buffer.from(`POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}`);
  assert.equal(status(textPlain), 415);
  const latin = Buffer.from(`POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json; charset=latin1\r\nContent-Length: 2\r\n\r\n{}`);
  assert.equal(status(latin), 415);
  const utf = Buffer.from(`POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json; charset=UTF-8\r\nContent-Length: 2\r\n\r\n{}`);
  assert.equal(parse(utf).kind, 'request');
  const noLength = Buffer.from(`POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\n\r\n`);
  assert.equal(status(noLength), 411);
  assert.equal(status(request('POST', { body: Buffer.from([0xff, 0xfe, 0x7b]) })), 400);
});

test('header and body limits', () => {
  const partial = Buffer.concat([Buffer.from('GET / HTTP/1.1\r\nX-Padding: '), Buffer.alloc(HEADER_LIMIT, 65)]);
  assert.equal(status(partial), 431, 'overflow before CRLFCRLF arrives');
  const parser = new RequestParser(TOKEN);
  assert.equal(parser.append(Buffer.from('GET / HTTP/1.1\r\nX-Padding: ')).kind, 'incomplete');
  const r = parser.append(Buffer.alloc(HEADER_LIMIT, 65));
  assert.equal(r.kind === 'failure' ? r.response.status : r.kind, 431);
  const bigHeaders = Buffer.from(`GET / HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${TOKEN}\r\nX-Padding: ${'A'.repeat(HEADER_LIMIT)}\r\n\r\n`);
  assert.equal(status(bigHeaders), 431);
  assert.equal(status(Buffer.from(request('POST', { body: Buffer.alloc(0) }).toString().replace('Content-Length: 0', `Content-Length: ${BODY_LIMIT + 1}`))), 413);
  const exact = request('POST', { body: Buffer.alloc(BODY_LIMIT, 0x20) });
  const ok = parse(exact);
  assert.equal(ok.kind, 'request');
  if (ok.kind === 'request') assert.equal(ok.request.body.length, BODY_LIMIT);
});

// ---- real loopback server -------------------------------------------------------------

function raw(port: number, bytes: Buffer): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: '127.0.0.1', port });
    const chunks: Buffer[] = [];
    socket.on('data', (c) => chunks.push(c));
    socket.on('error', reject);
    socket.on('close', () => resolve(Buffer.concat(chunks).toString()));
    socket.write(bytes);
  });
}

test('loopback server: auth, handler, headers, binding, restart', async () => {
  const server = new WebhookServer();
  const seen: HttpRequest[] = [];
  const handler = async (req: HttpRequest) => { seen.push(req); return { status: 202, body: { got: req.body.toString() } }; };
  assert.equal(server.running, false);
  await assert.rejects(server.start({ port: 0, allowLAN: false, token: 'short', handler }), /at least 16/);
  await assert.rejects(server.start({ port: 0, allowLAN: false, token: 'has space in token!!', handler }), /visible ASCII/);
  const { port, host } = await server.start({ port: 0, allowLAN: false, token: TOKEN, handler });
  try {
    assert.equal(host, '127.0.0.1');
    assert.equal(server.running, true);
    assert.equal(server.port, port);
    assert.ok(port > 0);

    const good = await fetch(`http://127.0.0.1:${port}/v1/actions`, {
      method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' }, body: '{"a":1}',
    });
    assert.equal(good.status, 202);
    assert.deepEqual(await good.json(), { got: '{"a":1}' });
    assert.equal(good.headers.get('access-control-allow-origin'), null);
    assert.equal(good.headers.get('cache-control'), 'no-store');
    assert.equal(good.headers.get('x-content-type-options'), 'nosniff');
    assert.match(good.headers.get('content-type') ?? '', /^application\/json; charset=utf-8$/);
    assert.equal(seen.length, 1);

    const before = seen.length;
    const denied = await fetch(`http://127.0.0.1:${port}/health`);
    assert.equal(denied.status, 401);
    assert.equal(denied.headers.get('access-control-allow-origin'), null);
    const preflight = await raw(port, Buffer.from('OPTIONS / HTTP/1.1\r\nHost: x\r\nOrigin: http://evil.example\r\n\r\n'));
    assert.match(preflight, /^HTTP\/1\.1 401 /);
    assert.doesNotMatch(preflight, /access-control/i);
    assert.equal(seen.length, before, 'unauthorized requests never reach the handler');

    const reply = await raw(port, request('GET', { path: '/health' }));
    assert.match(reply, /^HTTP\/1\.1 202 Accepted\r\n/);

    // Restart on a new ephemeral port stops the previous listener.
    const second = await server.start({ port: 0, allowLAN: false, token: TOKEN, handler });
    await assert.rejects(raw(port, request('GET', { path: '/health' })), /ECONNREFUSED/);
    assert.equal(server.port, second.port);
  } finally {
    await server.stop();
  }
  assert.equal(server.running, false);
  await assert.rejects(raw(port, request('GET')), /ECONNREFUSED/);
});

test('loopback server: binds 127.0.0.1 only, handler errors are generic 500s', async () => {
  const server = new WebhookServer();
  const { port } = await server.start({ port: 0, allowLAN: false, token: TOKEN, handler: async () => { throw new Error('secret stack detail'); } });
  try {
    // The loopback connection must come from/to 127.0.0.1 (start() also reports host '127.0.0.1').
    const probe = createConnection({ host: '127.0.0.1', port });
    await new Promise<void>((resolve, reject) => { probe.once('connect', resolve); probe.once('error', reject); });
    assert.equal(probe.remoteAddress, '127.0.0.1');
    probe.destroy();
    const reply = await raw(port, request('GET', { path: '/health' }));
    assert.match(reply, /^HTTP\/1\.1 500 /);
    assert.doesNotMatch(reply, /secret stack detail/);
  } finally {
    await server.stop();
  }
});

test('loopback server: EADDRINUSE gives an actionable message', async () => {
  const blocker = createServer();
  await new Promise<void>((resolve) => blocker.listen(0, '127.0.0.1', resolve));
  const taken = (blocker.address() as AddressInfo).port;
  const server = new WebhookServer();
  try {
    await assert.rejects(
      server.start({ port: taken, allowLAN: false, token: TOKEN, handler: async () => ({ status: 200, body: null }) }),
      (error: Error) => error.message.startsWith(`Port ${taken} is in use`),
    );
    assert.equal(server.running, false);
  } finally {
    await server.stop();
    await new Promise<void>((resolve) => blocker.close(() => resolve()));
  }
});

test('loopback server: early-auth rejection while a body is still streaming', async () => {
  const server = new WebhookServer();
  const { port } = await server.start({ port: 0, allowLAN: false, token: TOKEN, handler: async () => ({ status: 200, body: null }) });
  try {
    const reply = await raw(port, request('POST', { body: Buffer.alloc(BODY_LIMIT, 32), auth: 'Bearer nope' }));
    assert.match(reply, /^HTTP\/1\.1 401 /);
  } finally {
    await server.stop();
  }
});

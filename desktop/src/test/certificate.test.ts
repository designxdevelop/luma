import test from 'node:test';
import assert from 'node:assert/strict';
import { X509Certificate, createPrivateKey } from 'node:crypto';
import { request } from 'node:https';
import { createConnection } from 'node:net';
import { generateWebhookIdentity, loadWebhookIdentity } from '../core/certificate';
import { WebhookServer } from '../core/http';
import type { SecretStore } from '../main/storage';

test('certificate has a valid P-256 signature, local SANs, server purpose and fingerprint', () => {
  const now = new Date('2049-12-31T12:00:00Z');
  const identity = generateWebhookIdentity(now); const cert = new X509Certificate(identity.cert);
  assert.equal(cert.subject, 'CN=Luma local webhooks');
  assert.equal(cert.checkHost('localhost'), 'localhost');
  assert.equal(cert.checkIP('127.0.0.1'), '127.0.0.1');
  assert.ok(cert.checkIP('::1')); assert.equal(cert.ca, false);
  assert.ok(cert.keyUsage?.includes('1.3.6.1.5.5.7.3.1'));
  assert.ok(cert.verify(cert.publicKey)); assert.ok(cert.checkPrivateKey(createPrivateKey(identity.key)));
  assert.equal(Date.parse(cert.validFrom), now.getTime() - 3600000);
  assert.equal(Date.parse(cert.validTo), now.getTime() + 824 * 86400000);
  assert.match(identity.fingerprint, /^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/);
  assert.equal(identity.fingerprint, cert.fingerprint256);
});

test('identity is reused until seven days before expiry; demo never accesses storage', () => {
  let value: string | undefined; let writes = 0;
  const store: SecretStore = { available: true, read: () => value, write: (_name, v) => { value = v; writes++; }, delete: () => {} };
  const now = new Date('2026-01-01T00:00:00Z'); const first = loadWebhookIdentity(store, false, now);
  assert.equal(loadWebhookIdentity(store, false, new Date(now.getTime() + 816 * 86400000)).cert, first.cert);
  assert.notEqual(loadWebhookIdentity(store, false, new Date(now.getTime() + 817 * 86400000)).cert, first.cert);
  assert.equal(writes, 2);
  assert.notEqual(loadWebhookIdentity(undefined, true, now).cert, first.cert);
  assert.throws(() => loadWebhookIdentity(undefined), /Secure storage/);
});

test('HTTPS trusts only the generated CA and rejects plaintext HTTP', async () => {
  const identity = generateWebhookIdentity(); const server = new WebhookServer();
  const { port } = await server.start({ port: 0, allowLAN: false, token: 'long-enough-token-123', tls: identity, handler: async () => ({ status: 200, body: { ok: true } }) });
  try {
    const status = await new Promise<number>((resolve, reject) => {
      const req = request({ host: '127.0.0.1', port, path: '/', ca: identity.cert, headers: { Authorization: 'Bearer long-enough-token-123' } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode!)); }); req.on('error', reject); req.end();
    });
    assert.equal(status, 200);
    const result = await new Promise<string>(resolve => { const socket = createConnection(port, '127.0.0.1'); let data = ''; socket.on('data', chunk => data += chunk.toString()); socket.on('error', () => resolve(data)); socket.on('close', () => resolve(data)); socket.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'); });
    assert.doesNotMatch(result, /^HTTP\/1\.1/);
  } finally { await server.stop(); }
});

test('silent clients that never finish the TLS handshake are closed and free their slots', async () => {
  const identity = generateWebhookIdentity();
  const server = new WebhookServer();
  const { port } = await server.start({ port: 0, allowLAN: false, token: 'long-enough-token-123', tls: identity, deadlineMs: 200, handler: async () => ({ status: 200, body: { ok: true } }) });
  try {
    const sockets = Array.from({ length: 16 }, () => createConnection({ host: '127.0.0.1', port }));
    const closed = await Promise.all(sockets.map((socket) => new Promise<boolean>((resolve) => {
      socket.on('error', () => undefined);
      socket.on('close', () => resolve(true));
      setTimeout(() => resolve(false), 3_000);
    })));
    assert.ok(closed.every(Boolean), 'every idle pre-handshake connection was closed');
  } finally { await server.stop(); }
});

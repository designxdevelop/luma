import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Bridge, ENDPOINT_ID } from '../src/bridge.mjs';
import { handler } from '../lambda/index.mjs';

const REDIRECT = 'https://pitangui.amazon.com/api/skill/link/M2AAAAAAAAAAAA';
const env = { HUB_TOKEN: 'h'.repeat(43), ALEXA_CLIENT_ID: 'luma-alexa', ALEXA_CLIENT_SECRET: 'client-secret-value', ALEXA_REDIRECT_URIS: `${REDIRECT}, https://layla.amazon.com/api/skill/link/M2AAAAAAAAAAAA`, LAMBDA_SECRET: 'lambda-secret-value' };

class MemoryStorage {
  map = new Map();
  async get(k) { return structuredClone(this.map.get(k)); }
  async put(k, v) { this.map.set(k, structuredClone(v)); }
  async delete(k) { this.map.delete(k); }
  async list({ prefix }) { return new Map([...this.map].filter(([k]) => k.startsWith(prefix))); }
}

function setup() {
  const clock = { t: 1_800_000_000_000 };
  const bridge = new Bridge({ env, storage: new MemoryStorage(), now: () => clock.t });
  const call = (path, { method = 'POST', body, headers = {} } = {}) => bridge.fetch(new Request(`https://relay.example${path}`, { method, body, headers }));
  const hub = (path, body = '{}', token = env.HUB_TOKEN) => call(path, { body, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' } });
  const form = (path, fields, headers = {}) => call(path, { body: new URLSearchParams(fields).toString(), headers: { 'content-type': 'application/x-www-form-urlencoded', ...headers } });
  const alexa = async (directive, secret = env.LAMBDA_SECRET) => (await call('/alexa', { body: JSON.stringify({ directive }), headers: { 'x-luma-relay-secret': secret } })).json();
  const linkParams = { response_type: 'code', client_id: env.ALEXA_CLIENT_ID, redirect_uri: REDIRECT, state: 'alexa-state-123' };
  async function link() {
    const { code } = await (await hub('/hub/pairing-code')).json();
    const redirect = await form('/oauth/authorize', { ...linkParams, pairing_code: code.toLowerCase() });
    assert.equal(redirect.status, 302);
    const location = new URL(redirect.headers.get('location'));
    assert.equal(location.origin + location.pathname, REDIRECT);
    assert.equal(location.searchParams.get('state'), 'alexa-state-123');
    const basic = `Basic ${btoa(`${env.ALEXA_CLIENT_ID}:${env.ALEXA_CLIENT_SECRET}`)}`;
    const tokens = await (await form('/oauth/token', { grant_type: 'authorization_code', code: location.searchParams.get('code'), redirect_uri: REDIRECT }, { authorization: basic })).json();
    assert.equal(tokens.token_type, 'Bearer');
    return { ...tokens, code: location.searchParams.get('code'), basic };
  }
  const activate = (token, name = 'Activate', messageId = 'msg-1') => alexa({
    header: { namespace: 'Alexa.SceneController', name, payloadVersion: '3', messageId, correlationToken: 'corr-1' },
    endpoint: { scope: { type: 'BearerToken', token }, endpointId: ENDPOINT_ID, cookie: {} }, payload: {},
  });
  return { clock, bridge, call, hub, form, alexa, link, activate, linkParams };
}

test('pairing, account linking, discovery, and a routine Activate reach a waiting Luma long poll', async () => {
  const s = setup();
  const tokens = await s.link();
  const discovery = await s.alexa({ header: { namespace: 'Alexa.Discovery', name: 'Discover', payloadVersion: '3', messageId: 'd1' }, payload: { scope: { type: 'BearerToken', token: tokens.access_token } } });
  assert.equal(discovery.event.header.name, 'Discover.Response');
  const [endpoint] = discovery.event.payload.endpoints;
  assert.deepEqual(endpoint.displayCategories, ['SCENE_TRIGGER']);
  assert.ok(endpoint.manufacturerName && endpoint.description && endpoint.friendlyName.length <= 128);
  assert.deepEqual(endpoint.capabilities.map((c) => c.interface), ['Alexa.SceneController', 'Alexa']);

  const poll = s.hub('/hub/next', '{"wait":true}');
  await new Promise((r) => setImmediate(r));
  const started = await s.activate(tokens.access_token);
  assert.equal(started.event.header.name, 'ActivationStarted');
  assert.equal(started.event.header.correlationToken, 'corr-1');
  assert.equal(started.event.endpoint.endpointId, ENDPOINT_ID);
  assert.deepEqual(started.context, {});
  assert.match(started.event.payload.timestamp, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  const delivered = await (await poll).json();
  assert.deepEqual(delivered.events, [{ id: 'msg-1', type: 'activate', issuedAt: s.clock.t / 1000 }]);

  const accept = await s.alexa({ header: { namespace: 'Alexa.Authorization', name: 'AcceptGrant', payloadVersion: '3', messageId: 'a1' }, payload: { grant: { type: 'OAuth2.AuthorizationCode', code: 'x' }, grantee: { type: 'BearerToken', token: tokens.access_token } } });
  assert.equal(accept.event.header.name, 'AcceptGrant.Response');
});

test('the Lambda forwarder relays the directive with its secret and turns failures into an Alexa error', async () => {
  const seen = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => { seen.push({ url: String(url), init }); return new Response('{"event":{"header":{"name":"ok"}}}', { status: 200 }); };
  process.env.RELAY_URL = 'https://relay.example'; process.env.LAMBDA_SECRET = 'lambda-secret-value';
  try {
    assert.deepEqual(await handler({ directive: { header: { name: 'Discover' } } }), { event: { header: { name: 'ok' } } });
    assert.equal(seen[0].url, 'https://relay.example/alexa');
    assert.equal(seen[0].init.headers['x-luma-relay-secret'], 'lambda-secret-value');
    globalThis.fetch = async () => new Response('', { status: 502 });
    const failed = await handler({ directive: { header: { correlationToken: 'c' }, endpoint: { endpointId: ENDPOINT_ID } } });
    assert.equal(failed.event.header.name, 'ErrorResponse');
    assert.equal(failed.event.header.correlationToken, 'c');
    assert.equal(failed.event.payload.message, 'The Luma relay could not be reached.'); // never the raw error text
  } finally { globalThis.fetch = realFetch; }
});

test('relay rejects forged callers, wrong redirects, reused codes, and guessed pairing codes', async () => {
  const s = setup();
  assert.equal((await s.call('/alexa', { body: '{}', headers: { 'x-luma-relay-secret': 'nope' } })).status, 401);
  assert.equal((await s.hub('/hub/next', '{"wait":false}', 'x'.repeat(43))).status, 401);
  const evil = await s.call(`/oauth/authorize?${new URLSearchParams({ ...s.linkParams, redirect_uri: 'https://evil.example/cb' })}`, { method: 'GET' });
  assert.equal(evil.status, 400);
  assert.equal(evil.headers.get('location'), null);

  // Five wrong guesses burn the code.
  const { code } = await (await s.hub('/hub/pairing-code')).json();
  for (let i = 0; i < 5; i++) assert.equal((await s.form('/oauth/authorize', { ...s.linkParams, pairing_code: 'AAAAAAAA' })).status, 400);
  assert.equal((await s.form('/oauth/authorize', { ...s.linkParams, pairing_code: code })).status, 400);

  const tokens = await s.link();
  const reuse = await s.form('/oauth/token', { grant_type: 'authorization_code', code: tokens.code, redirect_uri: REDIRECT }, { authorization: tokens.basic });
  assert.equal(reuse.status, 400);
  const badClient = await s.form('/oauth/token', { grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: env.ALEXA_CLIENT_ID, client_secret: 'wrong' });
  assert.equal(badClient.status, 401);
  assert.equal((await s.activate('forged-token')).event.payload.type, 'INVALID_AUTHORIZATION_CREDENTIAL');
});

test('offline hub, expiry, stale events, refresh rotation, and unlink', async () => {
  const s = setup();
  const tokens = await s.link();
  assert.equal((await s.activate(tokens.access_token)).event.payload.type, 'ENDPOINT_UNREACHABLE');

  assert.equal((await s.hub('/hub/next', '{"wait":false}')).status, 204);
  await s.activate(tokens.access_token, 'Activate', 'old');
  s.clock.t += 31_000; // queued longer than 30 s: never delivered late
  assert.equal((await s.hub('/hub/next', '{"wait":false}')).status, 204);
  await s.activate(tokens.access_token, 'Deactivate', 'stop-1');
  assert.deepEqual((await (await s.hub('/hub/next', '{"wait":false}')).json()).events.map((e) => e.type), ['deactivate']);

  s.clock.t += 3_600_000;
  assert.equal((await s.activate(tokens.access_token)).event.payload.type, 'EXPIRED_AUTHORIZATION_CREDENTIAL');
  const refreshed = await (await s.form('/oauth/token', { grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: env.ALEXA_CLIENT_ID, client_secret: env.ALEXA_CLIENT_SECRET })).json();
  assert.ok(refreshed.access_token);
  const again = await s.form('/oauth/token', { grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: env.ALEXA_CLIENT_ID, client_secret: env.ALEXA_CLIENT_SECRET });
  assert.equal(again.status, 400); // rotated

  assert.equal((await s.hub('/hub/unlink')).status, 204);
  assert.equal((await s.activate(refreshed.access_token)).event.payload.type, 'INVALID_AUTHORIZATION_CREDENTIAL');
});

test('expired access tokens and unexchanged-then-expired codes are deleted when read', async () => {
  const s = setup();
  const tokens = await s.link();
  const keys = (prefix) => [...s.bridge.storage.map.keys()].filter((k) => k.startsWith(prefix));
  assert.equal(keys('access:').length, 1);
  s.clock.t += 3_600_001;
  assert.equal((await s.activate(tokens.access_token)).event.payload.type, 'EXPIRED_AUTHORIZATION_CREDENTIAL');
  assert.equal(keys('access:').length, 0);

  // A code that outlives its TTL is removed when presented, and cannot be used.
  const { code } = await (await s.hub('/hub/pairing-code')).json();
  const redirect = await s.form('/oauth/authorize', { ...s.linkParams, pairing_code: code });
  const stale = new URL(redirect.headers.get('location')).searchParams.get('code');
  assert.equal(keys('code:').length, 1);
  s.clock.t += 121_000;
  const res = await s.form('/oauth/token', { grant_type: 'authorization_code', code: stale, redirect_uri: REDIRECT }, { authorization: tokens.basic });
  assert.equal(res.status, 400);
  assert.equal(keys('code:').length, 0);
});

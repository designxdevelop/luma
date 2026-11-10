// Luma Alexa doorbell relay: one relay per home, deployed to your own Cloudflare account.
//
// Alexa routine ("When the Blink doorbell is pressed") -> "Control scene: Doorbell Alert"
// -> Alexa sends SceneController.Activate to the Lambda forwarder -> POST /alexa here
// -> queued for the Luma hub, which long-polls /hub/next over outbound HTTPS.
//
// OAuth account linking uses a one-time pairing code that Luma shows, so no user
// passwords exist here. Secrets (wrangler secret put): HUB_TOKEN, ALEXA_CLIENT_ID,
// ALEXA_CLIENT_SECRET, ALEXA_REDIRECT_URIS (comma-separated, from the Alexa console), LAMBDA_SECRET.

export const ENDPOINT_ID = 'luma-doorbell-alert';
const ACCESS_TTL = 3600, CODE_TTL = 120, PAIRING_TTL = 600, PAIRING_ATTEMPTS = 5;
const EVENT_TTL = 30, POLL_HOLD = 25, ONLINE_WINDOW = 40, QUEUE_LIMIT = 5;
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

const encoder = new TextEncoder();
async function sha256(text) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(text)))].map((b) => b.toString(16).padStart(2, '0')).join('');
}
/** Compares digests, so length and content timing reveal nothing about the secret. */
async function same(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || !b) return false;
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0;
}
function randomToken() {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function pairingCode() {
  return [...crypto.getRandomValues(new Uint8Array(8))].map((b) => ALPHABET[b % 32]).join('');
}
const escape = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const security = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' };
const json = (status, body) => new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...security } });
const page = (status, body) => new Response(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Link Luma</title><body style="font:16px system-ui;max-width:28rem;margin:3rem auto;padding:0 1rem">${body}</body>`, {
  status, headers: { 'content-type': 'text/html; charset=utf-8', 'content-security-policy': "default-src 'none'; form-action 'self'; frame-ancestors 'none'", ...security },
});

export class Bridge {
  /** `storage` is Durable Object storage (get/put/delete/list); `now` returns milliseconds. */
  constructor({ env, storage, now = () => Date.now() }) {
    this.env = env; this.storage = storage; this.now = now;
    this.queue = []; this.waiter = null; this.lastPoll = -Infinity;
  }
  get seconds() { return this.now() / 1000; }

  async fetch(request) {
    const url = new URL(request.url);
    try {
      if (url.pathname === '/oauth/authorize' && request.method === 'GET') return this.authorizePage(url.searchParams);
      if (url.pathname === '/oauth/authorize' && request.method === 'POST') return this.authorize(new URLSearchParams(await request.text()));
      if (url.pathname === '/oauth/token' && request.method === 'POST') return this.token(request, new URLSearchParams(await request.text()));
      if (url.pathname === '/alexa' && request.method === 'POST') {
        if (!(await same(request.headers.get('x-luma-relay-secret'), this.env.LAMBDA_SECRET))) return json(401, { error: 'unauthorized' });
        return json(200, await this.directive(await request.json()));
      }
      if (url.pathname.startsWith('/hub/') && request.method === 'POST') {
        const bearer = (request.headers.get('authorization') || '').replace(/^Bearer /, '');
        if (!this.env.HUB_TOKEN || this.env.HUB_TOKEN.length < 32 || !(await same(bearer, this.env.HUB_TOKEN))) return json(401, { error: 'unauthorized' });
        if (url.pathname === '/hub/next') return this.next(await request.json().catch(() => ({})));
        if (url.pathname === '/hub/pairing-code') return this.newPairingCode();
        if (url.pathname === '/hub/unlink') return this.unlink();
      }
      return json(404, { error: 'not found' });
    } catch {
      return json(400, { error: 'bad request' });
    }
  }

  // ---------- OAuth 2.0 authorization code grant (Alexa account linking) ----------

  /** Only an exact, configured Alexa redirect URL is ever redirected to. */
  checkClient(params) {
    const allowed = (this.env.ALEXA_REDIRECT_URIS || '').split(',').map((s) => s.trim()).filter(Boolean);
    return params.get('response_type') === 'code' && params.get('client_id') === this.env.ALEXA_CLIENT_ID && allowed.includes(params.get('redirect_uri') || '');
  }

  authorizePage(params, message = '') {
    if (!this.checkClient(params)) return page(400, '<h1>Link request not recognised</h1><p>Start account linking from the Alexa app.</p>');
    const hidden = ['response_type', 'client_id', 'redirect_uri', 'state', 'scope'].map((k) => `<input type="hidden" name="${k}" value="${escape(params.get(k) || '')}">`).join('');
    return page(message ? 400 : 200, `<h1>Link Luma to Alexa</h1><p>In Luma, open Automations › Doorbell alert › <b>Get Pairing Code</b>, then enter it here.</p>${message ? `<p role="alert" style="color:#b00">${escape(message)}</p>` : ''}
<form method="post">${hidden}<label>Pairing code<br><input name="pairing_code" autocomplete="one-time-code" autocapitalize="characters" maxlength="12" required style="font-size:1.4rem;letter-spacing:.2em"></label><p><button type="submit">Link</button></p></form>`);
  }

  async authorize(params) {
    if (!this.checkClient(params)) return this.authorizePage(params);
    const pairing = await this.storage.get('pairing');
    if (!pairing || pairing.expiresAt < this.seconds) return this.authorizePage(params, 'No current pairing code. Get a new one in Luma.');
    const entered = (params.get('pairing_code') || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (await sha256(entered) !== pairing.hash) {
      pairing.attempts += 1;
      if (pairing.attempts >= PAIRING_ATTEMPTS) await this.storage.delete('pairing'); else await this.storage.put('pairing', pairing);
      return this.authorizePage(params, pairing.attempts >= PAIRING_ATTEMPTS ? 'Too many tries. Get a new code in Luma.' : 'That code is not right.');
    }
    await this.storage.delete('pairing');
    const code = randomToken();
    await this.storage.put(`code:${await sha256(code)}`, { redirectUri: params.get('redirect_uri'), expiresAt: this.seconds + CODE_TTL });
    const target = new URL(params.get('redirect_uri'));
    target.searchParams.set('code', code);
    if (params.get('state')) target.searchParams.set('state', params.get('state'));
    return new Response(null, { status: 302, headers: { location: target.toString(), ...security } });
  }

  async token(request, params) {
    // Alexa sends client credentials as HTTP Basic or in the body, per the console setting.
    let id = params.get('client_id'), secret = params.get('client_secret');
    const basic = (request.headers.get('authorization') || '').match(/^Basic (.+)$/);
    if (basic) [id, secret] = atob(basic[1]).split(':').map(decodeURIComponent);
    if (!(await same(id, this.env.ALEXA_CLIENT_ID)) || !(await same(secret, this.env.ALEXA_CLIENT_SECRET))) return json(401, { error: 'invalid_client' });
    if (params.get('grant_type') === 'authorization_code') {
      const key = `code:${await sha256(params.get('code') || '')}`;
      const code = await this.storage.get(key);
      await this.storage.delete(key); // single use, even on failure
      if (!code || code.expiresAt < this.seconds || code.redirectUri !== params.get('redirect_uri')) return json(400, { error: 'invalid_grant' });
      return json(200, await this.issue());
    }
    if (params.get('grant_type') === 'refresh_token') {
      const key = `refresh:${await sha256(params.get('refresh_token') || '')}`;
      if (!(await this.storage.get(key))) return json(400, { error: 'invalid_grant' });
      await this.storage.delete(key);
      return json(200, await this.issue());
    }
    return json(400, { error: 'unsupported_grant_type' });
  }

  async issue() {
    const access = randomToken(), refresh = randomToken();
    await this.storage.put(`access:${await sha256(access)}`, { expiresAt: this.seconds + ACCESS_TTL });
    await this.storage.put(`refresh:${await sha256(refresh)}`, { createdAt: this.seconds });
    return { access_token: access, token_type: 'Bearer', expires_in: ACCESS_TTL, refresh_token: refresh };
  }

  async tokenState(token) {
    const key = typeof token === 'string' && token ? `access:${await sha256(token)}` : undefined;
    const entry = key ? await this.storage.get(key) : undefined;
    if (!entry) return 'INVALID_AUTHORIZATION_CREDENTIAL';
    if (entry.expiresAt < this.seconds) { await this.storage.delete(key); return 'EXPIRED_AUTHORIZATION_CREDENTIAL'; }
    return 'ok';
  }

  // ---------- Alexa directives (from the Lambda forwarder) ----------

  async directive(event) {
    const { header = {}, endpoint, payload = {} } = event?.directive || {};
    const reply = (namespace, name, extra = {}) => ({ event: { header: { namespace, name, payloadVersion: '3', messageId: crypto.randomUUID(), ...(header.correlationToken ? { correlationToken: header.correlationToken } : {}) }, ...extra } });
    const error = (type, message) => reply('Alexa', 'ErrorResponse', { ...(endpoint ? { endpoint } : {}), payload: { type, message } });

    if (header.namespace === 'Alexa.Discovery' && header.name === 'Discover') {
      const state = await this.tokenState(payload.scope?.token);
      if (state !== 'ok') return error(state, 'Link Luma again in the Alexa app.');
      return reply('Alexa.Discovery', 'Discover.Response', { payload: { endpoints: [{
        endpointId: ENDPOINT_ID,
        manufacturerName: 'Luma',
        description: 'Flashes the Govee lights you chose in Luma, then restores them',
        friendlyName: 'Doorbell Alert',
        displayCategories: ['SCENE_TRIGGER'],
        cookie: {},
        capabilities: [
          { type: 'AlexaInterface', interface: 'Alexa.SceneController', version: '3', supportsDeactivation: true },
          { type: 'AlexaInterface', interface: 'Alexa', version: '3' },
        ],
      }] } });
    }
    if (header.namespace === 'Alexa.Authorization' && header.name === 'AcceptGrant') {
      const state = await this.tokenState(payload.grantee?.token);
      if (state !== 'ok') return reply('Alexa.Authorization', 'ErrorResponse', { payload: { type: 'ACCEPT_GRANT_FAILED', message: 'Link Luma again.' } });
      return reply('Alexa.Authorization', 'AcceptGrant.Response', { payload: {} });
    }
    if (header.namespace === 'Alexa.SceneController' && (header.name === 'Activate' || header.name === 'Deactivate')) {
      const state = await this.tokenState(endpoint?.scope?.token);
      if (state !== 'ok') return error(state, 'Link Luma again in the Alexa app.');
      if (endpoint.endpointId !== ENDPOINT_ID) return error('NO_SUCH_ENDPOINT', 'Unknown scene.');
      if (!this.waiter && this.seconds - this.lastPoll > ONLINE_WINDOW) return error('ENDPOINT_UNREACHABLE', 'Luma is not running or is offline.');
      const id = String(header.messageId || crypto.randomUUID()).slice(0, 200);
      this.push({ id, type: header.name === 'Activate' ? 'activate' : 'deactivate', issuedAt: this.seconds });
      return { ...reply('Alexa.SceneController', header.name === 'Activate' ? 'ActivationStarted' : 'DeactivationStarted', {
        endpoint: { scope: endpoint.scope, endpointId: ENDPOINT_ID },
        payload: { cause: { type: 'VOICE_INTERACTION' }, timestamp: new Date(this.now()).toISOString().replace(/\.\d{3}Z$/, 'Z') },
      }), context: {} };
    }
    return error('INVALID_DIRECTIVE', 'Not supported.');
  }

  // ---------- Luma hub ----------

  push(event) {
    this.queue = [...this.queue, event].slice(-QUEUE_LIMIT);
    if (this.waiter) { const { resolve } = this.waiter; this.waiter = null; resolve(); }
  }

  take() {
    const fresh = this.queue.filter((e) => this.seconds - e.issuedAt <= EVENT_TTL);
    this.queue = [];
    return fresh;
  }

  /** Long poll: answers at once with queued events, or holds up to 25 s for the next one. */
  async next(body) {
    this.lastPoll = this.seconds;
    let events = this.take();
    if (!events.length && body.wait !== false) {
      if (this.waiter) { this.waiter.resolve(); } // a newer poll replaces an older one
      await new Promise((resolve) => {
        const timer = setTimeout(() => { if (this.waiter?.resolve === done) this.waiter = null; resolve(); }, POLL_HOLD * 1000);
        const done = () => { clearTimeout(timer); resolve(); };
        this.waiter = { resolve: done };
      });
      this.lastPoll = this.seconds;
      events = this.take();
    }
    return events.length ? json(200, { events }) : new Response(null, { status: 204, headers: security });
  }

  async newPairingCode() {
    const code = pairingCode();
    const expiresAt = Math.floor(this.seconds + PAIRING_TTL);
    await this.storage.put('pairing', { hash: await sha256(code), expiresAt, attempts: 0 });
    return json(200, { code, expiresAt });
  }

  async unlink() {
    for (const prefix of ['access:', 'refresh:', 'code:']) {
      for (const key of (await this.storage.list({ prefix })).keys()) await this.storage.delete(key);
    }
    await this.storage.delete('pairing');
    return new Response(null, { status: 204, headers: security });
  }
}

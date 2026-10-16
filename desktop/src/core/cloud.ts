// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Govee's capability (cloud) API. Every request goes through ONE promise chain per
// GoveeCloud instance (a single account queue) and is paced; commands are never retried.

import { randomUUID } from 'node:crypto';
import type { Capability, CapabilityCommand, JSONValue, LightDevice } from '../shared/types';
import { LumaError, isObject, safeInt } from './model';

export interface HttpLike { status: number; headers: { get(name: string): string | null }; text(): Promise<string> }
export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body?: string; redirect?: 'error'; signal?: AbortSignal }) => Promise<HttpLike>;
export interface CloudOptions {
  fetch?: FetchLike;
  now?: () => number;
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
  timeoutMs?: number;
}

type DeviceState = Partial<Pick<LightDevice, 'power' | 'brightness' | 'rgb' | 'colorTemperature' | 'online' | 'lastSeen'>>;

const BASE_URL = 'https://openapi.api.govee.com/router/api/v1/';
const ACCOUNT_SPACING_MS = 84;
const DEVICE_SPACING_MS = 1000;
const READ_SPACING_MS = 2000;
const MAX_BODY_CHARS = 8 * 1024 * 1024;

const abortError = () => new DOMException('The request was cancelled.', 'AbortError');

const defaultSleep = (ms: number, signal?: AbortSignal) => new Promise<void>((resolve, reject) => {
  if (signal?.aborted) return reject(abortError());
  const onAbort = () => { clearTimeout(timer); reject(abortError()); };
  const timer = setTimeout(() => { signal?.removeEventListener('abort', onAbort); resolve(); }, ms);
  signal?.addEventListener('abort', onAbort, { once: true });
});

export class GoveeCloud {
  private readonly apiKey: string;
  private readonly fetchImpl: FetchLike;
  private readonly now: () => number;
  private readonly sleep: (ms: number, signal?: AbortSignal) => Promise<void>;
  private readonly timeoutMs: number;
  private tail: Promise<void> = Promise.resolve();
  private nextAccount = 0;
  private readonly nextDevice = new Map<string, number>();
  private readonly nextRead = new Map<string, number>();

  constructor(apiKey: string, options: CloudOptions = {}) {
    this.apiKey = apiKey.trim();
    this.fetchImpl = options.fetch ?? ((url, init) => fetch(url, init));
    this.now = options.now ?? Date.now;
    this.sleep = options.sleep ?? defaultSleep;
    this.timeoutMs = options.timeoutMs ?? 20_000;
  }

  async devices(): Promise<LightDevice[]> {
    const root = await this.request('GET', 'user/devices');
    if (!Array.isArray(root.data)) throw new LumaError('Govee returned an invalid device list.');
    const lights: LightDevice[] = [];
    for (const row of root.data) {
      if (!isObject(row) || typeof row.device !== 'string' || typeof row.sku !== 'string') throw new LumaError('Govee returned a device without an ID or model.');
      if (typeof row.type === 'string' && row.type !== 'devices.types.light') continue;
      lights.push({
        id: row.device,
        sku: row.sku,
        name: typeof row.deviceName === 'string' && row.deviceName !== '' ? row.deviceName : row.sku,
        room: 'Unassigned',
        capabilities: row.capabilities === undefined ? [] : decodeCapabilities(row.capabilities),
      });
    }
    return lights;
  }

  /** Returns only what Govee reported. Offline devices yield just `{online:false}` (their values are historical). */
  async state(device: LightDevice): Promise<DeviceState> {
    const root = await this.request('POST', 'device/state', { device });
    const payload = root.payload;
    if (!isObject(payload) || !Array.isArray(payload.capabilities)) throw new LumaError('Govee returned invalid device state.');
    validateIdentity(payload, device);
    const reported = payload.capabilities.filter(isObject);
    const onlineValue = reported.find((c) => c.instance === 'online')?.state;
    const online = isObject(onlineValue) && typeof onlineValue.value === 'boolean' ? onlineValue.value : undefined;
    if (online === false) return { online: false };
    const out: DeviceState = {};
    if (online === true) { out.online = true; out.lastSeen = this.now(); }
    for (const cap of reported) {
      const state = cap.state;
      if (!isObject(state)) continue;
      const v = state.value;
      switch (cap.instance) {
        case 'powerSwitch': { const n = safeInt(v, 0, 1); if (n !== undefined) out.power = n === 1; break; }
        case 'brightness': { const n = safeInt(v, 0, 100); if (n !== undefined) out.brightness = n; break; }
        case 'colorRgb': { const n = safeInt(v, 0, 0xffffff); if (n !== undefined) out.rgb = n; break; }
        case 'colorTemperatureK': { const n = safeInt(v, 0, 10000); if (n !== undefined && (n === 0 || n >= 1000)) out.colorTemperature = n; break; }
      }
    }
    return out;
  }

  /** Never retried automatically: a retry could double-apply a command whose reply was lost. */
  async control(device: LightDevice, command: CapabilityCommand, signal?: AbortSignal): Promise<void> {
    await this.request('POST', 'device/control', { device, command, signal });
  }

  async scenes(device: LightDevice, diy: boolean): Promise<Capability[]> {
    const root = await this.request('POST', diy ? 'device/diy-scenes' : 'device/scenes', { device });
    const payload = root.payload;
    if (!isObject(payload)) throw new LumaError('Govee returned invalid scene data.');
    validateIdentity(payload, device);
    if (payload.capabilities !== undefined) return decodeCapabilities(payload.capabilities);
    // The dynamic-scene documentation also shows a single capability/value payload.
    if (typeof payload.type === 'string' && typeof payload.instance === 'string' && payload.value !== undefined) {
      return [{ type: payload.type, instance: payload.instance, parameters: { dataType: 'ENUM', options: [{ name: payload.instance, value: payload.value }] } }];
    }
    throw new LumaError('Govee returned invalid scene capabilities.');
  }

  private request(method: 'GET' | 'POST', path: string, opts: { device?: LightDevice; command?: CapabilityCommand; signal?: AbortSignal } = {}): Promise<{ [key: string]: JSONValue }> {
    const { signal } = opts;
    const run = this.tail.then(() => {
      if (signal?.aborted) throw abortError();
      return this.execute(method, path, opts);
    });
    this.tail = run.then(() => undefined, () => undefined); // one failure must not break the chain
    if (!signal) return run;
    // A queued request can be cancelled immediately; its turn in the chain then throws before sending.
    return new Promise((resolve, reject) => {
      const onAbort = () => reject(abortError());
      signal.addEventListener('abort', onAbort, { once: true });
      run.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort));
    });
  }

  private async execute(method: string, path: string, opts: { device?: LightDevice; command?: CapabilityCommand; signal?: AbortSignal }): Promise<{ [key: string]: JSONValue }> {
    const { device, command, signal } = opts;
    if (this.apiKey === '') throw new LumaError('Add your Govee API key in Settings first.');
    const readKey = `${path}:${device?.id ?? 'account'}`;
    let ready = this.nextAccount;
    if (device) ready = Math.max(ready, this.nextDevice.get(device.id) ?? 0);
    if (!command) ready = Math.max(ready, this.nextRead.get(readKey) ?? 0);
    const wait = ready - this.now();
    if (wait > 0) await this.sleep(wait, signal);
    if (signal?.aborted) throw abortError();

    const sentAt = this.now();
    this.nextAccount = sentAt + ACCOUNT_SPACING_MS;
    if (device) this.nextDevice.set(device.id, sentAt + DEVICE_SPACING_MS);
    if (!command) this.nextRead.set(readKey, sentAt + READ_SPACING_MS);

    let body: string | undefined;
    if (device) {
      const payload: { [key: string]: JSONValue } = { sku: device.sku, device: device.id };
      if (command) payload.capability = { type: command.type, instance: command.instance, value: command.value };
      body = JSON.stringify({ requestId: randomUUID(), payload });
    }

    const controller = new AbortController();
    const onAbort = () => controller.abort();
    signal?.addEventListener('abort', onAbort, { once: true });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, this.timeoutMs);
    let status: number, retryAfter: string | null, text: string;
    try {
      const response = await this.fetchImpl(BASE_URL + path, {
        method,
        headers: { 'Govee-API-Key': this.apiKey, 'Content-Type': 'application/json' },
        body,
        redirect: 'error', // never forward the API key to a redirect target
        signal: controller.signal,
      });
      status = response.status;
      retryAfter = response.headers.get('Retry-After');
      if (status === 429) this.pause(retryAfter);
      if (status < 200 || status >= 300) text = '';
      else text = await response.text();
    } catch {
      if (signal?.aborted) throw abortError();
      // Never echo the underlying message: it can carry request details.
      throw new LumaError(timedOut ? 'Govee did not respond in time.' : 'Could not reach Govee. Check your connection.', 502);
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    }

    if (status >= 300 && status < 400) throw new LumaError('Govee returned an unexpected redirect.', 502);
    if (status === 429) throw new LumaError("Govee's rate limit was reached. Requests are paused; try again later.", 429);
    if (status === 401 || status === 403) throw new LumaError(`Govee rejected the API key (HTTP ${status}). It may have been rotated or revoked; check your key in Settings.`, 401);
    if (status < 200 || status >= 300) throw new LumaError(`Govee request failed (HTTP ${status}).`, 502);
    if (text.length > MAX_BODY_CHARS) throw new LumaError('Govee response is too large.', 502);
    let root: unknown;
    try { root = JSON.parse(text); } catch { throw new LumaError('Govee returned a response that is not valid JSON.', 502); }
    if (!isObject(root)) throw new LumaError('Govee returned an unexpected response.', 502);
    if (root.code !== 200) {
      if (root.code === 429) {
        this.pause(retryAfter);
        throw new LumaError("Govee's rate limit was reached. Requests are paused; try again later.", 429);
      }
      // Avoid echoing arbitrary remote response text, which may include account details.
      throw new LumaError(`Govee rejected the request (${typeof root.code === 'number' ? root.code : 'missing code'}).`, 502);
    }
    return root;
  }

  /** Pauses the whole account queue for Retry-After seconds (2…3600, default 60). */
  private pause(retryAfter: string | null): void {
    const parsed = retryAfter === null || retryAfter.trim() === '' ? NaN : Number(retryAfter);
    const seconds = Math.min(3600, Math.max(2, Number.isFinite(parsed) ? parsed : 60));
    this.nextAccount = Math.max(this.nextAccount, this.now() + seconds * 1000);
  }
}

function decodeCapabilities(value: JSONValue): Capability[] {
  if (!Array.isArray(value)) throw new LumaError('Govee returned invalid capabilities.');
  return value.map((row) => {
    if (!isObject(row) || typeof row.type !== 'string' || typeof row.instance !== 'string') throw new LumaError('Govee returned an incomplete capability.');
    const capability: Capability = { type: row.type, instance: row.instance };
    if (row.parameters !== undefined) capability.parameters = row.parameters;
    return capability;
  });
}

function validateIdentity(payload: { [key: string]: JSONValue }, device: LightDevice): void {
  if (typeof payload.device === 'string' && payload.device !== device.id) throw new LumaError('Govee returned state for a different device.');
  if (typeof payload.sku === 'string' && payload.sku !== device.sku) throw new LumaError('Govee returned a different device model.');
}

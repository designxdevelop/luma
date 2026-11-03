// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Read-only sign-in to the private Govee Home account API, ported from the native
// GoveeAccount/GoveeHomeImport. Used only to read rooms, control groups (DreamView) and
// automations; nothing here controls lights. Contract per homebridge-govee @ c7b3037 and
// goveetl @ 3890402; live-checked by the native app on 2026-11-02. Token refresh is not
// implemented: goveetl reports Govee rejects it (401), so an expired session signs in again.

import type { GoveeAutomation as Automation, GoveeConflict as Conflict, GoveeHomeGroup as HomeGroup, GoveeImportPlan as ImportPlan, JSONValue, LightDevice, LightScene, SceneSchedule } from '../shared/types';
import { LumaError, isObject } from './model';
import type { FetchLike } from './cloud';

export const ACCOUNT_HOST = 'https://app2.govee.com/';
// ponytail: pinned to homebridge's live-used values; bump when Govee rejects them.
const APP_VERSION = '7.4.10';
const USER_AGENT = 'GoveeHome/7.4.10 (com.ihoment.GoVeeSensor; build:8; iOS 26.5.0) Alamofire/5.11.0';
const LIMIT = 8 * 1024 * 1024;

export class SessionExpired extends LumaError {
  constructor() { super('Your Govee Home sign-in expired. Sign in again.', 401); }
}

export type LoginResult = { kind: 'needsCode' } | { kind: 'signedIn'; token: string };

export class GoveeAccount {
  private readonly fetchImpl: FetchLike;
  /** `clientId` must stay the same between sign-ins, or Govee asks for a code every time. */
  constructor(private readonly clientId: string, options: { fetch?: FetchLike; host?: string } = {}) {
    this.fetchImpl = options.fetch ?? ((url, init) => fetch(url, init));
    this.host = options.host ?? ACCOUNT_HOST;
    if (!this.host.startsWith('https://')) throw new LumaError('Govee sign-in requires HTTPS.');
  }
  private readonly host: string;

  /** When Govee wants a code (status 454), this also asks it to email one (`type 8`). */
  async login(email: string, password: string, code?: string): Promise<LoginResult> {
    const body: { [k: string]: JSONValue } = { email, password, client: this.clientId };
    if (code) body.code = code;
    const root = await this.post('account/rest/account/v2/login', body);
    if (root.status === 454) {
      if (code) throw new LumaError("Govee didn't accept that code. Request a new one and try again.");
      const sent = await this.post('account/rest/account/v1/verification', { email, type: 8 });
      if (sent.status !== 200) throw new LumaError("Govee couldn't send a sign-in code. Try again later.");
      return { kind: 'needsCode' };
    }
    if (root.status === 200) {
      const token = isObject(root.client) && typeof root.client.token === 'string' ? root.client.token.trim() : '';
      if (!token) throw new LumaError('Govee returned an incomplete session.');
      return { kind: 'signedIn', token };
    }
    // The server's message is never shown: it can echo account details.
    if (typeof root.status === 'number') throw new LumaError(`Govee didn't accept the email or password (status ${root.status}).`);
    throw new LumaError('Govee returned an unexpected sign-in response.');
  }

  deviceList(token: string) { return this.get('bff-app/v1/device/list', token); }
  groups(token: string) { return this.get('bff-app/v1/general-control/list?filterEmpty=false', token); }
  automations(token: string) { return this.get('bff-app/v1/ecology/resource/automations', token); }

  // ponytail: GET only. Group control and automation edits are private POSTs that act on lights; not implemented.
  private async get(path: string, token: string): Promise<JSONValue> {
    const { status, root } = await this.send('GET', path, undefined, token);
    if (status === 401 || status === 403 || (isObject(root) && root.status === 401)) throw new SessionExpired();
    if (status < 200 || status >= 300) throw new LumaError(`Govee Home request failed (HTTP ${status}).`, 502);
    if (root === undefined) throw new LumaError('Govee Home returned an unreadable response.', 502);
    return root;
  }

  private async post(path: string, body: JSONValue): Promise<{ [k: string]: JSONValue }> {
    const { status, root } = await this.send('POST', path, JSON.stringify(body));
    if (status < 200 || status >= 300 || !isObject(root)) throw new LumaError(`Govee sign-in failed (HTTP ${status}).`, 502);
    return root;
  }

  private async send(method: string, path: string, body?: string, token?: string): Promise<{ status: number; root?: JSONValue }> {
    const headers: Record<string, string> = {
      appVersion: APP_VERSION, clientId: this.clientId, clientType: '1', iotVersion: '0', timestamp: String(Date.now()), 'User-Agent': USER_AGENT,
    };
    if (body) headers['Content-Type'] = 'application/json';
    if (token) headers.Authorization = `Bearer ${token}`;
    let status: number, text = '';
    try {
      // A redirect would resend the password or token elsewhere, so it is an error.
      const response = await this.fetchImpl(this.host + path, { method, headers, body, redirect: 'error', signal: AbortSignal.timeout(30_000) });
      status = response.status;
      if (status >= 200 && status < 300) text = await response.text();
    } catch {
      throw new LumaError('Could not reach Govee Home. Check your connection.', 502); // never echo request details
    }
    if (text.length > LIMIT) throw new LumaError('Govee response is too large.', 502);
    let root: JSONValue | undefined;
    try { root = text ? JSON.parse(text) as JSONValue : undefined; } catch { root = undefined; }
    return { status, root };
  }
}

// ---------- parsing (shapes per goveetl @ 3890402 and a live account, 2026-11-02) ----------

export interface ImportEntry { device: string; sku: string; name: string; room?: string; firmware?: string }

const clean = (v: unknown): string | undefined => (typeof v === 'string' && v.trim() ? v.trim().slice(0, 64) : undefined);
const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);

function envelope(root: JSONValue): { [k: string]: JSONValue } {
  if (!isObject(root)) throw new LumaError('Govee Home returned an unreadable response.');
  if (typeof root.status === 'number' && root.status !== 200) throw new LumaError(`Govee Home request failed (status ${root.status}).`);
  return isObject(root.data) ? root.data : root;
}

/** `GET bff-app/v1/device/list`: only identity, model, name and room are read. */
export function parseDeviceList(root: JSONValue): ImportEntry[] {
  const body = envelope(root);
  if (!Array.isArray(body.devices)) throw new LumaError('No device list found in the Govee Home response.');
  const rooms = new Map<number, string>();
  for (const g of Array.isArray(body.groups) ? body.groups : []) {
    if (isObject(g) && num(g.groupId) !== undefined && clean(g.groupName)) rooms.set(g.groupId as number, clean(g.groupName)!);
  }
  return body.devices.flatMap((row) => {
    if (!isObject(row) || !clean(row.device) || !clean(row.sku)) return [];
    const room = num(row.groupId) !== undefined ? rooms.get(row.groupId as number) : undefined;
    const firmware = clean(row.versionSoft);
    return [{ device: clean(row.device)!, sku: clean(row.sku)!, name: clean(row.deviceName) ?? clean(row.sku)!, ...(room ? { room } : {}), ...(firmware ? { firmware } : {}) }];
  });
}

/** Matches on device ID (case-insensitive) and model. Never creates lights. */
export function planRooms(entries: ImportEntry[], devices: LightDevice[]): ImportPlan {
  const plan: ImportPlan = { changes: [], unchanged: 0, withoutRoom: 0, notInLuma: 0 };
  for (const e of entries) {
    const d = devices.find((x) => x.id.toLowerCase() === e.device.toLowerCase() && x.sku.toLowerCase() === e.sku.toLowerCase());
    if (!d) { plan.notInLuma++; continue; }
    if (!e.room) { plan.withoutRoom++; continue; }
    if (e.room === d.room) { plan.unchanged++; continue; }
    plan.changes.push({ deviceID: d.id, name: d.name, currentRoom: d.room, goveeRoom: e.room });
  }
  return plan;
}

/** `GET bff-app/v1/general-control/list`. "type 10 with a sceneFeastId = DreamView" is from one live sample. */
export function parseGroups(root: JSONValue): HomeGroup[] {
  const body = envelope(root);
  return (Array.isArray(body.list) ? body.list : []).flatMap((row) => {
    if (!isObject(row) || num(row.groupId) === undefined || !clean(row.name)) return [];
    const main = isObject(row.mainDevice) ? row.mainDevice : {};
    const g: HomeGroup = { id: row.groupId as number, name: clean(row.name)!, enabled: row.enable === 1, isDreamView: row.type === 10 && (num(row.sceneFeastId) ?? 0) > 0 };
    if (num(row.deviceCount) !== undefined) g.reportedLightCount = row.deviceCount as number;
    if (clean(main.device)) g.mainDevice = clean(main.device);
    if (clean(main.sku)) g.mainSKU = clean(main.sku);
    return [g];
  });
}

/** `GET bff-app/v1/ecology/resource/automations`. Read-only; `repeat` 1–7 weekday mapping is unverified. */
export function parseAutomations(root: JSONValue): Automation[] {
  const body = envelope(root);
  return (Array.isArray(body.autoExecs) ? body.autoExecs : []).flatMap((row) => {
    if (!isObject(row) || num(row.groupId) === undefined || !clean(row.name)) return [];
    const schedule = isObject(row.schedule) ? row.schedule : {};
    const times = (Array.isArray(schedule.times) ? schedule.times : []).flatMap((t) => {
      const h = isObject(t) ? num(t.hour) : undefined, m = isObject(t) ? num(t.minute) : undefined;
      return h !== undefined && m !== undefined && Number.isInteger(h) && Number.isInteger(m) && h >= 0 && h < 24 && m >= 0 && m < 60 ? [{ hour: h, minute: m }] : [];
    });
    const targets = (Array.isArray(schedule.skus) ? schedule.skus : []).flatMap((t) => {
      if (!isObject(t) || !clean(t.sku)) return [];
      const dreamView = t.isFeast === 1;
      return [{ sku: clean(t.sku)!, name: clean(dreamView ? t.feastName : t.deviceName) ?? clean(t.sku)!, isDreamView: dreamView }];
    });
    const repeatDays = (Array.isArray(schedule.repeat) ? schedule.repeat : []).filter((d): d is number => typeof d === 'number' && Number.isInteger(d));
    return [{ id: row.groupId as number, name: clean(row.name)!, enabled: row.enable === 1, times, repeatDays, targets }];
  });
}

/**
 * Enabled Govee automations at the same minute as an enabled Luma schedule touching the same
 * light (matched by model and Govee name: the automation list has no device ID). Days aren't
 * compared because Govee's weekday numbering isn't verified, so a match is a possible conflict.
 */
export function findConflicts(automations: Automation[], schedules: SceneSchedule[], scenes: LightScene[], devices: Array<LightDevice & { goveeName?: string }>): Conflict[] {
  const found: Conflict[] = [];
  for (const a of automations.filter((x) => x.enabled)) {
    for (const s of schedules.filter((x) => x.enabled && a.times.some((t) => t.hour === x.hour && t.minute === x.minute))) {
      const ids = new Set(scenes.find((sc) => sc.id === s.sceneID)?.steps.map((st) => st.deviceID) ?? []);
      for (const d of devices.filter((x) => ids.has(x.id))) {
        const target = a.targets.find((t) => !t.isDreamView && t.sku.toLowerCase() === d.sku.toLowerCase() && t.name === (d.goveeName ?? d.name));
        if (target) found.push({ automation: a.name, scheduleID: s.id, light: d.name });
      }
    }
  }
  return found;
}

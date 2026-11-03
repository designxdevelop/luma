import { loadWebhookIdentity, webhookSans, type WebhookIdentity } from '../core/certificate';
// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// The app model in the main process. Electron-free so the whole journey is testable
// with fakes. Confirmed state lives in `home.devices`; requested values live only in
// the ControlEngine overlay and are never persisted or served by the webhook API.

import { randomBytes, randomUUID } from 'node:crypto';
import type { ActivityEntry, AppSnapshot, BackupResult, GoveeHomeView, Capability, CapabilityCommand, DeviceReading, LightDevice, LightScene, SavedHome, SceneSchedule, SceneStep } from '../shared/types';
import { LAN_INSTANCES, LumaError, brightnessRange, decodeScene, isObject, message, power, brightness, rgb, kelvin, safeInt, supports, validateCommand, validateScene, whiteRange } from '../core/model';
import { isLight } from '../shared/devices';
import { compatibilityReport } from '../core/compat';
import { applyBackup, decodeBackup, encodeBackup } from './backup';
import { ControlEngine, type ControlOptions, type ControlTransport } from '../core/controls';
import { SceneRunner, minuteKey, shouldRun, validateSchedule } from '../core/automation';
import { GoveeCloud, type CloudOptions, type DeviceState, type FetchLike } from '../core/cloud';
import { GoveeAccount, SessionExpired, findConflicts, parseAutomations, parseDeviceList, parseGroups, planRooms, type ImportEntry } from '../core/account';
import { GoveeLan, type LanPacket } from '../core/lan';
import { WebhookServer } from '../core/http';
import { createApiHandler } from '../core/api';
import { HomeStorage, dreamViewDrafts, emptyHome, type SecretStore } from './storage';
import { FloorPlanStore } from './floor-plans';
import { BluetoothController } from './bluetooth';
import { dreamViewMemberLimit } from '../shared/library';
import { demoDevices, demoEffects, demoReadings, demoScenes } from './demo';
import { REGIONS } from '../shared/sync-math';
import { SyncController } from './sync';
import { ScheduleSync, type ScheduleSyncDeps } from './schedule-sync';
import { canonicalID } from '../core/schedule-sync';
import type { StreamField } from '../core/stream';
import { DoorbellController } from './doorbell';

const API_KEY = 'govee-api-key';
const HOME_TOKEN = 'govee-home-token';
const CLIENT_ID = 'govee-client-id';
const WEBHOOK_TOKEN = 'webhook-token';

export interface HomeOptions {
  demo: boolean;
  version: string;
  /** Undefined in demo: nothing is ever read from or written to disk. */
  storage?: HomeStorage;
  /** Undefined in demo: the credential store is never touched. */
  secrets?: SecretStore;
  copyToClipboard?(text: string): void;
  cloudOptions?: CloudOptions;
  controlOptions?: ControlOptions;
  createLan?: (handlers: ConstructorParameters<typeof GoveeLan>[0]) => GoveeLan;
  /** Real screen capture is available (connected mode on Windows). */
  captureSupported?: boolean;
  syncOptions?: Partial<ConstructorParameters<typeof SyncController>[1]>;
  /** Govee Home account requests (tests); defaults to global fetch. */
  accountFetch?: FetchLike;
  /** Schedule sync overrides (tests: transport, clock, folder). */
  scheduleSyncOptions?: Partial<ScheduleSyncDeps>;
  /** Doorbell alert clock and relay fetch (tests). */
  doorbellOptions?: Pick<ConstructorParameters<typeof DoorbellController>[0], 'clock' | 'fetch'>;
  /** Floor plans (main passes a store with an image encoder); in memory without images when omitted. */
  floorPlans?: FloorPlanStore;
  /** Sends an event to the renderer (Bluetooth writes); undefined in tests and headless use. */
  postToRenderer?(channel: string, payload?: unknown): void;
}

export class Home {
  readonly demo: boolean;
  private home: SavedHome = emptyHome();
  private cloud?: GoveeCloud;
  private lan?: GoveeLan;
  private readonly server = new WebhookServer();
  private readonly engine: ControlEngine;
  private readonly runner: SceneRunner;
  private activity: ActivityEntry[] = [];
  private notice?: string;
  private scanning = false;
  private busy = false;
  /** Bumped by disconnect; a connect/reconnect that started earlier must not resurrect the cloud. */
  private cloudGeneration = 0;
  private cloudAbort = new AbortController();
  private canSave = true;
  private webhookStatus = 'Stopped';
  private webhookIdentity?: WebhookIdentity;
  private token?: string;
  private listeners = new Set<() => void>();
  private persistTimer?: NodeJS.Timeout;
  private scheduleTimer?: NodeJS.Timeout;
  private scanTimer?: NodeJS.Timeout;
  /** IPs that answered during the current LAN session; Screen Sync never streams to a stale saved IP. */
  private lanSeen = new Set<string>();
  /** Restore writes that must go over LAN or not at all (never cloud). */
  private readonly lanOnly = new WeakSet<CapabilityCommand>();
  /** Last cloud readings per device (sensors, appliance modes). Never persisted. */
  private readonly readings = new Map<string, DeviceReading[]>();
  /** Confirmed state of the last scene's lights, taken before its first write. One level, never persisted. */
  private restorePoint?: LightScene;
  private readonly floorPlans: FloorPlanStore;
  /** Last Govee Home import, in memory only (re-read with the saved token). */
  private goveeHome: Omit<GoveeHomeView, 'available' | 'signedIn' | 'conflicts' | 'firmware'> & { entries: ImportEntry[] } = { awaitingCode: false, busy: false, groups: [], automations: [], unavailable: [], entries: [] };
  readonly sync: SyncController;
  readonly scheduleSync: ScheduleSync;
  readonly doorbell: DoorbellController;
  readonly bluetooth: BluetoothController;

  constructor(private readonly options: HomeOptions) {
    this.demo = options.demo;
    this.floorPlans = options.floorPlans ?? new FloorPlanStore(undefined, () => undefined);
    const transport: ControlTransport = {
      send: (device, command, signal) => this.transmit(device, command, signal),
      read: async (device, command) => {
        if (device.isDemo) return undefined;
        // Confirm over the route that carried the write: e.g. 1500 K goes by cloud even on a LAN light.
        if (device.ip && this.lan?.running && (!command || lanEligible(command))) { this.lan.requestStatus(device.ip); return undefined; }
        if (this.cloud) return this.absorb(device.id, await this.cloud.state(device));
        return undefined;
      },
    };
    this.engine = new ControlEngine({
      device: (id) => this.home.devices.find((d) => d.id === id),
      update: (id, mutate) => { const d = this.home.devices.find((x) => x.id === id); if (d) { mutate(d); this.schedulePersist(); } },
      changed: () => this.emit(),
      log: (text, isError) => this.log(text, isError),
      transport,
    }, options.controlOptions);
    this.runner = new SceneRunner({
      send: (step, signal) => this.engine.submit(step.deviceID, step.command, { signal }),
      changed: () => this.emit(),
      log: (text, isError) => this.log(text, isError),
    });
    this.sync = new SyncController({
      devices: () => this.home.devices.filter(isLight),
      hasPending: (id) => this.engine.pendingFor(id).length > 0 || this.doorbell?.isAlerting(id) === true,
      sceneRunning: () => this.runner.runningSceneID !== undefined,
      lanReady: (d) => !!d.ip && !!this.lan?.running && this.lanSeen.has(d.ip),
      streamWrite: (id, field, value) => this.streamWrite(id, field, value),
      restore: async (id, commands) => {
        for (const c of commands) this.lanOnly.add(c);
        // Enqueued synchronously in order; the engine sends them in order per light.
        await Promise.all(commands.map((c) => this.engine.submit(id, c)));
      },
      changed: () => this.emit(),
      log: (text, isError) => this.log(text, isError),
    }, { demo: this.demo, captureSupported: !this.demo && options.captureSupported === true, ...options.syncOptions });
    if (this.demo) {
      this.home = { ...emptyHome(), devices: demoDevices(), scenes: demoScenes() };
      for (const [id, values] of Object.entries(demoReadings())) this.readings.set(id, values);
      this.log('Demo home loaded. These are sample lights; nothing real is controlled, and changes are not saved.');
    } else if (options.storage) {
      try { this.home = options.storage.load(); }
      catch {
        this.canSave = false;
        this.log(`Your saved home could not be read. It was left untouched at ${options.storage.file}.`, true);
      }
    }
    if (this.home.syncSettings) this.sync.setSettings(this.home.syncSettings);
    this.scheduleSync = new ScheduleSync({
      folder: this.demo ? undefined : options.storage?.folder,
      secrets: this.demo ? undefined : options.secrets,
      platform: process.platform === 'win32' ? 'windows' : process.platform,
      scenes: () => this.home.scenes,
      schedules: () => this.home.schedules,
      apply: (scenes, schedules) => { this.home.scenes = scenes; this.home.schedules = schedules; this.schedulePersist(); },
      run: (sceneID) => this.runSavedScene(sceneID),
      runStatus: (runID) => this.runner.runs.find((r) => r.id === runID)?.status,
      persistHome: () => this.persistNow(),
      log: (text, isError) => this.log(text, isError),
      changed: () => this.emit(),
      ...options.scheduleSyncOptions,
    });
    this.bluetooth = new BluetoothController({
      emit: () => this.emit(),
      post: options.postToRenderer ?? (() => {}),
      supported: !options.demo && !!options.postToRenderer,
      accountName: (localName) => {
        const entry = this.goveeHome.entries.find((e) => e.bleName?.toLowerCase() === localName.toLowerCase());
        return entry && this.home.devices.find((d) => d.id.toLowerCase() === entry.device.toLowerCase())?.name;
      },
    });
    this.doorbell = new DoorbellController({
      demo: this.demo, folder: options.storage?.folder, secrets: options.secrets,
      lights: () => this.home.devices.filter(isLight),
      device: (id) => this.home.devices.find((d) => d.id === id),
      lanReady: (d) => !!d.ip && !!this.lan?.running && this.lanSeen.has(d.ip),
      busy: (id) => this.sync.holds(id) ? 'in Screen or Audio Sync' : this.home.devices.find((d) => d.id === id)?.dreamView ? 'DreamView is on' : this.engine.pendingFor(id).length ? 'being changed' : undefined,
      read: (device) => this.freshRead(device),
      write: (id, command) => this.alertWrite(id, command),
      log: (text, isError) => this.log(text, isError),
      changed: () => this.emit(),
      ...options.doorbellOptions,
    });
    this.scheduleTimer = setInterval(() => this.tickSchedules(), 15_000);
    this.scheduleTimer.unref?.();
  }

  // ---------- observation ----------

  subscribe(listener: () => void): () => void { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  private emit(): void { for (const l of this.listeners) l(); }

  log(text: string, isError = false): void {
    this.activity.unshift({ id: randomUUID(), time: Date.now(), message: text, isError });
    this.activity.length = Math.min(this.activity.length, 200);
    if (isError) this.notice = text;
    this.emit();
  }

  clearActivity(): void { this.activity = []; this.emit(); }
  setAppearance(value: unknown): void {
    if (value !== 'system' && value !== 'light' && value !== 'dark') throw new LumaError('Invalid appearance.');
    this.home.appearance = value; this.schedulePersist(); this.emit();
  }
  setSyncSettings(value: unknown): void {
    this.sync.setSettings(value); this.home.syncSettings = { ...this.sync.settings }; this.schedulePersist();
  }
  setSyncAssignments(value: unknown): void {
    if (!Array.isArray(value) || value.length > 1000) throw new LumaError('Invalid assignments.');
    const ids = new Set<string>();
    const assignments = value.map((item: unknown) => {
      if (!item || typeof item !== 'object') throw new LumaError('Invalid assignment.');
      const v = item as Record<string, unknown>;
      if (typeof v.id !== 'string' || !v.id.trim() || v.id.length > 128 || /[\u0000-\u001f]/.test(v.id) || ids.has(v.id) || typeof v.region !== 'string' || !REGIONS.includes(v.region as never) || typeof v.included !== 'boolean') throw new LumaError('Invalid assignment.');
      ids.add(v.id); return { id: v.id, region: v.region as (typeof REGIONS)[number], included: v.included };
    });
    this.home.syncAssignments = assignments; this.schedulePersist(); this.emit();
  }
  dismissNotice(): void { this.notice = undefined; this.emit(); }

  /** Confirmed state only. */
  confirmedDevices(): LightDevice[] { return this.home.devices.map((d) => ({ ...d })); }

  snapshot(): AppSnapshot {
    const pending: AppSnapshot['pending'] = {};
    for (const d of this.home.devices) { const p = this.engine.pendingFor(d.id); if (p.length) pending[d.id] = p; }
    return {
      demo: this.demo,
      platformSecretsAvailable: this.options.secrets?.available ?? false,
      cloudConnected: this.cloud !== undefined,
      hasSavedKey: !this.demo && this.hasSecret(API_KEY),
      scanning: this.scanning,
      busy: this.busy,
      devices: this.home.devices.map((d) => this.engine.overlay(d)),
      pending,
      scenes: this.home.scenes,
      schedules: this.home.schedules,
      runs: this.runner.runs.slice(0, 100),
      runningSceneID: this.runner.runningSceneID,
      activity: this.activity.slice(0, 100),
      notice: this.notice,
      webhook: {
        running: this.server.running,
        status: this.webhookStatus,
        fingerprint: this.webhookIdentity?.fingerprint,
        spkiPin: this.webhookIdentity?.spkiPin,
        port: this.home.webhookPort,
        allowLAN: this.home.allowLAN,
        maskedToken: this.token ? `${this.token.slice(0, 3)}…${this.token.slice(-4)}` : this.demo ? undefined : this.hasSecret(WEBHOOK_TOKEN) ? 'lm_…saved' : undefined,
        available: !this.demo && (this.options.secrets?.available ?? false),
      },
      canSave: this.canSave && !this.demo,
      version: this.options.version,
      sync: this.sync.view(),
      appearance: this.home.appearance ?? 'system',
      syncAssignments: this.home.syncAssignments ?? [],
      readings: Object.fromEntries(this.readings),
      goveeHome: this.goveeHomeView(),
      scheduleSync: this.scheduleSync.view(),
      doorbell: this.doorbell.view(),
      restorePoint: this.restorePoint?.name,
      floorPlans: this.floorPlans.list(),
      floorPlansWritable: this.floorPlans.writable && (this.canSave || this.demo),
      dreamViewDrafts: this.home.dreamViewDrafts ?? {},
      bluetooth: this.bluetooth.view(),
    };
  }

  // ---------- floor plans ----------

  /** Mutates floor plans and tells the renderer. Every change is validated by the store. */
  floorPlan<T>(change: (store: FloorPlanStore) => T): T {
    const result = change(this.floorPlans);
    this.emit();
    return result;
  }

  floorPlanPlace(id: string, deviceID: string, x: unknown, y: unknown): void {
    this.findDevice(deviceID);
    this.floorPlan((f) => f.place(id, deviceID, x, y));
  }

  /** Local partner draft for a DreamView main light, shape-checked like a restored backup. Never sent. */
  saveDreamViewDraft(lightID: string, input: unknown): void {
    const light = this.findDevice(lightID);
    let draft;
    try { draft = dreamViewDrafts({ [lightID]: input })[lightID]!; } catch { throw new LumaError('Screen areas are 1–10, for at most 64 lights.'); }
    const limit = dreamViewMemberLimit(light.sku);
    if (limit !== undefined && draft.members.length > limit) throw new LumaError(`${light.sku} groups hold up to ${limit} lights.`);
    const ids = draft.members.map((m) => m.deviceID);
    if (new Set(ids).size !== ids.length || ids.includes(lightID) || draft.members.some((m) => m.areas.length === 0)) throw new LumaError('Each partner light needs at least one screen area.');
    for (const m of draft.members) { this.findDevice(m.deviceID); m.areas = [...new Set(m.areas)].sort((a, b) => a - b); }
    const drafts = { ...(this.home.dreamViewDrafts ?? {}) };
    if (draft.members.length) drafts[lightID] = draft; else delete drafts[lightID];
    this.home.dreamViewDrafts = drafts;
    this.schedulePersist(); this.emit();
  }

  private hasSecret(name: string): boolean {
    try { return this.options.secrets?.read(name) !== undefined; } catch { return false; }
  }

  // ---------- persistence ----------

  private schedulePersist(): void {
    if (this.demo || !this.options.storage || !this.canSave) return;
    clearTimeout(this.persistTimer);
    this.persistTimer = setTimeout(() => this.persistNow(), 250);
  }

  persistNow(): void {
    clearTimeout(this.persistTimer);
    this.persistTimer = undefined;
    if (this.demo || !this.options.storage || !this.canSave) return;
    try { this.options.storage.save(this.home); } catch (error) { this.log(`Could not save your home: ${message(error)}`, true); }
  }

  // ---------- cloud & LAN ----------

  private requireReal(action: string): void {
    if (this.demo) throw new LumaError(`Demo mode: ${action} is disabled. Sample lights only.`);
  }

  private requireSecrets(): SecretStore {
    const secrets = this.options.secrets;
    if (!secrets?.available) throw new LumaError('Secure storage (Windows DPAPI or a Linux keyring) is unavailable, so Luma will not store credentials. Nothing was saved.');
    return secrets;
  }

  async connect(apiKey: string): Promise<void> {
    this.requireReal('connecting a Govee account');
    const key = typeof apiKey === 'string' ? apiKey.trim() : '';
    if (!/^[\x21-\x7e]{8,256}$/.test(key)) throw new LumaError('Enter your Govee API key (visible characters only).');
    const secrets = this.requireSecrets();
    await this.withBusy(async () => {
      const generation = this.cloudGeneration;
      const client = new GoveeCloud(key, this.options.cloudOptions);
      const found = await client.devices();
      this.ensureCurrent(generation);
      secrets.write(API_KEY, key);
      this.cloud = client;
      this.mergeCloudDevices(found);
      this.log(`Connected Govee cloud. Found ${found.length} lights.`);
      void this.refreshAll();
    });
  }

  /** Reconnect with the saved encrypted key (on launch or from Settings). */
  async reconnect(): Promise<void> {
    this.requireReal('reconnecting');
    const key = this.requireSecrets().read(API_KEY);
    if (!key) throw new LumaError('No saved API key. Enter one to connect.');
    await this.withBusy(async () => {
      const generation = this.cloudGeneration;
      const client = new GoveeCloud(key, this.options.cloudOptions);
      const found = await client.devices();
      this.ensureCurrent(generation);
      this.cloud = client;
      this.mergeCloudDevices(found);
      this.log(`Reconnected Govee cloud. Found ${found.length} lights.`);
      void this.refreshAll();
    });
  }

  disconnect(): void {
    this.requireReal('disconnecting');
    this.cloudGeneration++;
    this.cloudAbort.abort(); // writes still waiting in the old client's paced queue are not sent
    this.cloudAbort = new AbortController();
    this.cloud = undefined;
    this.options.secrets?.delete(API_KEY);
    this.log('Cloud disconnected and the saved API key was removed.');
  }

  private ensureCurrent(generation: number): void {
    if (generation !== this.cloudGeneration) throw new LumaError('Connection cancelled: the cloud was disconnected.');
  }

  private async withBusy(work: () => Promise<void>): Promise<void> {
    if (this.busy) throw new LumaError('Already working on it.');
    this.busy = true; this.emit();
    try { await work(); }
    catch (error) {
      const text = message(error);
      this.log(`Cloud connection failed: ${text}`, true);
      throw new LumaError(text);
    } finally { this.busy = false; this.emit(); }
  }

  private mergeCloudDevices(found: LightDevice[]): void {
    for (const incoming of found) {
      const existing = this.home.devices.find((d) => d.id.toLowerCase() === incoming.id.toLowerCase());
      if (existing) {
        existing.sku = incoming.sku;
        existing.name = existing.customName ?? incoming.name; // a Luma rename survives cloud refreshes
        if (incoming.deviceType) existing.deviceType = incoming.deviceType; else delete existing.deviceType;
        existing.capabilities = mergeCapabilities(existing.capabilities, incoming.capabilities);
      } else {
        this.home.devices.push({ ...incoming, room: 'Unassigned', capabilities: incoming.capabilities });
      }
    }
    this.persistNow();
    this.emit();
  }

  private async refreshAll(): Promise<void> {
    const generation = this.cloudGeneration;
    for (const device of [...this.home.devices]) {
      if (generation !== this.cloudGeneration) return;
      try { await this.refresh(device.id, true); } catch (error) { this.log(`Could not read ${device.name}: ${message(error)}`); }
    }
  }

  async refresh(deviceID: string, quiet = false): Promise<void> {
    const device = this.findDevice(deviceID);
    if (device.isDemo) { if (!quiet) this.log('Demo state refreshed.'); return; }
    if (device.ip && this.lan?.running) { this.lan.requestStatus(device.ip); return; }
    if (!this.cloud) throw new LumaError('Connect cloud or discover LAN lights to refresh state.');
    const revision = this.engine.revision(deviceID), generation = this.cloudGeneration;
    const state = this.absorb(deviceID, await this.cloud.state(device));
    this.ensureCurrent(generation);
    this.engine.report(deviceID, state, { revision });
  }

  /** Keeps readings and the DreamView flag from a cloud state read (the engine tracks basic controls only). */
  private absorb(deviceID: string, state: DeviceState): DeviceState {
    const { readings, dreamView, ...basic } = state;
    const device = this.home.devices.find((d) => d.id === deviceID);
    if (state.online === false) this.readings.delete(deviceID); // offline values are historical
    else if (readings) this.readings.set(deviceID, readings);
    if (device && dreamView !== undefined && state.online !== false) device.dreamView = dreamView;
    this.emit();
    return basic;
  }

  async discover(): Promise<void> {
    this.requireReal('LAN discovery');
    if (this.scanning) return;
    await this.ensureLan();
    this.lan!.discover();
    this.scanning = true;
    this.log('Scanning Wi-Fi for Govee lights with LAN Control enabled…');
    clearTimeout(this.scanTimer);
    this.scanTimer = setTimeout(() => {
      this.scanning = false;
      const count = this.home.devices.filter((d) => d.ip).length;
      this.log(`LAN scan complete. ${count} LAN light${count === 1 ? '' : 's'} known.`);
    }, 5000);
  }

  private async ensureLan(): Promise<void> {
    if (!this.lan) {
      const handlers = { onPacket: (p: LanPacket) => this.onLanPacket(p), onError: (text: string) => this.log(text, true) };
      this.lan = this.options.createLan ? this.options.createLan(handlers) : new GoveeLan(handlers);
      this.lanSeen.clear();
    }
    await this.lan.start();
  }

  private onLanPacket(packet: LanPacket): void {
    this.lanSeen.add(packet.ip);
    if (packet.kind === 'discovery') {
      let device = this.home.devices.find((d) => d.id.toLowerCase() === packet.id.toLowerCase());
      for (const other of this.home.devices) if (other !== device && other.ip === packet.ip) other.ip = undefined;
      if (!device) {
        device = { id: packet.id, sku: packet.sku, name: `Govee ${packet.sku}`, room: 'Unassigned', capabilities: [] };
        this.home.devices.push(device);
        this.log(`Found ${device.name} on the LAN.`);
      }
      device.ip = packet.ip;
      device.online = true;
      device.lastSeen = Date.now();
      this.schedulePersist();
      this.emit();
      return;
    }
    const device = this.home.devices.find((d) => d.ip === packet.ip);
    if (!device) return;
    const s = packet.status;
    this.engine.report(device.id, { power: s.power, brightness: s.brightness, rgb: s.rgb, colorTemperature: s.kelvin, online: true, lastSeen: Date.now() }, { lan: true });
  }

  /** One write. LAN only for basic controls in the LAN range; everything else is cloud. Never retried. */
  private async transmit(device: LightDevice, command: CapabilityCommand, signal: AbortSignal): Promise<{ route: string; confirmed?: boolean }> {
    // Any ordinary write takes the light out of a running doorbell alert; it is not restored.
    this.doorbell.yield(device.id);
    if (device.isDemo) return { route: 'Demo', confirmed: true };
    if (this.demo) throw new LumaError('Demo mode never controls real lights.');
    if (this.lanOnly.has(command) && !(device.ip && this.lan?.running && lanEligible(command))) {
      throw new LumaError('LAN is unavailable, so this light was not restored (Screen Sync never uses cloud).');
    }
    if (device.ip && this.lan?.running && lanEligible(command)) {
      await this.lan.control(device.ip, command);
      try { this.lan.requestStatus(device.ip); } catch { /* confirmation reads retry later */ }
      return { route: 'LAN sent; awaiting status' };
    }
    if (!this.cloud) throw new LumaError(`Connect Govee cloud to use ${command.instance} on this light.`);
    await this.cloud.control(device, command, AbortSignal.any([signal, this.cloudAbort.signal]));
    return { route: 'Cloud accepted' };
  }

  async control(deviceID: string, command: CapabilityCommand): Promise<void> {
    // Manual control takes a light out of Screen Sync first, after its last stream datagram.
    if (this.sync.holds(deviceID)) {
      validateCommand(command, this.findDevice(deviceID));
      await this.sync.exclude(deviceID);
    }
    await this.engine.submit(deviceID, command, { coalesce: true });
    // DreamView state is cloud-only and has no confirmation read; check it once it has had time to start.
    if (command.instance === 'dreamViewToggle' && this.cloud) setTimeout(() => void this.refresh(deviceID, true).catch(() => {}), 3000).unref?.();
  }

  /** Ordered writes to one light, never coalesced (each segment group is its own command). All validated before the first send. */
  async controlBatch(deviceID: string, commands: unknown): Promise<void> {
    const device = this.findDevice(deviceID);
    if (!Array.isArray(commands) || commands.length === 0 || commands.length > 64) throw new LumaError('Send 1–64 commands at a time.');
    for (const c of commands) validateCommand(c as CapabilityCommand, device);
    if (this.sync.holds(deviceID)) await this.sync.exclude(deviceID);
    // Enqueued synchronously in order; the engine sends them in order per light.
    await Promise.all((commands as CapabilityCommand[]).map((c) => this.engine.submit(deviceID, c)));
  }

  /** Room brightness or white. Each light gets the value clamped to its own advertised range; non-lights are skipped. */
  async roomAction(room: unknown, action: unknown): Promise<void> {
    if (typeof room !== 'string' || !room || room.length > 160 || !isObject(action)) throw new LumaError('Invalid room action.');
    const keys = Object.keys(action);
    if (keys.length !== 1 || !['brightness', 'kelvin'].includes(keys[0]!)) throw new LumaError('Choose brightness or white for the room.');
    const lights = this.home.devices.filter((d) => isLight(d) && d.room === room);
    const writes: Array<[string, CapabilityCommand]> = [];
    if (action.brightness !== undefined) {
      const value = safeInt(action.brightness, 1, 100);
      if (value === undefined) throw new LumaError('Brightness must be an integer 1–100.');
      for (const d of lights) if (supports(d, 'brightness')) { const [lo, hi] = brightnessRange(d); writes.push([d.id, brightness(Math.min(hi, Math.max(lo, value)))]); }
    } else {
      const value = safeInt(action.kelvin, 1000, 10000);
      if (value === undefined) throw new LumaError('White must be an integer 1000–10000 K.');
      for (const d of lights) if (supports(d, 'colorTemperatureK')) { const [lo, hi] = whiteRange(d); writes.push([d.id, kelvin(Math.min(hi, Math.max(lo, value)))]); }
    }
    if (writes.length === 0) throw new LumaError(`No lights in ${room} support ${action.brightness !== undefined ? 'brightness' : 'white'}.`);
    await Promise.allSettled(writes.map(([id, c]) => (this.sync.holds(id) ? this.control(id, c) : this.engine.submit(id, c, { coalesce: true }))));
  }

  /** Doorbell alert pulse or restore: one direct write, like a Screen Sync datagram, but cloud is allowed. */
  private async alertWrite(deviceID: string, command: CapabilityCommand): Promise<void> {
    const device = this.findDevice(deviceID);
    validateCommand(command, device);
    if (device.isDemo) { applyDemo(device, command); this.emit(); return; }
    if (this.demo) throw new LumaError('Demo mode never controls real lights.');
    if (device.ip && this.lan?.running && this.lanSeen.has(device.ip) && lanEligible(command)) { await this.lan.control(device.ip, command); return; }
    if (!this.cloud) throw new LumaError('No LAN or cloud route for this light.');
    await this.cloud.control(device, command, this.cloudAbort.signal);
  }

  /** One fresh state read for the doorbell alert. LAN waits up to 1.5 s for the status reply. */
  private async freshRead(device: LightDevice): Promise<boolean> {
    if (device.ip && this.lan?.running && this.lanSeen.has(device.ip)) {
      const started = Date.now(), before = device.lastSeen ?? 0;
      this.lan.requestStatus(device.ip);
      for (let i = 0; i < 30; i++) {
        const seen = this.home.devices.find((d) => d.id === device.id)?.lastSeen ?? 0;
        if (seen > before && seen >= started) return true;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      return false;
    }
    if (!this.cloud) return false;
    const revision = this.engine.revision(device.id);
    const state = await Promise.race([this.cloud.state(device), new Promise<never>((_, reject) => setTimeout(() => reject(new LumaError('timed out')), 3000).unref?.())]);
    this.engine.report(device.id, this.absorb(device.id, state), { revision });
    return true;
  }

  /** One Screen Sync datagram: LAN only, no status request, no cloud, IP from confirmed records only. */
  private async streamWrite(deviceID: string, field: StreamField, value: number): Promise<void> {
    const device = this.findDevice(deviceID);
    if (device.isDemo) return;
    if (this.demo) throw new LumaError('Demo mode never controls real lights.');
    if (!device.ip || !this.lan?.running || !this.lanSeen.has(device.ip)) throw new LumaError('LAN is unavailable for this light.');
    await this.lan.control(device.ip, field === 'colorRgb' ? rgb(value) : brightness(value));
  }

  async loadEffects(deviceID: string, diy: boolean): Promise<void> {
    const device = this.findDevice(deviceID);
    const found = device.isDemo ? demoEffects(diy) : await (this.cloud ?? fail('Connect Govee cloud to load device effects.')).scenes(device, diy);
    device.capabilities = mergeCapabilities(device.capabilities, found);
    this.schedulePersist();
    this.log(`Loaded ${diy ? 'DIY' : 'dynamic'} effects for ${device.name}.`);
  }

  assignRoom(deviceID: string, room: string): void {
    const device = this.findDevice(deviceID);
    const trimmed = typeof room === 'string' ? room.trim().slice(0, 40) : '';
    device.room = trimmed || 'Unassigned';
    this.schedulePersist(); this.emit();
  }

  renameDevice(deviceID: string, name: string): void {
    const device = this.findDevice(deviceID);
    const trimmed = typeof name === 'string' ? name.trim().slice(0, 64) : '';
    if (!trimmed) throw new LumaError('Enter a name.');
    device.name = trimmed;
    device.customName = trimmed;
    this.schedulePersist(); this.emit();
  }

  private findDevice(id: string): LightDevice {
    const device = this.home.devices.find((d) => d.id === id);
    if (!device) throw new LumaError('Light not found.', 404);
    return device;
  }

  // ---------- scenes ----------

  saveScene(input: unknown): LightScene {
    const scene = decodeScene(input, this.home.devices);
    // Shared scenes need UUIDs so the Mac and iPhone can read them.
    if (this.scheduleSync.role !== 'off' && !canonicalID(scene.id)) scene.id = randomUUID();
    const index = this.home.scenes.findIndex((s) => s.id === scene.id);
    if (index >= 0) this.home.scenes[index] = scene; else this.home.scenes.push(scene);
    this.schedulePersist();
    this.log(`Saved scene: ${scene.name}.`);
    this.scheduleSync.localChange('scene', scene.id);
    return scene;
  }

  deleteScene(sceneID: string): void {
    this.home.scenes = this.home.scenes.filter((s) => s.id !== sceneID);
    this.home.schedules = this.home.schedules.filter((s) => s.sceneID !== sceneID);
    this.schedulePersist(); this.emit();
    this.scheduleSync.localChange('scene', sceneID);
  }

  /** Builds steps from confirmed state (never from pending intents). */
  captureScene(name: string, icon: string, deviceIDs: string[]): LightScene {
    if (!Array.isArray(deviceIDs) || deviceIDs.length === 0) throw new LumaError('Choose at least one light.');
    const steps = this.snapshotSteps(deviceIDs);
    if (steps.length === 0) throw new LumaError('Those lights have no known state to capture yet. Refresh them first.');
    return this.saveScene({ id: randomUUID(), name, icon, steps });
  }

  /** Steps that put lights back to their last confirmed state. Unknown power is skipped. */
  private snapshotSteps(deviceIDs: string[]): SceneStep[] {
    const steps: SceneStep[] = [];
    for (const device of this.home.devices.filter((d) => deviceIDs.includes(d.id))) {
      const add = (command: CapabilityCommand) => steps.push({ id: randomUUID(), deviceID: device.id, command, delayMilliseconds: 0 });
      if (device.power !== undefined && supports(device, 'powerSwitch')) add(power(device.power));
      if (device.power === false) continue;
      if (device.brightness && device.brightness > 0 && supports(device, 'brightness')) add(brightness(device.brightness));
      if (device.colorTemperature && device.colorTemperature > 0 && supports(device, 'colorTemperatureK')) add(kelvin(device.colorTemperature));
      else if (device.rgb !== undefined && supports(device, 'colorRgb')) add(rgb(device.rgb));
    }
    return steps;
  }

  validateSceneJSON(text: string): LightScene {
    if (typeof text !== 'string' || text.length > 256 * 1024) throw new LumaError('Scene JSON is too large.');
    let parsed: unknown;
    try { parsed = JSON.parse(text); } catch { throw new LumaError("That JSON isn't a valid scene."); }
    return decodeScene(parsed, this.home.devices);
  }

  exportScene(sceneID: string): { name: string; json: string } {
    const scene = this.home.scenes.find((s) => s.id === sceneID);
    if (!scene) throw new LumaError('Scene not found.', 404);
    return { name: scene.name, json: JSON.stringify(scene, null, 2) };
  }

  importScene(text: string): LightScene {
    const scene = this.validateSceneJSON(text);
    if (this.home.scenes.some((s) => s.id === scene.id)) scene.id = randomUUID();
    return this.saveScene(scene);
  }

  /** Validates the whole scene against current lights before the first command. */
  runScene(scene: LightScene, saveRestorePoint = true): string {
    validateScene(scene, this.home.devices);
    // Scenes, schedules and webhooks never fight the stream: the whole run is refused before its first write.
    if (scene.steps.some((st) => this.sync.holds(st.deviceID))) throw new LumaError('Screen Sync is using one of these lights. Stop it first.', 409);
    // Taken before any step is sent. Effects, segments and DreamView aren't undone, only power/brightness/color/white.
    const steps = saveRestorePoint ? this.snapshotSteps([...new Set(scene.steps.map((st) => st.deviceID))]) : [];
    const runID = this.runner.start(scene);
    if (saveRestorePoint) this.restorePoint = steps.length ? { id: randomUUID(), name: `Before ${scene.name}`.slice(0, 80), icon: 'sparkles', steps } : undefined;
    this.emit();
    return runID;
  }

  /** Puts the last scene's lights back. One level: restoring doesn't save a new point. */
  restoreBeforeScene(): string {
    const point = this.restorePoint;
    if (!point) throw new LumaError('There is nothing to restore.');
    const runID = this.runScene(point, false);
    this.restorePoint = undefined;
    this.emit();
    return runID;
  }

  runSavedScene(sceneID: string): string {
    const scene = this.home.scenes.find((s) => s.id === sceneID);
    if (!scene) throw new LumaError('Scene not found.', 404);
    return this.runScene(scene);
  }

  stopScene(): void { this.runner.stop(); }

  scenes(): LightScene[] { return this.home.scenes; }

  /** Applies one basic command to every device in a set (tray "All on/off", room actions). */
  async quickAction(deviceIDs: string[], command: CapabilityCommand): Promise<void> {
    await Promise.allSettled(deviceIDs.map((id) => (this.sync.holds(id) ? this.control(id, command) : this.engine.submit(id, command, { coalesce: true }))));
  }

  // ---------- Govee Home account (read-only) ----------

  private goveeHomeView(): GoveeHomeView {
    const { entries, ...view } = this.goveeHome;
    const available = !this.demo && (this.options.secrets?.available ?? false);
    const firmware: Record<string, string> = {};
    for (const e of entries) {
      const d = e.firmware ? this.home.devices.find((x) => x.id.toLowerCase() === e.device.toLowerCase() && x.sku.toLowerCase() === e.sku.toLowerCase()) : undefined;
      if (d) firmware[d.id] = e.firmware!;
    }
    return { ...view, available, signedIn: available && this.hasSecret(HOME_TOKEN), conflicts: this.goveeConflicts(), firmware };
  }

  private goveeConflicts() {
    // Automations name lights by their Govee name, which a Luma rename replaces in `name`.
    const names = new Map(this.goveeHome.entries.map((e) => [e.device.toLowerCase(), e.name]));
    const devices = this.home.devices.map((d) => ({ ...d, goveeName: names.get(d.id.toLowerCase()) ?? d.name }));
    return findConflicts(this.goveeHome.automations, this.home.schedules, this.home.scenes, devices);
  }

  private account(): GoveeAccount {
    const secrets = this.requireSecrets();
    let clientId = secrets.read(CLIENT_ID);
    if (!clientId) { clientId = randomBytes(16).toString('hex'); secrets.write(CLIENT_ID, clientId); }
    return new GoveeAccount(clientId, { fetch: this.options.accountFetch });
  }

  /** Read-only sign-in. The password is sent once to app2.govee.com and never stored; the session token is kept encrypted. */
  async goveeSignIn(email: unknown, password: unknown, code?: unknown): Promise<'needsCode' | 'signedIn'> {
    this.requireReal('Govee Home sign-in');
    if (typeof email !== 'string' || !/^[^\s@]{1,128}@[^\s@]{1,128}$/.test(email.trim())) throw new LumaError('Enter the email for your Govee Home account.');
    if (typeof password !== 'string' || password.length === 0 || password.length > 256) throw new LumaError('Enter your Govee Home password.');
    const codeText = typeof code === 'string' ? code.trim() : '';
    if (codeText && !/^[0-9A-Za-z]{4,10}$/.test(codeText)) throw new LumaError('Enter the code from Govee’s email.');
    if (this.goveeHome.busy) throw new LumaError('Already working on it.');
    const secrets = this.requireSecrets();
    this.goveeHome.busy = true; this.emit();
    try {
      const result = await this.account().login(email.trim(), password, codeText || undefined);
      if (result.kind === 'needsCode') {
        this.goveeHome.awaitingCode = true;
        this.log('Govee emailed a sign-in code. Enter it to finish signing in.');
        return 'needsCode';
      }
      secrets.write(HOME_TOKEN, result.token);
      this.goveeHome.awaitingCode = false;
      this.log('Signed in to Govee Home (read-only).');
    } finally { this.goveeHome.busy = false; this.emit(); }
    await this.goveeImport();
    return 'signedIn';
  }

  /** Reads rooms (required), then control groups and automations (best effort) with the saved session. */
  async goveeImport(): Promise<void> {
    this.requireReal('Govee Home import');
    const token = this.requireSecrets().read(HOME_TOKEN);
    if (!token) throw new LumaError('Sign in to Govee Home first.');
    if (this.goveeHome.busy) throw new LumaError('Already working on it.');
    this.goveeHome.busy = true; this.emit();
    const account = this.account();
    try {
      const entries = parseDeviceList(await account.deviceList(token));
      const unavailable: string[] = [];
      const extra = async <T>(label: string, read: () => Promise<T[]>): Promise<T[]> => {
        try { return await read(); } catch (error) { if (error instanceof SessionExpired) throw error; unavailable.push(label); return []; }
      };
      const groups = await extra('control groups', async () => parseGroups(await account.groups(token)));
      const automations = await extra('automations', async () => parseAutomations(await account.automations(token)));
      this.goveeHome = { ...this.goveeHome, entries, groups, automations, unavailable, importedAt: Date.now(), plan: planRooms(entries, this.home.devices) };
      this.log(`Read Govee Home: ${entries.length} devices, ${groups.length} groups, ${automations.length} automations.${unavailable.length ? ` Couldn't read ${unavailable.join(' or ')}.` : ''}`);
    } catch (error) {
      if (error instanceof SessionExpired) { this.options.secrets?.delete(HOME_TOKEN); this.goveeHome = { ...this.goveeHome, plan: undefined }; }
      this.log(`Govee Home import failed: ${message(error)}`, true);
      throw error;
    } finally { this.goveeHome.busy = false; this.emit(); }
  }

  /** Applies the chosen Govee Home rooms. Only lights in the current plan can change. */
  goveeApplyRooms(deviceIDs: unknown): void {
    const plan = this.goveeHome.plan;
    if (!plan) throw new LumaError('Import from Govee Home first.');
    if (!Array.isArray(deviceIDs) || deviceIDs.length > 1000) throw new LumaError('Invalid selection.');
    const chosen = new Set(deviceIDs.filter((id): id is string => typeof id === 'string'));
    let applied = 0;
    for (const change of plan.changes.filter((c) => chosen.has(c.deviceID))) {
      const device = this.home.devices.find((d) => d.id === change.deviceID);
      if (device) { device.room = change.goveeRoom.slice(0, 40); applied++; }
    }
    this.goveeHome.plan = planRooms(this.goveeHome.entries, this.home.devices);
    this.schedulePersist();
    this.log(`Imported Govee Home rooms for ${applied} light${applied === 1 ? '' : 's'}.`);
  }

  goveeSignOut(): void {
    this.requireReal('Govee Home sign-out');
    this.options.secrets?.delete(HOME_TOKEN);
    this.goveeHome = { awaitingCode: false, busy: false, groups: [], automations: [], unavailable: [], entries: [] };
    this.log('Signed out of Govee Home and removed the saved session.');
  }

  // ---------- backup ----------

  /** Scenes, schedules, names and rooms in the native backup format. No keys, tokens, IPs or webhook settings. */
  exportBackup(): string {
    this.requireReal('backup');
    return encodeBackup(this.home);
  }

  /** Replaces scenes and schedules; names and rooms apply to known lights. The current home is saved beside home.json first. */
  restoreBackup(text: string): BackupResult {
    this.requireReal('restore');
    this.scheduleSync.assertMayReplaceAll();
    if (!this.canSave) throw new LumaError('Your saved home could not be read, so restore is disabled to keep that file untouched.');
    if (this.runner.runningSceneID) throw new LumaError('Stop the running scene before restoring.');
    const backup = decodeBackup(text);
    try { this.options.storage?.saveCopy(this.home, 'home-before-restore.json'); }
    catch (error) { throw new LumaError(`Could not save a safety copy, so nothing was restored: ${message(error)}`); }
    const result = applyBackup(this.home, backup);
    this.restorePoint = undefined;
    this.persistNow();
    this.log(`Restored backup: ${result.scenes} scenes, ${result.schedules} schedules, ${result.lightsUpdated} lights.${result.lightsNotFound ? ` ${result.lightsNotFound} lights in the backup aren't connected here.` : ''}`);
    return result;
  }

  compatibilityReport(): string {
    return compatibilityReport(this.home.devices, `Luma ${this.options.version} for ${process.platform === 'win32' ? 'Windows' : process.platform === 'linux' ? 'Linux' : process.platform} (Electron)`);
  }

  // ---------- schedules ----------

  saveSchedule(input: unknown): void {
    const schedule = validateSchedule(input, this.home.scenes.map((s) => s.id));
    const index = this.home.schedules.findIndex((s) => s.id === schedule.id);
    if (index >= 0) this.home.schedules[index] = { ...schedule, lastRunMinute: this.home.schedules[index]!.lastRunMinute };
    else this.home.schedules.push(schedule);
    this.schedulePersist(); this.emit();
    this.scheduleSync.localChange('schedule', schedule.id);
  }

  deleteSchedule(id: string): void {
    this.home.schedules = this.home.schedules.filter((s) => s.id !== id);
    this.schedulePersist(); this.emit();
    this.scheduleSync.localChange('schedule', id);
  }

  tickSchedules(now = new Date()): void {
    // Shared schedules run only on the selected computer; a paired one never runs them.
    if (this.scheduleSync.tick(now)) return;
    for (const schedule of this.home.schedules) {
      if (!shouldRun(schedule, now)) continue;
      schedule.lastRunMinute = minuteKey(now);
      this.schedulePersist();
      const scene = this.home.scenes.find((s) => s.id === schedule.sceneID);
      if (!scene) { this.log('A scheduled scene no longer exists.', true); continue; }
      try { this.runScene(scene); } catch (error) { this.log(`Schedule skipped: ${message(error)}`, true); }
    }
  }

  // ---------- webhook server ----------

  setWebhookConfig(port: unknown, allowLAN: unknown): void {
    this.requireReal('the webhook server');
    if (this.server.running) throw new LumaError('Stop the server before changing its settings.');
    const p = safeInt(port, 1024, 65535);
    if (p === undefined) throw new LumaError('Port must be a whole number from 1024 to 65535.');
    this.home.webhookPort = p;
    this.home.allowLAN = allowLAN === true;
    this.schedulePersist(); this.emit();
  }

  async startWebhook(): Promise<void> {
    this.requireReal('the webhook server');
    const secrets = this.requireSecrets();
    if (!this.token) {
      this.token = secrets.read(WEBHOOK_TOKEN);
      if (!this.token) { this.token = newToken(); secrets.write(WEBHOOK_TOKEN, this.token); }
    }
    try {
      const identity = loadWebhookIdentity(secrets, false, new Date(), webhookSans(this.home.allowLAN));
      const { port, host } = await this.server.start({ tls: identity, port: this.home.webhookPort, allowLAN: this.home.allowLAN, token: this.token, handler: createApiHandler(this.apiHost()) });
      this.webhookIdentity = identity;
      this.webhookStatus = `Listening on ${host === '0.0.0.0' ? 'all network interfaces (LAN)' : 'this PC only'} · port ${port}`;
      this.log(`Webhook server started on port ${port}.`);
    } catch (error) {
      this.webhookStatus = `Not running: ${message(error)}`;
      this.log(this.webhookStatus, true);
      throw error;
    }
  }

  webhookCertificate(): string {
    if (!this.webhookIdentity) throw new LumaError('Start the server to access its certificate.');
    return this.webhookIdentity.cert;
  }

  async stopWebhook(): Promise<void> {
    await this.server.stop();
    this.webhookStatus = 'Stopped';
    this.log('Webhook server stopped.');
  }

  async rotateToken(): Promise<void> {
    this.requireReal('the webhook server');
    const secrets = this.requireSecrets();
    if (this.server.running) await this.stopWebhook();
    const token = newToken();
    secrets.write(WEBHOOK_TOKEN, token); // store first so memory and storage never disagree
    this.token = token;
    this.log('Webhook token rotated. Update your callers, then start the server.');
  }

  copyToken(): void {
    this.requireReal('the webhook server');
    const token = this.token ?? this.requireSecrets().read(WEBHOOK_TOKEN);
    if (!token) throw new LumaError('Start the server once to create a token.');
    this.token = token;
    this.options.copyToClipboard?.(token);
    this.log('Webhook token copied to the clipboard.');
  }

  private apiHost() {
    return {
      demo: this.demo,
      devices: () => this.confirmedDevices(),
      scenes: () => this.home.scenes,
      runs: () => this.runner.runs,
      runScene: (scene: LightScene) => this.runScene(scene),
      doorbell: (method: string, rest: string[], body: Buffer) => this.doorbell.api(method, rest, body),
    };
  }

  async shutdown(): Promise<void> {
    this.bluetooth.disconnect(undefined);
    await this.doorbell.shutdown();
    clearInterval(this.scheduleTimer);
    await this.scheduleSync.stop();
    clearTimeout(this.scanTimer);
    await this.sync.stop('Luma is quitting.');
    this.runner.stop();
    this.engine.stop();
    this.lan?.stop();
    await this.server.stop();
    this.persistNow();
  }

  /** Schedules for the tray / renderer, and light IDs by room. */
  roomDeviceIDs(room?: string): string[] {
    return this.home.devices.filter((d) => isLight(d) && (room === undefined || d.room === room)).map((d) => d.id);
  }

  get hasSavedHome(): boolean { return this.home.devices.length > 0; }
  get savedSchedules(): SceneSchedule[] { return this.home.schedules; }
}

function fail(text: string): never { throw new LumaError(text); }

function applyDemo(device: LightDevice, command: CapabilityCommand): void {
  const n = command.value as number;
  if (command.instance === 'powerSwitch') device.power = n === 1;
  else if (command.instance === 'brightness') device.brightness = n;
  else if (command.instance === 'colorRgb') { device.rgb = n; device.colorTemperature = 0; }
  else if (command.instance === 'colorTemperatureK') device.colorTemperature = n;
}

function newToken(): string { return `lm_${randomBytes(32).toString('base64url')}`; }

export function lanEligible(command: CapabilityCommand): boolean {
  if (!(LAN_INSTANCES as readonly string[]).includes(command.instance)) return false;
  if (command.instance === 'colorTemperatureK') return safeInt(command.value, 2000, 9000) !== undefined;
  return true;
}

/** Merges capabilities by type+instance, keeping previously loaded ENUM options. */
export function mergeCapabilities(existing: Capability[], incoming: Capability[]): Capability[] {
  const result = [...existing];
  for (const cap of incoming) {
    const index = result.findIndex((c) => c.type === cap.type && c.instance === cap.instance);
    if (index < 0) { result.push(cap); continue; }
    const old = result[index]!;
    const oldOptions = isObject(old.parameters) && Array.isArray(old.parameters.options) ? old.parameters.options : undefined;
    const newOptions = isObject(cap.parameters) && Array.isArray(cap.parameters.options) ? cap.parameters.options : undefined;
    if (oldOptions && newOptions && isObject(cap.parameters)) {
      const options = [...newOptions];
      for (const o of oldOptions) if (!options.some((n) => JSON.stringify(n) === JSON.stringify(o))) options.push(o);
      result[index] = { ...cap, parameters: { ...cap.parameters, options } };
    } else result[index] = cap;
  }
  return result;
}

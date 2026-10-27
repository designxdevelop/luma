import { loadWebhookIdentity, webhookSans, type WebhookIdentity } from '../core/certificate';
// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// The app model in the main process. Electron-free so the whole journey is testable
// with fakes. Confirmed state lives in `home.devices`; requested values live only in
// the ControlEngine overlay and are never persisted or served by the webhook API.

import { randomBytes, randomUUID } from 'node:crypto';
import type { ActivityEntry, AppSnapshot, Capability, CapabilityCommand, LightDevice, LightScene, SavedHome, SceneSchedule, SceneStep } from '../shared/types';
import { LAN_INSTANCES, LumaError, decodeScene, isObject, message, power, brightness, rgb, kelvin, safeInt, supports, validateCommand, validateScene } from '../core/model';
import { ControlEngine, type ControlOptions, type ControlTransport } from '../core/controls';
import { SceneRunner, minuteKey, shouldRun, validateSchedule } from '../core/automation';
import { GoveeCloud, type CloudOptions } from '../core/cloud';
import { GoveeLan, type LanPacket } from '../core/lan';
import { WebhookServer } from '../core/http';
import { createApiHandler } from '../core/api';
import { HomeStorage, emptyHome, type SecretStore } from './storage';
import { demoDevices, demoEffects, demoScenes } from './demo';
import { REGIONS } from '../shared/sync-math';
import { SyncController } from './sync';
import type { StreamField } from '../core/stream';

const API_KEY = 'govee-api-key';
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
  readonly sync: SyncController;

  constructor(private readonly options: HomeOptions) {
    this.demo = options.demo;
    const transport: ControlTransport = {
      send: (device, command, signal) => this.transmit(device, command, signal),
      read: async (device, command) => {
        if (device.isDemo) return undefined;
        // Confirm over the route that carried the write: e.g. 1500 K goes by cloud even on a LAN light.
        if (device.ip && this.lan?.running && (!command || lanEligible(command))) { this.lan.requestStatus(device.ip); return undefined; }
        if (this.cloud) return this.cloud.state(device);
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
      devices: () => this.home.devices,
      hasPending: (id) => this.engine.pendingFor(id).length > 0,
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
      this.log('Demo home loaded. These are sample lights; nothing real is controlled, and changes are not saved.');
    } else if (options.storage) {
      try { this.home = options.storage.load(); }
      catch {
        this.canSave = false;
        this.log(`Your saved home could not be read. It was left untouched at ${options.storage.file}.`, true);
      }
    }
    if (this.home.syncSettings) this.sync.setSettings(this.home.syncSettings);
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
    };
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
        existing.name = incoming.name;
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
    const state = await this.cloud.state(device);
    this.ensureCurrent(generation);
    this.engine.report(deviceID, state, { revision });
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
    const index = this.home.scenes.findIndex((s) => s.id === scene.id);
    if (index >= 0) this.home.scenes[index] = scene; else this.home.scenes.push(scene);
    this.schedulePersist();
    this.log(`Saved scene: ${scene.name}.`);
    return scene;
  }

  deleteScene(sceneID: string): void {
    this.home.scenes = this.home.scenes.filter((s) => s.id !== sceneID);
    this.home.schedules = this.home.schedules.filter((s) => s.sceneID !== sceneID);
    this.schedulePersist(); this.emit();
  }

  /** Builds steps from confirmed state (never from pending intents). */
  captureScene(name: string, icon: string, deviceIDs: string[]): LightScene {
    if (!Array.isArray(deviceIDs) || deviceIDs.length === 0) throw new LumaError('Choose at least one light.');
    const steps: SceneStep[] = [];
    for (const device of this.home.devices.filter((d) => deviceIDs.includes(d.id))) {
      const add = (command: CapabilityCommand) => steps.push({ id: randomUUID(), deviceID: device.id, command, delayMilliseconds: 0 });
      if (device.power !== undefined && supports(device, 'powerSwitch')) add(power(device.power));
      if (device.power === false) continue;
      if (device.brightness && device.brightness > 0 && supports(device, 'brightness')) add(brightness(device.brightness));
      if (device.colorTemperature && device.colorTemperature > 0 && supports(device, 'colorTemperatureK')) add(kelvin(device.colorTemperature));
      else if (device.rgb !== undefined && supports(device, 'colorRgb')) add(rgb(device.rgb));
    }
    if (steps.length === 0) throw new LumaError('Those lights have no known state to capture yet. Refresh them first.');
    return this.saveScene({ id: randomUUID(), name, icon, steps });
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
  runScene(scene: LightScene): string {
    validateScene(scene, this.home.devices);
    // Scenes, schedules and webhooks never fight the stream: the whole run is refused before its first write.
    if (scene.steps.some((st) => this.sync.holds(st.deviceID))) throw new LumaError('Screen Sync is using one of these lights. Stop it first.', 409);
    return this.runner.start(scene);
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

  // ---------- schedules ----------

  saveSchedule(input: unknown): void {
    const schedule = validateSchedule(input, this.home.scenes.map((s) => s.id));
    const index = this.home.schedules.findIndex((s) => s.id === schedule.id);
    if (index >= 0) this.home.schedules[index] = { ...schedule, lastRunMinute: this.home.schedules[index]!.lastRunMinute };
    else this.home.schedules.push(schedule);
    this.schedulePersist(); this.emit();
  }

  deleteSchedule(id: string): void {
    this.home.schedules = this.home.schedules.filter((s) => s.id !== id);
    this.schedulePersist(); this.emit();
  }

  tickSchedules(now = new Date()): void {
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
    };
  }

  async shutdown(): Promise<void> {
    clearInterval(this.scheduleTimer);
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
    return this.home.devices.filter((d) => room === undefined || d.room === room).map((d) => d.id);
  }

  get hasSavedHome(): boolean { return this.home.devices.length > 0; }
  get savedSchedules(): SceneSchedule[] { return this.home.schedules; }
}

function fail(text: string): never { throw new LumaError(text); }

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

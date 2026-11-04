// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Bluetooth lights, ported from the native BluetoothLights: one connection at a time, opened
// only when the person picks a light, in the source's order (connect → encryption marker →
// notifications → handshake → status reads). Keep-alive is a power query every 5 s; the light
// is dropped after 20 s without a reply or 3 minutes without use. The renderer carries GATT
// bytes over Web Bluetooth; the protocol, encryption and 60 ms write pacing live here.

import type { BluetoothAction, BluetoothOp, BluetoothView } from '../shared/types';
import { DreamView, GoveeBLEProfile, brightness, color, modelFromLocalName, parseAdvertisement, parseStatus, power, queryFrame, videoMode, type Advertisement, type Mode } from '../core/ble';
import { GoveeBLESession } from '../core/ble-crypto';
import { captureSummary, decodeCapture } from '../core/ble-capture';
import { LumaError, isObject } from '../core/model';

export interface BluetoothDeps {
  emit(): void;
  /** Sends to the renderer: `luma:ble-write` (frame) or `luma:ble-disconnect`. */
  post(channel: string, payload?: unknown): void;
  /** The Luma light whose Govee Home Bluetooth name matches, if signed in. */
  accountName?(localName: string): string | undefined;
  supported: boolean;
  clock?: { setTimeout: typeof setTimeout; clearTimeout: typeof clearTimeout; setInterval: typeof setInterval; clearInterval: typeof clearInterval; now(): number };
}

interface Nearby { id: string; localName: string; model?: string; advertisement?: Advertisement; rssi?: number }

const SCAN_SECONDS = 15;
/** Web Bluetooth doesn't expose the ATT MTU; Chromium negotiates the largest the adapter allows. */
const ASSUMED_WRITE_LENGTH = 512;

export class BluetoothController {
  private phase: BluetoothView['phase'] = 'idle';
  private message?: string;
  private nearby: Nearby[] = [];
  private choose?: (id: string) => void;
  private connected?: Nearby;
  private profile?: GoveeBLEProfile;
  private readback: BluetoothView['readback'] = {};
  private mode?: Mode;
  private session = new GoveeBLESession();
  /** Per light, so one light's encryption requirement never applies to another. */
  private sessions = new Map<string, GoveeBLESession>();
  private outbox: number[][] = [];
  private pump?: ReturnType<typeof setTimeout>;
  private deadline?: ReturnType<typeof setTimeout>;
  private scanStop?: ReturnType<typeof setTimeout>;
  private keepAlive?: ReturnType<typeof setInterval>;
  private lastReceived = 0;
  private lastUsed = 0;
  private capture?: BluetoothView['capture'];
  private readonly clock: NonNullable<BluetoothDeps['clock']>;

  constructor(private readonly deps: BluetoothDeps) {
    this.clock = deps.clock ?? { setTimeout, clearTimeout, setInterval, clearInterval, now: Date.now };
  }

  view(): BluetoothView {
    const p = this.profile, c = this.connected;
    return {
      supported: this.deps.supported, phase: this.phase, message: this.message,
      nearby: this.nearby.map((n) => {
        const profile = n.model ? GoveeBLEProfile.resolve(n.model, n.advertisement?.pact) : undefined;
        return { id: n.id, localName: n.localName, rssi: n.rssi, account: n.localName ? this.deps.accountName?.(n.localName) : undefined, connectable: !!profile,
          title: profile ? `${profile.name} · ${profile.model}` : n.model ?? 'Govee device',
          note: profile ? profile.limitation : 'Recognised, but Luma has no verified Bluetooth profile for this model yet.' };
      }),
      connected: c && p ? { id: c.id, title: p.name, encryption: !this.session.ready ? 'Not connected' : this.session.version === 0 ? 'Not encrypted' : `Encrypted (V${this.session.version})`,
        limitation: p.limitation, color: GoveeBLEProfile.supports(p, 'color'), videoMode: GoveeBLEProfile.supports(p, 'videoMode'), dreamView: GoveeBLEProfile.supports(p, 'dreamView'), memberLimit: p.dreamViewMemberLimit } : undefined,
      readback: { ...this.readback },
      capture: this.capture,
    };
  }

  /** Electron's select-bluetooth-device: called repeatedly while the chooser is open. */
  found(devices: Array<{ deviceId: string; deviceName: string }>, callback: (id: string) => void): void {
    this.choose = callback;
    if (this.phase !== 'scanning') { this.phase = 'scanning'; this.message = undefined; }
    for (const d of devices) {
      const model = modelFromLocalName(d.deviceName ?? '');
      if (!model) continue;
      const i = this.nearby.findIndex((n) => n.id === d.deviceId);
      if (i < 0) this.nearby.push({ id: d.deviceId, localName: d.deviceName, model });
    }
    this.deps.emit();
  }

  async handle(op: BluetoothOp, arg?: unknown): Promise<boolean | void> {
    switch (op) {
      case 'scan':
        if (!this.deps.supported) throw new LumaError('Bluetooth LE isn\'t available on this system.');
        if (this.connected) throw new LumaError('Disconnect the current light first.');
        this.nearby = []; this.phase = 'scanning'; this.message = undefined;
        this.clock.clearTimeout(this.scanStop!);
        this.scanStop = this.clock.setTimeout(() => this.endScan(), SCAN_SECONDS * 1000);
        break;
      case 'scanEnded': if (this.phase === 'scanning') { this.phase = 'idle'; this.choose = undefined; } break;
      case 'choose': {
        const target = this.nearby.find((n) => n.id === arg);
        if (!target || !this.choose || this.connected || !target.model || !GoveeBLEProfile.resolve(target.model, target.advertisement?.pact)) throw new LumaError('Choose a supported light from the list.');
        this.clock.clearTimeout(this.scanStop!);
        this.connected = target; this.profile = GoveeBLEProfile.resolve(target.model, target.advertisement?.pact);
        this.readback = {}; this.mode = undefined; this.outbox = [];
        this.session = this.sessions.get(target.id) ?? new GoveeBLESession(); this.session.reset();
        this.phase = 'connecting'; this.lastUsed = this.clock.now();
        this.setDeadline(30, "The light didn't finish connecting. Move closer and try again.");
        const choose = this.choose; this.choose = undefined;
        choose(target.id);
        break;
      }
      case 'secure': return this.secure(arg);
      case 'notifying': this.negotiate(); break;
      case 'notify': if (Array.isArray(arg) && arg.length <= 512 && arg.every((b) => Number.isInteger(b) && b >= 0 && b <= 255)) this.received(arg as number[]); break;
      case 'closed': if (this.connected || this.phase === 'scanning') this.disconnect(typeof arg === 'string' ? arg.slice(0, 200) : undefined, false); break;
      case 'disconnect': this.endScan(); this.disconnect(undefined); break;
      case 'send': this.act(arg); break;
      case 'capture':
        try { this.capture = { summary: captureSummary(decodeCapture(String(arg))) }; }
        catch (error) { this.capture = { error: error instanceof Error ? error.message : String(error) }; }
        break;
      default: throw new LumaError('Unknown Bluetooth request.');
    }
    this.deps.emit();
  }

  private endScan(): void {
    this.clock.clearTimeout(this.scanStop!);
    if (this.choose) { const cancel = this.choose; this.choose = undefined; cancel(''); }
    if (this.phase === 'scanning') this.phase = 'idle';
    this.deps.emit();
  }

  /** Marker and advertisement in; true when the session may continue to notifications. */
  private secure(arg: unknown): boolean {
    if (!this.connected || this.phase !== 'connecting' || !isObject(arg)) return false;
    const raw = Array.isArray(arg.advertisement) ? arg.advertisement.filter((b): b is number => Number.isInteger(b)).slice(0, 64) : undefined;
    const ad = raw ? parseAdvertisement(raw) : undefined;
    if (ad) this.connected.advertisement = ad;
    if (typeof arg.rssi === 'number') this.connected.rssi = arg.rssi;
    const m = arg.marker;
    const marker = Array.isArray(m) ? { kind: 'value' as const, bytes: m.filter((b): b is number => Number.isInteger(b)).slice(0, 64) } : { kind: m === 'failed' ? 'readFailed' as const : 'absent' as const };
    this.phase = 'securing';
    const advertised = this.connected.advertisement;
    try { this.session.select(marker, advertised?.supportsEncryption ?? false, advertised ? !advertised.supportsEncryption : false); }
    catch { this.disconnect("Luma couldn't tell how this light encrypts its connection, so it didn't send anything."); return false; }
    const pact = this.session.markerPact ?? advertised?.pact;
    if (this.connected.model && pact) this.profile = GoveeBLEProfile.resolve(this.connected.model, pact);
    this.deps.emit();
    return true;
  }

  private negotiate(): void {
    if (!this.connected || this.phase !== 'securing') return;
    let first: number[] | undefined;
    try { first = this.session.startNegotiation(ASSUMED_WRITE_LENGTH); }
    catch { this.disconnect("This connection can't carry the light's encryption (the Bluetooth packet size is too small)."); return; }
    if (!first) { this.becameReady(); return; }
    this.setDeadline(6, "The light didn't answer the encryption handshake.");
    this.enqueue(first);
  }

  private becameReady(): void {
    this.clock.clearTimeout(this.deadline!);
    this.phase = 'reading';
    const p = this.profile;
    for (const q of ['power', 'brightness', 'colorMode', 'firmware', ...(p && GoveeBLEProfile.supports(p, 'hardwareQuery') ? ['hardware'] as const : [])] as const) this.send(queryFrame(q));
    if (p && GoveeBLEProfile.supports(p, 'dreamView')) for (const s of ['switchGroup', 'videoSettings', 'saturation', 'memberConnect'] as const) this.send(DreamView.query(s));
    this.phase = 'ready';
    this.lastReceived = this.clock.now();
    this.clock.clearInterval(this.keepAlive!);
    this.keepAlive = this.clock.setInterval(() => {
      if (this.phase !== 'ready') return;
      if (this.clock.now() - this.lastReceived > 20_000) { this.disconnect('The light stopped answering.'); return; }
      if (this.clock.now() - this.lastUsed > 180_000) { this.disconnect(undefined); return; }
      this.send(queryFrame('power'));
    }, 5000);
    this.deps.emit();
  }

  private received(bytes: number[]): void {
    if (!this.connected) return;
    this.lastReceived = this.clock.now();
    let event;
    try { event = this.session.receive(bytes); } catch { this.disconnect('The light rejected the encryption handshake.'); return; }
    switch (event.kind) {
      case 'write': this.enqueue(event.frame); return;
      case 'ready': this.becameReady(); return;
      case 'ignored': return;
      case 'packet': {
        const status = parseStatus(event.packet), r = this.readback;
        if (!status) return;
        if (status.kind === 'power') r.power = status.on;
        else if (status.kind === 'brightness') r.brightness = status.percent;
        else if (status.kind === 'firmware') r.firmware = status.version;
        else if (status.kind === 'hardware') r.hardware = status.version;
        else if (status.kind === 'mode') {
          this.mode = status.mode;
          const m = status.mode;
          r.video = m.kind === 'video' && m.source !== undefined && m.wholeScreen !== undefined ? { movie: m.source === 'movie', whole: m.wholeScreen, saturation: m.saturation } : undefined;
        } else {
          const d = status.reading;
          if (d.kind === 'enabled') r.groupEnabled = d.on;
          else if (d.kind === 'videoSettings') { r.groupArea = d.applyArea; r.groupContent = d.contentMode; }
          else if (d.kind === 'saturation') r.groupSaturation = d.value;
          else if (d.kind === 'memberConnect') r.memberSlots = d.raw.map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
        }
        this.deps.emit();
      }
    }
  }

  /** A control: each one re-reads what it changes, and is refused until the light reported that value. */
  private act(arg: unknown): void {
    const a = arg as BluetoothAction, p = this.profile, r = this.readback;
    if (this.phase !== 'ready' || !p || !isObject(arg)) throw new LumaError('Connect to a light first.');
    const int = (v: unknown, lo: number, hi: number) => { if (!Number.isInteger(v) || (v as number) < lo || (v as number) > hi) throw new LumaError('Invalid value.'); return v as number; };
    switch (a.kind) {
      case 'power': if (r.power === undefined) break; this.send(power(a.on === true), queryFrame('power')); break;
      case 'brightness': if (r.brightness === undefined) break; this.send(brightness(int(a.value, 1, 100)), queryFrame('brightness')); break;
      case 'color': { if (!GoveeBLEProfile.supports(p, 'color')) break; const v = int(a.rgb, 0, 0xffffff); this.send(color(v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff, p.wholeMask), queryFrame('colorMode')); break; }
      case 'video': {
        // Only once the light reports video mode, so sound settings Luma doesn't show go back unchanged.
        const m = this.mode;
        if (!GoveeBLEProfile.supports(p, 'videoMode') || m?.kind !== 'video') break;
        this.send(videoMode(a.movie ? 'movie' : 'game', a.whole === true, int(a.saturation, 1, 100), m.soundEffects, m.softness), queryFrame('colorMode'));
        break;
      }
      case 'groupEnabled': if (r.groupEnabled === undefined) break; this.send(DreamView.setEnabled(a.on === true), DreamView.query('switchGroup')); break;
      case 'groupVideo': if (r.groupArea === undefined || r.groupArea > 1 || (r.groupContent ?? 2) > 1) break; this.send(DreamView.setVideo(a.whole === true, a.movie === true), DreamView.query('videoSettings')); break;
      case 'groupSaturation': if (r.groupSaturation === undefined) break; this.send(DreamView.setSaturation(int(a.value, 0, 100)), DreamView.query('saturation')); break;
      default: throw new LumaError('Unknown Bluetooth control.');
    }
  }

  /** Sends a logical frame through the session. */
  private send(frame: number[], thenRead?: number[]): void {
    if (!this.session.ready) return;
    let packet: number[];
    try { packet = this.session.encode(frame); } catch { return; }
    this.lastUsed = this.clock.now();
    this.enqueue(packet);
    if (thenRead) this.send(thenRead);
  }

  private enqueue(bytes: number[]): void {
    this.outbox.push(bytes);
    if (this.pump) return;
    // ponytail: fixed 60 ms pacing, as on native; tune per model if a light drops writes.
    const next = () => {
      const frame = this.outbox.shift();
      if (!frame || !this.connected) { this.pump = undefined; return; }
      this.deps.post('luma:ble-write', frame);
      this.pump = this.clock.setTimeout(next, 60);
    };
    next();
  }

  private setDeadline(seconds: number, message: string): void {
    this.clock.clearTimeout(this.deadline!);
    this.deadline = this.clock.setTimeout(() => this.disconnect(message), seconds * 1000);
  }

  disconnect(reason: string | undefined, tellRenderer = true): void {
    this.clock.clearTimeout(this.deadline!); this.clock.clearInterval(this.keepAlive!); this.clock.clearTimeout(this.pump!);
    this.pump = undefined; this.outbox = [];
    if (this.connected) { this.session.reset(); this.sessions.set(this.connected.id, this.session); }
    const had = !!this.connected;
    this.connected = undefined; this.profile = undefined; this.mode = undefined;
    this.phase = reason ? 'failed' : 'idle'; this.message = reason;
    if (had && tellRenderer) this.deps.post('luma:ble-disconnect');
    this.deps.emit();
  }
}

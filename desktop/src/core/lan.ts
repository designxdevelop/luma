// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Govee's documented basic LAN UDP protocol. A successful send is NOT a device
// acknowledgement, and control commands have no reply.

import dgram from 'node:dgram';
import type { CapabilityCommand, JSONValue } from '../shared/types';
import { BASIC_TYPES, LumaError, isObject, safeInt } from './model';

export interface LanStatus { power: boolean; brightness: number; rgb: number; kelvin: number }
export type LanPacket =
  | { kind: 'discovery'; id: string; sku: string; ip: string }
  | { kind: 'status'; ip: string; status: LanStatus };

const MULTICAST_GROUP = '239.255.255.250';
const SCAN_PORT = 4001;
const REPLY_PORT = 4002;
const CONTROL_PORT = 4003;
const MAX_DATAGRAM = 8192;

/**
 * Dotted quad, each octet 0…255 in canonical decimal form (leading zeros such as
 * "01.2.3.4" are rejected: they are ambiguous, some stacks read them as octal),
 * first octet 1…223, not 127.x.
 */
export function isUnicastIPv4(ip: string): boolean {
  const parts = ip.split('.');
  if (parts.length !== 4 || !parts.every((p) => /^(0|[1-9]\d{0,2})$/.test(p) && Number(p) <= 255)) return false;
  const first = Number(parts[0]);
  return first >= 1 && first <= 223 && first !== 127;
}

export function lanEnvelope(cmd: string, data: Record<string, JSONValue>): Buffer {
  return Buffer.from(JSON.stringify({ msg: { cmd, data } }));
}

/** Only the four basic controls travel over LAN; everything else needs cloud. */
export function lanControlPacket(command: CapabilityCommand): Buffer {
  const unsupported = () => new LumaError("This command or value is not supported by Govee's LAN API. Use cloud control for scenes and advanced capabilities.");
  if (!isObject(command) || BASIC_TYPES[command.instance] !== command.type) throw unsupported();
  switch (command.instance) {
    case 'powerSwitch': {
      const n = safeInt(command.value, 0, 1);
      if (n === undefined) throw unsupported();
      return lanEnvelope('turn', { value: n });
    }
    case 'brightness': {
      const n = safeInt(command.value, 1, 100);
      if (n === undefined) throw unsupported();
      return lanEnvelope('brightness', { value: n });
    }
    case 'colorRgb': {
      const n = safeInt(command.value, 0, 0xffffff);
      if (n === undefined) throw unsupported();
      return lanEnvelope('colorwc', { color: { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 }, colorTemInKelvin: 0 });
    }
    case 'colorTemperatureK': {
      const n = safeInt(command.value, 2000, 9000);
      if (n === undefined) throw unsupported();
      return lanEnvelope('colorwc', { color: { r: 0, g: 0, b: 0 }, colorTemInKelvin: n });
    }
    default:
      throw unsupported();
  }
}

export function parseLanPacket(data: Buffer, sourceIP: string): LanPacket {
  const invalid = () => new LumaError('Invalid LAN datagram.');
  if (data.length > MAX_DATAGRAM || !isUnicastIPv4(sourceIP)) throw invalid();
  let root: unknown;
  try { root = JSON.parse(data.toString('utf8')); } catch { throw invalid(); }
  const msg = isObject(root) ? root.msg : undefined;
  if (!isObject(msg) || typeof msg.cmd !== 'string' || !isObject(msg.data)) throw invalid();
  const body = msg.data;
  if (msg.cmd === 'scan') {
    const { ip, device, sku } = body;
    if (ip !== sourceIP || typeof device !== 'string' || device === '' || device.length > 128 || typeof sku !== 'string' || sku === '' || sku.length > 32) throw invalid();
    return { kind: 'discovery', id: device, sku, ip };
  }
  if (msg.cmd === 'devStatus') {
    const color = isObject(body.color) ? body.color : {};
    const onOff = safeInt(body.onOff, 0, 1), brightness = safeInt(body.brightness, 0, 100);
    const r = safeInt(color.r, 0, 255), g = safeInt(color.g, 0, 255), b = safeInt(color.b, 0, 255);
    const kelvin = safeInt(body.colorTemInKelvin, 0, 9000);
    if (onOff === undefined || brightness === undefined || r === undefined || g === undefined || b === undefined || kelvin === undefined || (kelvin !== 0 && kelvin < 2000)) throw invalid();
    return { kind: 'status', ip: sourceIP, status: { power: onOff === 1, brightness, rgb: (r << 16) | (g << 8) | b, kelvin } };
  }
  throw invalid();
}

export interface UdpSocketLike {
  bind(port: number, cb: () => void): void;
  on(event: 'message', cb: (msg: Buffer, rinfo: { address: string; family: string }) => void): void;
  on(event: 'error', cb: (err: Error) => void): void;
  addMembership(group: string): void;
  setMulticastTTL(ttl: number): void;
  send(msg: Buffer, port: number, address: string, cb?: (err: Error | null) => void): void;
  close(): void;
}

export interface LanHandlers { onPacket: (packet: LanPacket) => void; onError: (message: string) => void }

const defaultSocket = (): UdpSocketLike => dgram.createSocket({ type: 'udp4', reuseAddr: true }) as unknown as UdpSocketLike;

export class GoveeLan {
  private socket?: UdpSocketLike;
  private starting?: Promise<void>;
  private bound = false;

  constructor(private readonly handlers: LanHandlers, private readonly createSocket: () => UdpSocketLike = defaultSocket) {}

  get running(): boolean { return this.socket !== undefined && this.bound; }

  start(): Promise<void> {
    if (this.running) return Promise.resolve();
    this.starting ??= this.open().finally(() => { this.starting = undefined; });
    return this.starting;
  }

  private open(): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = this.createSocket();
      const fail = (error: unknown) => {
        try { socket.close(); } catch { /* already closed */ }
        if (this.socket === socket) this.socket = undefined;
        this.bound = false;
        reject(bindError(error));
      };
      socket.on('error', (error) => {
        if (this.bound) this.handlers.onError(`LAN socket error${errorCode(error)}.`);
        else fail(error);
      });
      socket.on('message', (msg, rinfo) => this.receive(msg, rinfo));
      this.socket = socket;
      try {
        socket.bind(REPLY_PORT, () => {
          if (this.socket !== socket) return reject(new LumaError('LAN start was cancelled.'));
          try {
            socket.addMembership(MULTICAST_GROUP);
            socket.setMulticastTTL(1);
          } catch (error) { return fail(error); }
          this.bound = true;
          resolve();
        });
      } catch (error) { fail(error); }
    });
  }

  /** Multicast scan; devices answer on UDP 4002. */
  discover(): void {
    this.send(lanEnvelope('scan', { account_topic: 'reserve' }), SCAN_PORT, MULTICAST_GROUP);
  }

  requestStatus(ip: string): void {
    if (!isUnicastIPv4(ip)) throw new LumaError('A valid device IPv4 address is required.');
    this.send(lanEnvelope('devStatus', {}), CONTROL_PORT, ip);
  }

  /**
   * Resolves once the OS accepted the datagram (NOT a device acknowledgement); rejects with a LumaError
   * on caller mistakes or a send failure. Failures are reported only through the promise, never onError.
   */
  async control(ip: string, command: CapabilityCommand): Promise<void> {
    if (!isUnicastIPv4(ip)) throw new LumaError('This light has no valid LAN address.');
    const packet = lanControlPacket(command);
    const socket = this.socket;
    if (!socket || !this.bound) throw new LumaError('Start LAN discovery first.');
    await new Promise<void>((resolve, reject) => {
      const fail = (error: unknown) => reject(new LumaError(`Could not send to the light over LAN: ${errorName(error)}`));
      try {
        socket.send(packet, CONTROL_PORT, ip, (error) => (error ? fail(error) : resolve()));
      } catch (error) { fail(error); }
    });
  }

  stop(): void {
    const socket = this.socket;
    this.socket = undefined;
    this.bound = false;
    try { socket?.close(); } catch { /* already closed */ }
  }

  private send(packet: Buffer, port: number, address: string): void {
    if (!this.socket || !this.bound) throw new LumaError('Start LAN discovery first.');
    try {
      this.socket.send(packet, port, address, (error) => { if (error) this.handlers.onError(`Could not send a LAN packet${errorCode(error)}.`); });
    } catch (error) {
      this.handlers.onError(`Could not send a LAN packet${errorCode(error)}.`);
    }
  }

  private receive(msg: Buffer, rinfo: { address: string; family: string }): void {
    // Anything that is not a well-formed Govee reply (SSDP/mDNS chatter, spoofed or oversized data) is dropped silently.
    if (rinfo.family !== 'IPv4' || msg.length > MAX_DATAGRAM) return;
    let packet: LanPacket;
    try { packet = parseLanPacket(msg, rinfo.address); } catch { return; }
    try {
      this.handlers.onPacket(packet);
      // Discovery carries no state; ask for it separately.
      if (packet.kind === 'discovery') this.requestStatus(packet.ip);
    } catch {
      this.handlers.onError('Could not process a LAN packet.');
    }
  }
}

function errorCode(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === 'string' && /^[A-Z0-9_]{1,24}$/.test(code) ? ` (${code})` : '';
}

function errorName(error: unknown): string {
  return errorCode(error).slice(2, -1) || 'unknown error';
}

function bindError(error: unknown): LumaError {
  if (errorCode(error) === ' (EADDRINUSE)') {
    return new LumaError('UDP port 4002 is already in use, probably by Home Assistant or another Govee tool. Close it (or turn off LAN control) and try again.');
  }
  return new LumaError(`Could not start LAN control${errorCode(error)}. Check that a firewall is not blocking UDP 4002 and that LAN control is enabled in the Govee Home app.`);
}

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Govee's Bluetooth link encryption, ported from LumaCore GoveeBLECrypto.swift,
// itself from ha-govee-led-ble @ b845c59 (`govee_encryption/__init__.py`,
// `session.py`, `govee_encryption.ksy`). Runs in the main process (node:crypto).
//
// V1 is the vendor's unauthenticated AES-ECB scheme with an RC4 tail; V2 is
// AES-GCM with a per-device key. The keys below are vendor-global constants
// shipped in every Govee Home install, not per-device secrets; the session keys
// they protect are never logged or persisted.

import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { checksum, type Pact } from './ble';
import { LumaError } from './model';

/** Constants only; untrusted text goes through `parseHex`. */
export function hex(s: string): number[] {
  const bytes = parseHex(s);
  if (!bytes) throw new Error('Invalid hex constant.');
  return bytes;
}

export function parseHex(s: string): number[] | undefined {
  if (s.length % 2 !== 0) return undefined;
  const out: number[] = [];
  for (let i = 0; i < s.length; i += 2) {
    const pair = s.slice(i, i + 2);
    // Swift's UInt8(_:radix:) also takes a sign: "+f" is 15 and "-0" is 0.
    if (/^[0-9a-fA-F]{2}$/.test(pair) || /^\+[0-9a-fA-F]$/.test(pair)) out.push(parseInt(pair, 16));
    else if (pair === '-0') out.push(0);
    else return undefined;
  }
  return out;
}

export const communicationKey = hex('4d616b696e674c696665536d61727465');
export const handshakeKey = hex('fc03783c7c42cb83e202a1643648aff6');
export const deviceKey = hex('ae028b630bae6ecc4bff1b249e22f955');
export const tagLength = 16;
/** ATT payload a V2 handshake reply needs (MTU 53 minus 3). */
export const minimumV2WriteLength = 50;

function ecb(data: number[], key: number[], encrypt: boolean): number[] {
  if (data.length === 0) return [];
  const cipher = encrypt ? createCipheriv('aes-128-ecb', Buffer.from(key), null) : createDecipheriv('aes-128-ecb', Buffer.from(key), null);
  cipher.setAutoPadding(false);
  return [...Buffer.concat([cipher.update(Buffer.from(data)), cipher.final()])];
}

/** Written by hand: Electron's BoringSSL has no RC4. */
function rc4(data: number[], key: number[]): number[] {
  const s = Array.from({ length: 256 }, (_, i) => i);
  for (let i = 0, j = 0; i < 256; i++) {
    j = (j + s[i]! + key[i % key.length]!) & 0xFF;
    [s[i], s[j]] = [s[j]!, s[i]!];
  }
  const out: number[] = [];
  for (let n = 0, i = 0, j = 0; n < data.length; n++) {
    i = (i + 1) & 0xFF;
    j = (j + s[i]!) & 0xFF;
    [s[i], s[j]] = [s[j]!, s[i]!];
    out.push(data[n]! ^ s[(s[i]! + s[j]!) & 0xFF]!);
  }
  return out;
}

/** Whole 16-byte blocks through AES-ECB, any remainder through a fresh RC4 stream. */
export function v1(data: number[], key: number[], encrypt: boolean): number[] {
  const boundary = Math.floor(data.length / 16) * 16;
  const out = ecb(data.slice(0, boundary), key, encrypt);
  if (boundary < data.length) out.push(...rc4(data.slice(boundary), key));
  return out;
}

export function aesECB(block: number[], key: number[]): number[] { return ecb(block, key, true); }

/** `E7 <opcode> <17 random bytes> <xor>` under the shared key. */
export function v1Handshake(opcode: number, random: number[]): number[] {
  const body = [0xE7, opcode, ...random];
  return v1([...body, checksum(body)], communicationKey, true);
}

/** The reply's opcode and 16-byte body, or undefined when it isn't a valid handshake frame. */
export function parseV1Handshake(frame: number[]): { opcode: number; body: number[] } | undefined {
  if (frame.length !== 20) return undefined;
  const plain = v1(frame, communicationKey, false);
  if (plain[0] !== 0xE7 || (plain[1] !== 1 && plain[1] !== 2) || checksum(plain) !== 0) return undefined;
  return { opcode: plain[1], body: plain.slice(2, 18) };
}

export function v2Request(clientIV: number[], nonce: number[]): number[] {
  const header = [0xE7, 0x11, 0x01, ...nonce, tagLength];
  return [...header, ...gcmSeal(clientIV, handshakeKey, nonce, header)];
}

/** Client IV from a captured request (for offline capture decoding). */
export function parseV2Request(frame: number[]): number[] | undefined {
  if (frame.length !== 40 || frame[0] !== 0xE7 || frame[1] !== 0x11 || frame[2] !== 0x01 || frame[15] !== tagLength) return undefined;
  return gcmOpen(frame.slice(16), handshakeKey, frame.slice(3, 15), frame.slice(0, 16));
}

export interface V2Identity { deviceIV: number[]; sku: string; mac: number[]; key: number[] }

export function parseV2Response(frame: number[]): V2Identity | undefined {
  if (frame.length !== 50 || frame[0] !== 0xE7 || frame[1] !== 0x11 || frame[2] !== 0x00) return undefined;
  const plain = gcmOpen(frame.slice(15), handshakeKey, frame.slice(3, 15), frame.slice(0, 15));
  if (!plain || plain.length !== 19) return undefined;
  const info = plain.slice(8, 19);
  return { deviceIV: plain.slice(0, 8), sku: new TextDecoder('utf-8', { ignoreBOM: true }).decode(new Uint8Array(plain.slice(8, 13))), mac: plain.slice(13, 19),
    key: aesECB([...info, ...new Array<number>(16 - info.length).fill(0)], deviceKey) };
}

function counterBytes(counter: number): number[] { return [counter >>> 24 & 0xFF, counter >>> 16 & 0xFF, counter >>> 8 & 0xFF, counter & 0xFF]; }

export function seal(plain: number[], iv: number[], key: number[], counter: number): number[] {
  if (!Number.isInteger(counter) || counter < 0 || counter > 0xFFFFFFFF) throw new Error('Counter must be a 32-bit unsigned integer.');
  const ctr = counterBytes(counter);
  return [...ctr, ...gcmSeal(plain, key, [...iv, ...ctr], ctr)];
}

export function unseal(frame: number[], iv: number[], key: number[]): { counter: number; plain: number[] } | undefined {
  if (frame.length < 4 + tagLength) return undefined;
  const ctr = frame.slice(0, 4);
  const plain = gcmOpen(frame.slice(4), key, [...iv, ...ctr], ctr);
  if (!plain) return undefined;
  return { counter: ctr.reduce((n, b) => n * 256 + b, 0), plain };
}

function gcmSeal(plain: number[], key: number[], nonce: number[], aad: number[]): number[] {
  const cipher = createCipheriv('aes-128-gcm', Buffer.from(key), Buffer.from(nonce), { authTagLength: tagLength });
  cipher.setAAD(Buffer.from(aad));
  return [...Buffer.concat([cipher.update(Buffer.from(plain)), cipher.final(), cipher.getAuthTag()])];
}

function gcmOpen(sealed: number[], key: number[], nonce: number[], aad: number[]): number[] | undefined {
  if (sealed.length < tagLength) return undefined;
  try {
    const decipher = createDecipheriv('aes-128-gcm', Buffer.from(key), Buffer.from(nonce), { authTagLength: tagLength });
    decipher.setAAD(Buffer.from(aad));
    decipher.setAuthTag(Buffer.from(sealed.slice(-tagLength)));
    return [...Buffer.concat([decipher.update(Buffer.from(sealed.slice(0, -tagLength))), decipher.final()])];
  } catch {
    return undefined;
  }
}

// MARK: Session

export type Marker =
  /** The device has no `2b12` characteristic. */
  | { kind: 'absent' }
  | { kind: 'value'; bytes: number[] }
  | { kind: 'readFailed' };

/** Fixed reasons: never carry keys, addresses or raw bytes. */
export type Failure = 'selectionFailed' | 'previousSelectionFailed' | 'notSelected' | 'notReady'
  | 'v2NeedsLargerWrites' | 'handshakeRejected' | 'counterExhausted' | 'invalidFrame';

export class GoveeBLESessionError extends LumaError {
  constructor(readonly failure: Failure) { super(failure); this.name = 'GoveeBLESessionError'; }
}

export type SessionEvent =
  /** Send this handshake frame next. */
  | { kind: 'write'; frame: number[] }
  | { kind: 'ready' }
  /** A decrypted 20-byte notification. */
  | { kind: 'packet'; packet: number[] }
  /** A duplicate, replayed or undecryptable frame, dropped. */
  | { kind: 'ignored' };

/** `format version [flag pactType(be16) pactCode if format 2] tail…` */
export function parseMarker(b: number[]): { version: number; pact: Pact | undefined } | undefined {
  if (b.length < 2 || (b[0] !== 1 && b[0] !== 2) || b[1]! > 2) return undefined;
  if (b[0] === 2) {
    if (b.length < 6) return undefined;
    return { version: b[1]!, pact: { type: b[3]! << 8 | b[4]!, code: b[5]! } };
  }
  return { version: b[1]!, pact: undefined };
}

/**
 * Encryption for one connection, transport-agnostic and fail-closed. The
 * Bluetooth layer feeds it the marker read, notifications and the write
 * length, and sends what it returns. Selection rules follow `session.py`
 * exactly: positive encryption evidence (advertised flag, a marker, or an
 * earlier encrypted connection) never falls back to plaintext.
 */
export class GoveeBLESession {
  #version = 0;
  #requiredVersion = 0;
  #ready = false;
  #markerPact: Pact | undefined;
  #deviceSKU: string | undefined;
  #deviceMAC: number[] | undefined;
  #rejectedFrames = 0;
  #selectionFailed = false;
  #awaiting: number | undefined;
  #key: number[] | undefined;
  #clientIV: number[] | undefined;
  #deviceIV: number[] | undefined;
  #counter = 2;
  #received = 0;
  #maxWrite = 0;
  /** Injected for tests; otherwise the system CSPRNG. */
  random: (n: number) => number[] = (n) => [...randomBytes(n)];

  get version(): number { return this.#version; }
  get requiredVersion(): number { return this.#requiredVersion; }
  get ready(): boolean { return this.#ready; }
  get markerPact(): Pact | undefined { return this.#markerPact; }
  /** From a V2 handshake: the model and MAC the device reports for itself. */
  get deviceSKU(): string | undefined { return this.#deviceSKU; }
  get deviceMAC(): number[] | undefined { return this.#deviceMAC; }
  get rejectedFrames(): number { return this.#rejectedFrames; }
  get encrypted(): boolean { return this.#ready && this.#version !== 0; }

  /** Forget this connection. The encryption requirement survives, as in the source. */
  reset(): void {
    this.#ready = false; this.#markerPact = undefined; this.#awaiting = undefined; this.#key = undefined; this.#clientIV = undefined; this.#deviceIV = undefined;
    this.#counter = 2; this.#received = 0; this.#maxWrite = 0; this.#deviceSKU = undefined; this.#deviceMAC = undefined;
  }

  /** Choose plaintext, V1 or V2 from what the device shows, without probing. */
  select(marker: Marker, advertisedEncryption: boolean, plaintextEvidence = false): void {
    this.reset();
    this.#version = 0;
    if (advertisedEncryption && this.#requiredVersion === 0) this.#requiredVersion = 1;
    const fail = (reason: Failure = 'selectionFailed') => { this.#selectionFailed = true; this.reset(); return new GoveeBLESessionError(reason); };
    switch (marker.kind) {
      case 'absent':
        if (this.#selectionFailed) throw fail('previousSelectionFailed');
        this.#version = this.#requiredVersion !== 0 ? this.#requiredVersion : (advertisedEncryption ? 1 : 0);
        break;
      case 'value': {
        const parsed = parseMarker(marker.bytes);
        if (!parsed) {
          if (!plaintextEvidence || advertisedEncryption || this.#requiredVersion !== 0) throw fail();
          this.#selectionFailed = false; this.#ready = true;
          return;
        }
        // Version zero means plaintext only without earlier encryption evidence.
        this.#version = parsed.version !== 0 ? parsed.version : this.#requiredVersion;
        this.#markerPact = parsed.pact;
        this.#selectionFailed = false;
        break;
      }
      case 'readFailed':
        if (!plaintextEvidence || advertisedEncryption || this.#requiredVersion !== 0) throw fail();
        this.#selectionFailed = false; this.#ready = true;
        return;
    }
    if (this.#version !== 0) this.#requiredVersion = this.#version;
    this.#ready = this.#version === 0;
  }

  /**
   * The first handshake frame, or undefined when the link is plaintext and ready.
   * `maxWriteLength` is the ATT payload for writes without response.
   */
  startNegotiation(maxWriteLength: number): number[] | undefined {
    if (this.#ready && this.#version === 0) return undefined;
    this.#maxWrite = maxWriteLength;
    switch (this.#version) {
      case 1:
        this.#awaiting = 1;
        return v1Handshake(1, this.random(17));
      case 2: {
        if (maxWriteLength < minimumV2WriteLength) { this.reset(); throw new GoveeBLESessionError('v2NeedsLargerWrites'); }
        const iv = this.random(8);
        this.#clientIV = iv; this.#awaiting = 0x11;
        return v2Request(iv, this.random(12));
      }
      default:
        throw new GoveeBLESessionError('notSelected');
    }
  }

  receive(frame: number[]): SessionEvent {
    if (!this.#ready) {
      const expected = this.#awaiting;
      if (expected === undefined) return { kind: 'ignored' };
      if (this.#version === 1) {
        const reply = parseV1Handshake(frame);
        if (!reply) { this.#rejectedFrames += 1; this.reset(); throw new GoveeBLESessionError('handshakeRejected'); }
        // A duplicate key reply is not confirmation of the next phase.
        if (reply.opcode !== expected) { this.#rejectedFrames += 1; return { kind: 'ignored' }; }
        if (expected === 1) {
          this.#key = reply.body; this.#awaiting = 2;
          return { kind: 'write', frame: v1Handshake(2, this.random(17)) };
        }
        this.#awaiting = undefined; this.#ready = true;
        return { kind: 'ready' };
      }
      const identity = parseV2Response(frame);
      if (!identity) { this.#rejectedFrames += 1; this.reset(); throw new GoveeBLESessionError('handshakeRejected'); }
      this.#deviceIV = identity.deviceIV; this.#key = identity.key; this.#deviceSKU = identity.sku; this.#deviceMAC = identity.mac;
      this.#awaiting = undefined; this.#ready = true;
      return { kind: 'ready' };
    }
    switch (this.#version) {
      case 0: return { kind: 'packet', packet: frame };
      case 1: {
        const key = this.#key;
        if (!key) throw new GoveeBLESessionError('notReady');
        const plain = v1(frame, key, false);
        if (plain.length !== 20 || checksum(plain) !== 0) { this.#rejectedFrames += 1; return { kind: 'ignored' }; }
        return { kind: 'packet', packet: plain };
      }
      default: {
        const key = this.#key, deviceIV = this.#deviceIV;
        if (!key || !deviceIV) throw new GoveeBLESessionError('notReady');
        const opened = unseal(frame, deviceIV, key);
        if (!opened || opened.counter <= this.#received) { this.#rejectedFrames += 1; return { kind: 'ignored' }; }
        this.#received = opened.counter;
        return { kind: 'packet', packet: opened.plain };
      }
    }
  }

  encode(packet: number[]): number[] {
    if (!this.#ready) throw new GoveeBLESessionError('notReady');
    switch (this.#version) {
      case 0: return packet;
      case 1: {
        const key = this.#key;
        if (!key) throw new GoveeBLESessionError('notReady');
        return v1(packet, key, true);
      }
      default: {
        const key = this.#key, clientIV = this.#clientIV;
        if (!key || !clientIV) throw new GoveeBLESessionError('notReady');
        if (packet.length + 20 > this.#maxWrite) throw new GoveeBLESessionError('v2NeedsLargerWrites');
        if (this.#counter >= 0xFFFFFFFF) throw new GoveeBLESessionError('counterExhausted');
        const counter = this.#counter;
        this.#counter += 1;
        return seal(packet, clientIV, key, counter);
      }
    }
  }
}

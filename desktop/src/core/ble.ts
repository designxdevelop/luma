// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Govee's Bluetooth LE light protocol, for the models whose wire format is
// evidenced in public source. Pure bytes: no Bluetooth stack here. Ported from
// LumaCore GoveeBLE.swift.
//
// Source of every frame, profile rule and test vector: teh-hippo/ha-govee-led-ble
// @ b845c59 (`transport.py`, `advertisement.py`, `const.py`, the `h6099_*` and
// `h6097_*` Kaitai schemas, and `tests/test_h6099*.py`). Nothing is guessed: a
// model or setting the source doesn't establish has no builder here.

import { LumaError } from './model';

/** GATT characteristics (`transport.py`). Writes go without response. */
export const writeCharacteristic = '00010203-0405-0607-0809-0A0B0C0D2B11';
export const notifyCharacteristic = '00010203-0405-0607-0809-0A0B0C0D2B10';
/** Optional: a readable marker saying whether, and how, the link is encrypted. */
export const encryptionCharacteristic = '00010203-0405-0607-0809-0A0B0C0D2B12';

export function checksum(bytes: Iterable<number>): number {
  let x = 0;
  for (const b of bytes) x ^= b;
  return x;
}

function u8(value: number, what: string): number {
  if (!Number.isInteger(value) || value < 0 || value > 255) throw new LumaError(`${what} must be 0–255.`);
  return value;
}

/** 19 content bytes, zero-padded, then their XOR. */
export function frame(prefix: number[]): number[] {
  if (prefix.length > 19) throw new Error('A Govee frame holds at most 19 content bytes.');
  const body = [...prefix, ...new Array<number>(19 - prefix.length).fill(0)];
  return [...body, checksum(body)];
}

export function isValidFrame(f: number[]): boolean { return f.length === 20 && checksum(f.slice(0, 19)) === f[19]; }

// MARK: Advertisement

/** A product revision. Some models change capabilities by Pact. */
export interface Pact { type: number; code: number }

export interface Advertisement {
  flags: number;
  pactType: number;
  pactCode: number;
  /** Flag bit 0x40. Its absence is not proof the link is plaintext. */
  supportsEncryption: boolean;
  pact: Pact;
}

/**
 * Manufacturer data: the company ID little-endian, then the payload. Govee puts
 * flags in the low byte, 0x88 in the high byte, then 0xEC, a big-endian Pact type
 * and a Pact code.
 */
export function parseAdvertisement(data: number[]): Advertisement | undefined {
  if (data.length < 6 || data[1] !== 0x88 || data[2] !== 0xEC) return undefined;
  const flags = data[0]!, pactType = data[3]! << 8 | data[4]!, pactCode = data[5]!;
  return { flags, pactType, pactCode, supportsEncryption: (flags & 0x40) !== 0, pact: { type: pactType, code: pactCode } };
}

// ICU's `$` (NSRegularExpression) also matches before a final line terminator.
const icuEnd = String.raw`(?=(?:\r\n|[\n\v\f\r\u0085\u2028\u2029])?$)`;
const namePattern = new RegExp(String.raw`(?:(?:ihoment|Govee|Minger|GBK|GVH)_(H[0-9A-Z]{4})(?:_|${icuEnd})|^GVH?([0-9A-Z]{4})(?:_[0-9A-Z]+|[0-9A-Z]{4}|${icuEnd})${icuEnd}|^(H[0-9A-Z]{4})_[0-9A-Z]+${icuEnd})`, 'i');

/** The model in an advertised local name such as `Govee_H6097_1A2B` (`const.py` `_BLE_MODEL_PATTERN`). */
export function modelFromLocalName(name: string): string | undefined {
  const match = namePattern.exec(name);
  if (!match) return undefined;
  for (const group of [1, 2, 3]) {
    const g = match[group];
    if (g !== undefined) {
      const raw = g.toUpperCase();
      return raw.length === 5 ? raw : 'H' + raw;
    }
  }
  return undefined;
}

// MARK: Commands (H6099 grammar, shared by H6097 and H66A0)

export function power(on: boolean): number[] { return frame([0x33, 0x01, on ? 1 : 0]); }

export function brightness(percent: number): number[] {
  if (!Number.isInteger(percent) || percent < 0 || percent > 100) throw new LumaError('Brightness must be 0–100.');
  return frame([0x33, 0x04, percent]);
}

/** Static colour on every segment in `mask` (Kelvin 0, preview black, as the source sends it). */
export function color(red: number, green: number, blue: number, mask: number): number[] {
  if (!Number.isInteger(mask) || mask < 0 || mask > 0xFFFF) throw new LumaError('Segment mask must be 0–65535.');
  return frame([0x33, 0x05, 0x15, 0x01, u8(red, 'Red'), u8(green, 'Green'), u8(blue, 'Blue'), 0, 0, 0, 0, 0, mask & 0xFF, mask >> 8]);
}

export type VideoSource = 'movie' | 'game';
export const videoSources: VideoSource[] = ['movie', 'game'];
const videoSourceRaw: Record<VideoSource, number> = { movie: 0, game: 1 };

/**
 * The backlight's own camera mode (Govee Home's Video tab): Movie or Game,
 * whole screen or part, saturation and sound effects.
 */
export function videoMode(source: VideoSource, wholeScreen: boolean, saturation: number, soundEffects: boolean, softness: number): number[] {
  if (!Number.isInteger(saturation) || saturation < 1 || saturation > 100) throw new LumaError('Saturation must be 1–100.');
  if (!Number.isInteger(softness) || softness < 0 || softness > 100) throw new LumaError('Softness must be 0–100.');
  return frame([0x33, 0x05, 0x00, videoSourceRaw[source], wholeScreen ? 0x09 : 0x08, saturation, soundEffects ? 1 : 0, 0x02, softness]);
}

// MARK: Status

export type Query = 'power' | 'brightness' | 'colorMode' | 'firmware' | 'hardware';
export const queries: Query[] = ['power', 'brightness', 'colorMode', 'firmware', 'hardware'];

export function queryFrame(query: Query): number[] {
  switch (query) {
    case 'power': return frame([0xAA, 0x01]);
    case 'brightness': return frame([0xAA, 0x04]);
    case 'colorMode': return frame([0xAA, 0x05, 0x01]);
    case 'firmware': return frame([0xAA, 0x06]);
    case 'hardware': return frame([0xAA, 0x07, 0x03]);
  }
}

export type Mode =
  | { kind: 'video'; source: VideoSource | undefined; wholeScreen: boolean | undefined; saturation: number; soundEffects: boolean; softness: number }
  /** The reply carries Kelvin only (0 = RGB); colour comes from segment pages, not read here. */
  | { kind: 'staticColor'; kelvin: number }
  | { kind: 'scene'; id: number }
  | { kind: 'other'; value: number };

export type Status =
  | { kind: 'power'; on: boolean }
  | { kind: 'brightness'; percent: number }
  | { kind: 'mode'; mode: Mode }
  | { kind: 'firmware'; version: string }
  | { kind: 'hardware'; version: string }
  | { kind: 'dreamView'; reading: DreamViewReading };

/** One notification. Anything unrecognised (command echoes, unmodelled domains) is undefined. */
export function parseStatus(f: number[]): Status | undefined {
  if (!isValidFrame(f) || f[0] !== 0xAA) return undefined;
  const body = f.slice(2, 19);
  const d = (i: number) => body[i]!;
  switch (f[1]) {
    case 0x01: return { kind: 'power', on: d(0) !== 0 };
    case 0x04: return d(0) <= 100 ? { kind: 'brightness', percent: d(0) } : undefined;
    case 0x06: return { kind: 'firmware', version: ascii(body) };
    case 0x07: return d(0) === 0x03 ? { kind: 'hardware', version: ascii(body.slice(1)) } : undefined;
    case 0x05:
      switch (d(0)) {
        case 0x00: return { kind: 'mode', mode: { kind: 'video', source: videoSources[d(1)], wholeScreen: d(2) === 9 ? true : d(2) === 8 ? false : undefined,
          saturation: d(3), soundEffects: d(4) !== 0, softness: d(6) } };
        case 0x15: return { kind: 'mode', mode: { kind: 'staticColor', kelvin: d(2) << 8 | d(3) } };
        case 0x04: return { kind: 'mode', mode: { kind: 'scene', id: d(1) | d(2) << 8 } };
        default: return { kind: 'mode', mode: { kind: 'other', value: d(0) } };
      }
    case 0x60: {
      const reading = DreamView.parse(f);
      return reading && { kind: 'dreamView', reading };
    }
    default: return undefined;
  }
}

function ascii(bytes: number[]): string {
  const end = bytes.indexOf(0);
  return String.fromCharCode(...(end < 0 ? bytes : bytes.slice(0, end)).filter((b) => b >= 0x20 && b < 0x7F));
}

// MARK: DreamView module 0x60

export type DreamViewSetting = 'switchGroup' | 'memberBrightness' | 'sameBrightness' | 'memberConnect' | 'saturation' | 'videoSettings' | 'sound';
const settingRaw: Record<DreamViewSetting, number> = {
  switchGroup: 0x01, memberBrightness: 0x03, sameBrightness: 0x04, memberConnect: 0x05, saturation: 0x09, videoSettings: 0x0A, sound: 0x0B,
};
export const dreamViewSettings = Object.keys(settingRaw) as DreamViewSetting[];

export type DreamViewReading =
  | { kind: 'enabled'; on: boolean }
  | { kind: 'memberBrightness'; raw: number[] }
  | { kind: 'sameBrightness'; on: boolean }
  | { kind: 'memberConnect'; raw: number[] }
  | { kind: 'saturation'; value: number }
  /** Raw values kept: 0 All / 1 Part, 0 Game / 1 Movie; anything else is unknown. */
  | { kind: 'videoSettings'; applyArea: number; contentMode: number }
  | { kind: 'sound'; enabled: boolean; softness: number };

/**
 * The controller's DreamView settings (`h6099_dreamview_frame.ksy`). Reads are
 * individual replies; zero slot bytes are not proof a slot is empty, and none
 * of this reads group membership. Group upload (A3 `0x50`) and delete (`0x0d`)
 * have no builder: membership needs evidenced `cmd_ver` (see `ble-capture`).
 */
export const DreamView = {
  query(setting: DreamViewSetting): number[] {
    return frame([0xAA, 0x60, settingRaw[setting], ...(setting === 'switchGroup' ? [1] : [])]);
  },

  parse(f: number[]): DreamViewReading | undefined {
    if (!isValidFrame(f) || f[0] !== 0xAA || f[1] !== 0x60) return undefined;
    const setting = dreamViewSettings.find((s) => settingRaw[s] === f[2]);
    if (!setting) return undefined;
    const b = f.slice(3, 19);
    const at = (i: number) => b[i]!;
    switch (setting) {
      case 'switchGroup': return { kind: 'enabled', on: at(0) !== 0 };
      case 'memberBrightness': return { kind: 'memberBrightness', raw: b };
      case 'sameBrightness': return { kind: 'sameBrightness', on: at(0) !== 0 };
      case 'memberConnect': return { kind: 'memberConnect', raw: b.slice(0, 10) };
      case 'saturation': return { kind: 'saturation', value: at(0) };
      case 'videoSettings': return { kind: 'videoSettings', applyArea: at(0), contentMode: at(1) };
      case 'sound': return { kind: 'sound', enabled: at(0) !== 0, softness: at(1) };
    }
  },

  /** Start or stop the group already set up on the controller. */
  setEnabled(on: boolean): number[] { return frame([0x33, 0x60, 0x01, on ? 1 : 0, 1]); },

  setSaturation(value: number): number[] {
    if (!Number.isInteger(value) || value < 0 || value > 100) throw new LumaError('Saturation must be 0–100.');
    return frame([0x33, 0x60, 0x09, value]);
  },

  setVideo(wholeScreen: boolean, movie: boolean): number[] { return frame([0x33, 0x60, 0x0A, wholeScreen ? 0 : 1, movie ? 1 : 0]); },
};

// MARK: A3 multi-frame payloads

/**
 * Joins `a3 <index> <17 bytes> <xor>` frames (indexes 0, 1, … then 0xFF) into
 * the envelope `01 <frame count> <type> <body…>` (`transport.py reassemble_a3`).
 */
export function reassembleA3(frames: number[][]): number[] | undefined {
  if (frames.length === 0) return undefined;
  const envelope: number[] = [];
  for (const [i, f] of frames.entries()) {
    if (!isValidFrame(f) || f[0] !== 0xA3 || f[1] !== (i === frames.length - 1 ? 0xFF : i & 0xFF)) return undefined;
    envelope.push(...f.slice(2, 19));
  }
  if (envelope.length < 3 || envelope[0] !== 0x01 || envelope[1] !== frames.length) return undefined;
  return envelope;
}

// MARK: - Profiles

export type Feature = 'power' | 'brightness' | 'color' | 'videoMode' | 'hardwareQuery' | 'dreamView';
export const features: Feature[] = ['power', 'brightness', 'color', 'videoMode', 'hardwareQuery', 'dreamView'];

/**
 * What Luma may do over Bluetooth for one model and revision. Only the TV
 * backlights sharing the H6099 command grammar are profiled (all "supported"
 * in the source, with owner confirmation issues 445/446/450); other recognised
 * Govee names are listed but not controlled.
 */
export interface GoveeBLEProfile {
  model: string;
  name: string;
  /** In `features` order. */
  features: Feature[];
  wholeMask: number;
  dreamViewMemberLimit: number;
  /** Why a capability is missing, when the revision isn't known well enough. */
  limitation?: string;
}

export const GoveeBLEProfile = {
  supports(profile: GoveeBLEProfile, feature: Feature): boolean { return profile.features.includes(feature); },

  /** `pact` comes from the advertisement or a format-2 encryption marker. */
  resolve(model: string, pact: Pact | undefined): GoveeBLEProfile | undefined {
    const full = [...features];
    switch (model.toUpperCase()) {
      case 'H6097':
        // `device_profile`: only Pact 1/1 and 2/1 are known to have the full feature set.
        if (pact && [{ type: 1, code: 1 }, { type: 2, code: 1 }].some((p) => p.type === pact.type && p.code === pact.code)) {
          return { model: 'H6097', name: 'TV Backlight 3 Lite', features: full, wholeMask: 0x3FFF, dreamViewMemberLimit: 7 };
        }
        return { model: 'H6097', name: 'TV Backlight 3 Lite', features: ['power', 'brightness'], wholeMask: 0x3FFF, dreamViewMemberLimit: 7,
          limitation: pact === undefined ? 'Revision not advertised yet: power and brightness only.' : 'Unrecognised revision: power and brightness only.' };
      case 'H6099':
        return { model: 'H6099', name: 'TV Backlight 3 Lite', features: full, wholeMask: 0x3FFF, dreamViewMemberLimit: 7 };
      case 'H66A0':
        // Its video and status grammars differ from H6099's, so its own video mode isn't built.
        return { model: 'H66A0', name: 'TV Backlight 3 Pro', features: ['power', 'brightness', 'color', 'dreamView'], wholeMask: 0x3FFF, dreamViewMemberLimit: 10 };
      default:
        return undefined;
    }
  },
};

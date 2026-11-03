// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Reads a Bluetooth capture of Govee Home talking to a light and recovers what
// Luma can't read from the light itself: the DreamView group Govee Home uploaded,
// with each member's `cmd_ver`. Nothing is sent anywhere. Ported from LumaCore
// GoveeBLECapture.swift.
//
// Encrypted captures still decode, because both handshakes are protected only by
// vendor-global keys: V1's session key travels in the device's reply, and V2's
// IVs, model and MAC travel in frames sealed with the shared handshake key.
//
// Input: one frame per line, `W <hex>` for a write to `2b11` and `N <hex>` for a
// notification from `2b10`, in capture order. Hex may contain spaces or colons;
// blank lines and `#` comments are skipped. PacketLogger and Wireshark can both
// export ATT values this way.

import { DreamView, type DreamViewReading, isValidFrame, reassembleA3 } from './ble';
import { type V2Identity, parseHex, parseV1Handshake, parseV2Request, parseV2Response, unseal, v1 } from './ble-crypto';
import { LumaError } from './model';

export type MemberIdentity =
  /** Display order (the wire carries it reversed). */
  | { kind: 'mac'; mac: number[] }
  | { kind: 'name'; name: string };

export interface Member {
  isRGBIC: boolean;
  cmdVer: number;
  identity: MemberIdentity;
  /** Wire area values: 1…10, 0 unassigned, 0xFF disabled. */
  areas: number[];
}

export interface CaptureReport {
  /** undefined when no handshake or plaintext frame was seen. */
  encryption: number | undefined;
  deviceSKU: string | undefined;
  frames: number;
  decoded: number;
  undecodable: number;
  /** Every A3 `0x50` upload, oldest first. The last one is the group Govee Home saved. */
  groupUploads: Member[][];
  dreamViewReadings: DreamViewReading[];
}

/** A summary safe to show or copy: identities are reduced to their kind. */
export function captureSummary(report: CaptureReport): string {
  const { encryption, deviceSKU } = report;
  const lines = [`Encryption: ${encryption === undefined ? 'unknown' : encryption === 0 ? 'none' : `V${encryption}`}${deviceSKU === undefined ? '' : ` · ${deviceSKU}`}`,
    `Frames: ${report.frames}, decoded ${report.decoded}, undecodable ${report.undecodable}`];
  const group = report.groupUploads.at(-1);
  if (group) {
    lines.push(`DreamView group upload: ${group.length} member${group.length === 1 ? '' : 's'}`);
    group.forEach((m, i) => {
      const kind = m.identity.kind === 'mac' ? 'address' : 'name';
      lines.push(`  ${i + 1}. cmd_ver ${m.cmdVer} · ${m.isRGBIC ? 'RGBIC' : 'single colour'} · by ${kind} · areas ${m.areas.join(',')}`);
    });
  } else {
    lines.push('No DreamView group upload in this capture. Save the group in Govee Home while capturing.');
  }
  return lines.join('\n');
}

// Swift splits on Character.isNewline and trims CharacterSet.whitespaces (Zs and tab).
const newline = /\r\n|[\n\r\u000B\u000C\u0085\u2028\u2029]/;
const edgeWhitespace = /^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu;
const segmenter = new Intl.Segmenter();

/** Swift Characters: grapheme clusters. ASCII lines (no CR LF left after the split) are one per code unit. */
function characters(line: string): string[] {
  return /^[\x00-\x7F]*$/.test(line) ? [...line] : Array.from(segmenter.segment(line), (s) => s.segment);
}

export function decodeCapture(text: string): CaptureReport {
  if (Buffer.byteLength(text, 'utf8') > 16 * 1024 * 1024) throw new LumaError('That capture is too large.');
  const report: CaptureReport = { encryption: undefined, deviceSKU: undefined, frames: 0, decoded: 0, undecodable: 0, groupUploads: [], dreamViewReadings: [] };
  let v1Key: number[] | undefined, clientIV: number[] | undefined, v2: V2Identity | undefined;
  let lastDeviceCounter = 0;
  let a3: number[][] = [];

  for (const raw of text.split(newline)) {
    const chars = characters(raw.replace(edgeWhitespace, ''));
    const dir = chars[0];
    if (dir !== 'W' && dir !== 'N') continue;
    const hex = chars.slice(1).filter((c) => /^[0-9a-fA-F]$/.test(c)).join('');
    const bytes = hex.length >= 2 ? parseHex(hex) : undefined;
    if (!bytes) { report.undecodable += 1; continue; }
    report.frames += 1;
    const write = dir === 'W';

    // Handshakes first: they set the keys for everything after them.
    const iv = write ? parseV2Request(bytes) : undefined;
    if (iv) { clientIV = iv; report.encryption = 2; continue; }
    const id = write ? undefined : parseV2Response(bytes);
    if (id) { v2 = id; report.deviceSKU = id.sku; report.encryption = 2; continue; }
    const hs = parseV1Handshake(bytes);
    if (hs) {
      if (!write && hs.opcode === 1) v1Key = hs.body;
      report.encryption = 1;
      continue;
    }

    let plain: number[] | undefined;
    if (v2) {
      if (write && clientIV) plain = unseal(bytes, clientIV, v2.key)?.plain;
      if (!write) {
        const opened = unseal(bytes, v2.deviceIV, v2.key);
        if (opened && opened.counter > lastDeviceCounter) { lastDeviceCounter = opened.counter; plain = opened.plain; }
      }
    } else if (v1Key) {
      const p = v1(bytes, v1Key, false);
      if (isValidFrame(p)) plain = p;
    } else if (isValidFrame(bytes)) {
      plain = bytes;
      if (report.encryption === undefined) report.encryption = 0;
    }
    const frame = plain;
    if (!frame || !isValidFrame(frame)) { report.undecodable += 1; continue; }
    report.decoded += 1;

    if (write && frame[0] === 0xA3) {
      if (frame[1] === 0) a3 = [];
      a3.push(frame);
      if (frame[1] === 0xFF) {
        const env = reassembleA3(a3);
        const group = env && env[2] === 0x50 ? parseGroup(env.slice(3)) : undefined;
        if (group) report.groupUploads.push(group);
        a3 = [];
      }
    } else if (!write) {
      const reading = DreamView.parse(frame);
      if (reading) report.dreamViewReadings.push(reading);
    }
  }
  return report;
}

/** `count, members…, zero padding` (`h6099_dreamview_group.ksy`). */
export function parseGroup(body: number[]): Member[] | undefined {
  let i = 0;
  const next = (): number | undefined => (i < body.length ? body[i++] : undefined);
  const take = (n: number): number[] | undefined => {
    if (n < 0 || i + n > body.length) return undefined;
    const out = body.slice(i, i + n);
    i += n;
    return out;
  };
  const count = next();
  if (count === undefined || count <= 0) return undefined;
  const members: Member[] = [];
  for (let m = 0; m < count; m++) {
    const rgbic = next();
    if (rgbic === undefined || rgbic > 1) return undefined;
    const kind = next(), ver = next();
    if (kind === undefined || ver === undefined) return undefined;
    let identity: MemberIdentity;
    switch (kind) {
      case 0: {
        const mac = take(6);
        if (!mac) return undefined;
        identity = { kind: 'mac', mac: mac.reverse() };
        break;
      }
      case 1: {
        const n = next();
        const name = n === undefined ? undefined : take(n);
        if (!name) return undefined;
        let text: string;
        try { text = new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(name)); } catch { return undefined; }
        identity = { kind: 'name', name: text };
        break;
      }
      default: return undefined;
    }
    const areaCount = next();
    const areas = areaCount === undefined ? undefined : take(areaCount);
    if (!areas) return undefined;
    members.push({ isRGBIC: rgbic === 1, cmdVer: ver, identity, areas });
  }
  if (!body.slice(i).every((b) => b === 0)) return undefined;
  return members;
}

function u8(value: number): number {
  if (!Number.isInteger(value) || value < 0 || value > 255) throw new LumaError('A group record value must be 0–255.');
  return value;
}

/**
 * The exact record bytes for `members`; used to prove the parser against the
 * source's vector. Luma has no path that sends a group to a light.
 */
export function encodeGroup(members: Member[]): number[] {
  const out = [u8(members.length)];
  for (const m of members) {
    out.push(m.isRGBIC ? 1 : 0);
    switch (m.identity.kind) {
      case 'mac': out.push(0, u8(m.cmdVer), ...[...m.identity.mac].reverse().map(u8)); break;
      case 'name': {
        const b = [...new TextEncoder().encode(m.identity.name)];
        out.push(1, u8(m.cmdVer), u8(b.length), ...b);
        break;
      }
    }
    out.push(u8(m.areas.length), ...m.areas.map(u8));
  }
  return out;
}

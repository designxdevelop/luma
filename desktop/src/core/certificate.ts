// Self-signed P-256 identity for local webhook TLS. The private key must be stored securely.
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign, X509Certificate } from 'node:crypto';
import { isIP } from 'node:net';
import { hostname, networkInterfaces } from 'node:os';
import type { SecretStore } from '../main/storage';

export interface WebhookIdentity { key: string; cert: string; fingerprint: string; sans: string[]; spkiPin: string }
const cat = (...parts: Buffer[]) => Buffer.concat(parts);
function tlv(tag: number, content: Buffer): Buffer {
  let n = content.length; const bytes: number[] = [];
  while (n > 0) { bytes.unshift(n & 255); n = Math.floor(n / 256); }
  return cat(Buffer.from([tag, ...(content.length < 128 ? [content.length] : [0x80 | bytes.length, ...bytes])]), content);
}
const seq = (...x: Buffer[]) => tlv(0x30, cat(...x));
const oid = (s: string) => {
  const parts = s.split('.').map(Number); const out = [parts[0]! * 40 + parts[1]!];
  for (let v of parts.slice(2)) { const chunk = [v % 128]; v = Math.floor(v / 128); while (v) { chunk.unshift((v % 128) | 128); v = Math.floor(v / 128); } out.push(...chunk); }
  return tlv(6, Buffer.from(out));
};
const bit = (b: Buffer) => tlv(3, cat(Buffer.from([0]), b));
const octet = (b: Buffer) => tlv(4, b);
const integer = (b: Buffer) => tlv(2, b[0]! & 128 ? cat(Buffer.from([0]), b) : b);
const time = (d: Date) => { const iso = d.toISOString(); const year = d.getUTCFullYear(); const value = iso.slice(0, 19).replace(/[-:T]/g, '') + 'Z'; return tlv(year < 2050 ? 0x17 : 0x18, Buffer.from(year < 2050 ? value.slice(2) : value)); };
const ext = (id: string, value: Buffer, critical = false) => seq(oid(id), ...(critical ? [tlv(1, Buffer.from([255]))] : []), octet(value));
// Store IP SANs as bytes in hex so equivalent IPv6 spellings compare equally.
function ipBytes(address: string): Buffer {
  if (isIP(address) === 4) return Buffer.from(address.split('.').map(Number));
  const [left, right = ''] = address.toLowerCase().split('::');
  const words = (part: string): number[] => part ? part.split(':').flatMap(word => {
    if (!word.includes('.')) return [parseInt(word, 16)];
    const bytes = word.split('.').map(Number); return [bytes[0]! * 256 + bytes[1]!, bytes[2]! * 256 + bytes[3]!];
  }) : [];
  const a = words(left!); const b = words(right);
  const all = address.includes('::') ? [...a, ...Array(8 - a.length - b.length).fill(0), ...b] : a;
  const bytes = Buffer.alloc(16); all.forEach((word, i) => bytes.writeUInt16BE(word, i * 2)); return bytes;
}
export function webhookSans(allowLAN: boolean, interfaces = networkInterfaces(), host = hostname()): string[] {
  const names = new Set(['DNS:localhost', `IP:${ipBytes('127.0.0.1').toString('hex')}`, `IP:${ipBytes('::1').toString('hex')}`]);
  if (allowLAN) {
    if (host && !host.includes('.')) names.add(`DNS:${host.toLowerCase()}.local`);
    for (const entries of Object.values(interfaces)) for (const entry of entries ?? []) {
      const address = entry.address.split('%')[0]!; const family = isIP(address);
      if (!family || entry.internal) continue;
      const bytes = ipBytes(address);
      if (family === 4 && (bytes[0] === 127 || (bytes[0] === 169 && bytes[1] === 254))) continue;
      if (family === 6 && ((bytes[0] === 0xfe && (bytes[1]! & 0xc0) === 0x80) || bytes.equals(ipBytes('::1')))) continue;
      names.add(`IP:${bytes.toString('hex')}`);
    }
  }
  return [...names].sort();
}
export function generateWebhookIdentity(now = new Date(), sans = webhookSans(false)): WebhookIdentity {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const serial = randomBytes(16); serial[0] = (serial[0]! & 0x7f) | 1;
  const name = seq(tlv(0x31, seq(oid('2.5.4.3'), tlv(0x0c, Buffer.from('Luma local webhooks')))));
  const algorithm = seq(oid('1.2.840.10045.4.3.2'));
  const san = seq(...sans.map(name => name.startsWith('DNS:') ? tlv(0x82, Buffer.from(name.slice(4))) : tlv(0x87, Buffer.from(name.slice(3), 'hex'))));
  const extensions = seq(ext('2.5.29.17', san), ext('2.5.29.37', seq(oid('1.3.6.1.5.5.7.3.1'))), ext('2.5.29.19', seq(), true), ext('2.5.29.15', Buffer.from([3, 2, 7, 0x80]), true));
  const tbs = seq(tlv(0xa0, integer(Buffer.from([2]))), integer(serial), algorithm, name, seq(time(new Date(now.getTime() - 3600000)), time(new Date(now.getTime() + 824 * 86400000))), name, publicKey.export({ type: 'spki', format: 'der' }), tlv(0xa3, extensions));
  const der = seq(tbs, algorithm, bit(sign('sha256', tbs, privateKey)));
  const cert = `-----BEGIN CERTIFICATE-----\n${der.toString('base64').match(/.{1,64}/g)!.join('\n')}\n-----END CERTIFICATE-----\n`;
  const key = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  return { key, cert, fingerprint: fingerprint(der), sans, spkiPin: spkiPin(createPublicKey(key)) };
}
export function fingerprint(der: Buffer): string { return createHash('sha256').update(der).digest('hex').toUpperCase().match(/../g)!.join(':'); }
export function spkiPin(publicKey: ReturnType<typeof createPublicKey>): string { return `sha256//${createHash('sha256').update(publicKey.export({ type: 'spki', format: 'der' })).digest('base64')}`; }
/** A single encrypted record prevents a partial write from mismatching the key and certificate. */
export function loadWebhookIdentity(secrets: SecretStore | undefined, demo = false, now = new Date(), sans = webhookSans(false)): WebhookIdentity {
  if (demo) return generateWebhookIdentity(now, sans);
  if (!secrets?.available) throw new Error('Secure storage is unavailable; the webhook server cannot start.');
  const saved = secrets.read('webhook-tls');
  if (saved) {
    try {
      const identity = JSON.parse(saved) as WebhookIdentity; const cert = new X509Certificate(identity.cert);
      if (JSON.stringify(identity.sans) === JSON.stringify(sans) && cert.checkPrivateKey(createPrivateKey(identity.key)) && Date.parse(cert.validTo) > now.getTime() + 7 * 86400000 && Date.parse(cert.validFrom) <= now.getTime()) return { ...identity, fingerprint: fingerprint(cert.raw), spkiPin: spkiPin(cert.publicKey) };
    } catch { /* replace invalid or expired identity */ }
  }
  const identity = generateWebhookIdentity(now, sans); secrets.write('webhook-tls', JSON.stringify(identity)); return identity;
}

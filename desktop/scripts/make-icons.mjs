// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Generates the app and tray icons (an amber light orb) as PNGs with no dependencies.
// Run: node scripts/make-icons.mjs  (outputs are checked in under assets/)

import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc = (buf) => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
};

function orb(size) {
  const rows = [];
  const c = (size - 1) / 2, r = size * 0.42;
  for (let y = 0; y < size; y++) {
    const row = Buffer.alloc(1 + size * 4);
    for (let x = 0; x < size; x++) {
      const d = Math.hypot(x - c, y - c);
      const edge = Math.max(0, Math.min(1, r - d + 0.5));
      // Warm radial gradient with a soft highlight toward the upper left.
      const h = Math.max(0, 1 - Math.hypot(x - c * 0.7, y - c * 0.7) / (r * 1.3));
      const R = 255, G = Math.round(150 + 80 * h), B = Math.round(40 + 120 * h * h);
      row.set([R, G, B, Math.round(255 * edge)], 1 + x * 4);
    }
    rows.push(row);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr.set([8, 6, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(Buffer.concat(rows))), chunk('IEND', Buffer.alloc(0))]);
}

mkdirSync('assets', { recursive: true });
writeFileSync('assets/icon.png', orb(256));
writeFileSync('assets/tray.png', orb(32));
console.log('Wrote assets/icon.png and assets/tray.png');

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Screen Sync worker: downsamples one transferred frame on an OffscreenCanvas, computes
// region averages, closes the frame, and posts back only those averages. Pixels never
// leave this worker and nothing is stored.

import { regionAverages } from '../shared/sync-math.js';

const W = 96, H = 54; // bounded analysis resolution
const canvas = new OffscreenCanvas(W, H);
const ctx = canvas.getContext('2d', { willReadFrequently: true, colorSpace: 'srgb' })!;
const scope = self as unknown as { onmessage: ((e: MessageEvent<{ seq: number; frame: ImageBitmap | VideoFrame }>) => void) | null; postMessage(m: unknown): void };

scope.onmessage = (event) => {
  const { seq, frame } = event.data;
  try {
    ctx.clearRect(0, 0, W, H);
    ctx.drawImage(frame, 0, 0, W, H);
    frame.close();
    const pixels = ctx.getImageData(0, 0, W, H, { colorSpace: 'srgb' }).data;
    scope.postMessage({ seq, regions: regionAverages(pixels, W, H) });
  } catch {
    try { frame.close(); } catch { /* already closed */ }
    scope.postMessage({ seq, error: true });
  }
};

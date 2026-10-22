// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Screen Sync frame pump. Samples at most ~30 frames per second, one frame in the worker
// and one IPC call in flight at a time (latest only; extra frames are skipped, never
// queued). Demo uses generated synthetic frames and never calls getDisplayMedia.
// Real capture asks only for video, never audio, and stops every track on Stop.

import type { LumaBridge, SyncGrant, SyncGrid } from '../shared/types';

const SAMPLE_MS = 1000 / 30;
const WORKER_TIMEOUT_MS = 3000;
type EndReason = 'ended' | 'muted' | 'denied' | 'worker' | 'hidden';

export class FramePump {
  private worker?: Worker;
  private stream?: MediaStream;
  private video?: HTMLVideoElement;
  private timer?: number;
  private watchdog?: number;
  private grant?: SyncGrant;
  private seq = 0;
  private inWorker = false;
  private inIPC = false;
  private paused = false;
  private t0 = 0;
  private synthetic?: OffscreenCanvas;

  constructor(private readonly luma: LumaBridge) {}

  get live(): boolean { return this.grant !== undefined; }
  get generation(): number | undefined { return this.grant?.generation; }
  get token(): string | undefined { return this.grant?.token; }

  /**
   * Call immediately after syncStart resolves (no other awaits), so getDisplayMedia
   * still has the click's user activation.
   */
  async start(grant: SyncGrant, demo: boolean): Promise<void> {
    this.stop();
    this.grant = grant;
    this.worker = new Worker(new URL('./screen-worker.js', import.meta.url), { type: 'module' });
    this.worker.onmessage = (e: MessageEvent<{ seq: number; grid?: SyncGrid; error?: boolean }>) => {
      if (this.grant === grant) this.analyzed(e.data);
    };
    this.worker.onerror = () => { if (this.grant === grant) this.end('worker'); };
    if (grant.synthetic || demo) {
      // Demo: generated frames only. Never capture this machine's screen.
      this.synthetic = new OffscreenCanvas(64, 36);
      this.t0 = performance.now();
    } else {
      // Every await below can outlive this grant (Stop, a newer Start): re-check it after each one,
      // release anything that arrives late, and only let this grant's callbacks end this grant.
      const mine = () => this.grant === grant;
      const endMine = (reason: EndReason) => () => { if (mine()) this.end(reason); };
      let stream: MediaStream;
      try {
        stream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 30, max: 30 } }, audio: false });
      } catch {
        endMine('denied')();
        return;
      }
      const track = stream.getVideoTracks()[0];
      if (!mine() || !track || stream.getAudioTracks().length > 0) {
        stream.getTracks().forEach((t) => t.stop());
        endMine('denied')();
        return;
      }
      // Paused while the picker was open: adopt the stream disabled; Resume enables it.
      track.enabled = !this.paused;
      this.stream = stream;
      track.addEventListener('ended', endMine('ended'), { once: true });
      // Muted = the OS stopped delivering frames (lock, source hidden or gone). Black frames
      // would otherwise keep the session alive, so end safely; the user starts again.
      track.addEventListener('mute', endMine('muted'), { once: true });
      const video = document.createElement('video');
      video.muted = true;
      video.srcObject = stream;
      this.video = video;
      try { await video.play(); } catch { endMine('ended')(); return; }
      if (!mine()) return; // stop() already released this stream and video
    }
    this.schedule(grant);
  }

  pause(): void {
    this.paused = true;
    this.stream?.getVideoTracks().forEach((t) => { t.enabled = false; });
  }

  /** Only resumes the session the token belongs to. */
  resume(token: string): void {
    if (!this.grant || this.grant.token !== token) return;
    this.paused = false;
    this.stream?.getVideoTracks().forEach((t) => { t.enabled = true; });
  }

  /** Releases everything: tracks, video, worker (and any frame it holds), timers. */
  stop(): void {
    this.grant = undefined;
    clearTimeout(this.timer);
    clearTimeout(this.watchdog);
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = undefined;
    if (this.video) { this.video.pause(); this.video.srcObject = null; this.video = undefined; }
    this.worker?.terminate();
    this.worker = undefined;
    this.synthetic = undefined;
    this.inWorker = this.inIPC = this.paused = false;
  }

  private end(reason: EndReason): void {
    const token = this.grant?.token;
    this.stop();
    if (token) void this.luma.syncEnded(token, reason).catch(() => {});
  }

  private schedule(grant: SyncGrant): void {
    if (this.grant === grant) this.timer = window.setTimeout(() => { if (this.grant === grant) void this.tick(grant); }, SAMPLE_MS);
  }

  private async tick(grant: SyncGrant): Promise<void> {
    if (this.grant !== grant) return;
    if (!this.paused && !this.inWorker && document.visibilityState === 'visible') {
      let frame: ImageBitmap | undefined;
      try { frame = await this.grab(); } catch { frame = undefined; }
      if (this.grant !== grant) { frame?.close(); return; }
      if (frame && (!this.worker || this.paused)) frame.close();
      else if (frame) {
        this.inWorker = true;
        this.worker!.postMessage({ seq: ++this.seq, frame }, [frame]);
        this.watchdog = window.setTimeout(() => this.end('worker'), WORKER_TIMEOUT_MS);
      }
    }
    this.schedule(grant);
  }

  private async grab(): Promise<ImageBitmap | undefined> {
    if (this.synthetic) return createImageBitmap(syntheticFrame(this.synthetic, (performance.now() - this.t0) / 1000));
    const video = this.video;
    if (!video || video.readyState < 2 || !video.videoWidth) return undefined;
    return createImageBitmap(video, { resizeWidth: 96, resizeHeight: 54, resizeQuality: 'low' });
  }

  private analyzed(data: { seq: number; grid?: SyncGrid; error?: boolean }): void {
    clearTimeout(this.watchdog);
    this.inWorker = false;
    const grant = this.grant;
    if (!grant || data.seq !== this.seq || !data.grid || this.paused || this.inIPC) return; // stale or busy: dropped
    this.inIPC = true;
    void this.luma.syncFrame(grant.token, grant.generation, data.seq, data.grid)
      .catch(() => false)
      .finally(() => { if (this.grant === grant) this.inIPC = false; });
  }
}

/** Animated synthetic picture with letterbox bars: warm left, cool right, slowly drifting. */
function syntheticFrame(canvas: OffscreenCanvas, t: number): OffscreenCanvas {
  const ctx = canvas.getContext('2d')!;
  const { width: w, height: h } = canvas;
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, w, h);
  const hue = (t * 12) % 360;
  const g = ctx.createLinearGradient(0, 0, w, 0);
  g.addColorStop(0, `hsl(${hue}, 85%, ${45 + 15 * Math.sin(t / 2)}%)`);
  g.addColorStop(1, `hsl(${(hue + 160) % 360}, 80%, ${40 + 15 * Math.cos(t / 3)}%)`);
  ctx.fillStyle = g;
  ctx.fillRect(0, 5, w, h - 10); // 5 px bars top and bottom
  return canvas;
}

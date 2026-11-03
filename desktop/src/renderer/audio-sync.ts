// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Audio Sync analysis pump. Captures real computer audio (system loopback through
// getDisplayMedia, or the default input through getUserMedia), analyzes it with a Web Audio
// AnalyserNode, and sends only 9 numbers (loudness + 8 bands, 0…1) to main 20 times a second,
// one IPC call in flight at a time (latest only). Audio is never played back, recorded, saved
// or sent anywhere else: the graph ends at the analyser, never at the speakers. Stop releases
// every track, node and the AudioContext. There is no synthetic or demo signal.

import type { AudioGrant, LumaBridge } from '../shared/types';
import { bandLevels, rmsLevel, type AudioLevels } from '../shared/audio-math.js';

/** Sent even during silence, so a quiet passage never trips main's stall watchdog. */
const SEND_MS = 50;
/** Raw signal for analysis: browser voice processing would flatten music. */
const RAW = { echoCancellation: false, noiseSuppression: false, autoGainControl: false } as const;
export type AudioEndReason = 'ended' | 'denied' | 'no-audio' | 'worker';

export class AudioPump {
  private grant?: AudioGrant;
  private stream?: MediaStream;
  private ctx?: AudioContext;
  private nodes: AudioNode[] = [];
  private analyser?: AnalyserNode;
  private freq?: Float32Array<ArrayBuffer>;
  private time?: Float32Array<ArrayBuffer>;
  private timer?: number;
  private seq = 0;
  private inIPC = false;
  private paused = false;

  constructor(private readonly luma: LumaBridge, private readonly onLevels: (levels: AudioLevels | undefined) => void) {}

  get live(): boolean { return this.grant !== undefined; }
  get generation(): number | undefined { return this.grant?.generation; }
  get token(): string | undefined { return this.grant?.token; }

  /** Call immediately after audioStart resolves (no other awaits), so capture keeps the click's user activation. */
  async start(grant: AudioGrant): Promise<void> {
    this.stop();
    this.grant = grant;
    const mine = () => this.grant === grant;
    let stream: MediaStream;
    try {
      stream = grant.source === 'system'
        ? await navigator.mediaDevices.getDisplayMedia({ video: true, audio: RAW })
        : await navigator.mediaDevices.getUserMedia({ audio: RAW, video: false });
    } catch {
      if (mine()) this.end('denied');
      return;
    }
    // getDisplayMedia requires video; main answers with Luma's own page. It is never used.
    for (const t of stream.getVideoTracks()) { t.stop(); stream.removeTrack(t); }
    const track = stream.getAudioTracks()[0];
    if (!mine() || !track) {
      stream.getTracks().forEach((t) => t.stop());
      if (mine()) this.end(grant.source === 'system' ? 'no-audio' : 'denied');
      return;
    }
    this.stream = stream;
    track.enabled = !this.paused;
    track.addEventListener('ended', () => { if (mine()) this.end('ended'); }, { once: true });
    try {
      const ctx = new AudioContext({ latencyHint: 'interactive' });
      this.ctx = ctx;
      const source = ctx.createMediaStreamSource(stream), analyser = ctx.createAnalyser();
      analyser.fftSize = 2048; // ~23 Hz bins at 48 kHz: the 40–84 Hz bass band still gets 2 bins
      analyser.smoothingTimeConstant = 0; // main smooths with attack/release
      source.connect(analyser); // never to ctx.destination: no echo, no doubled audio
      this.nodes = [source, analyser];
      this.analyser = analyser;
      this.freq = new Float32Array(analyser.frequencyBinCount);
      this.time = new Float32Array(analyser.fftSize);
      if (!this.paused) await ctx.resume();
    } catch {
      if (mine()) this.end('worker');
      return;
    }
    if (mine()) this.schedule(grant);
  }

  pause(): void {
    this.paused = true;
    this.stream?.getAudioTracks().forEach((t) => { t.enabled = false; });
    void this.ctx?.suspend().catch(() => {});
    this.onLevels(undefined);
  }

  /** Only resumes the session the token belongs to. */
  resume(token: string): void {
    if (!this.grant || this.grant.token !== token) return;
    this.paused = false;
    this.stream?.getAudioTracks().forEach((t) => { t.enabled = true; });
    void this.ctx?.resume().catch(() => {});
  }

  /** Releases everything: tracks, audio graph, AudioContext and timers. */
  stop(): void {
    this.grant = undefined;
    clearTimeout(this.timer);
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = undefined;
    for (const n of this.nodes) { try { n.disconnect(); } catch { /* already disconnected */ } }
    this.nodes = [];
    this.analyser = undefined;
    this.freq = this.time = undefined;
    const ctx = this.ctx;
    this.ctx = undefined;
    if (ctx && ctx.state !== 'closed') void ctx.close().catch(() => {});
    this.inIPC = this.paused = false;
    this.onLevels(undefined);
  }

  private end(reason: AudioEndReason): void {
    const token = this.grant?.token;
    this.stop();
    if (token) void this.luma.syncEnded(token, reason).catch(() => {});
  }

  private schedule(grant: AudioGrant): void {
    if (this.grant === grant) this.timer = window.setTimeout(() => this.tick(grant), SEND_MS);
  }

  private tick(grant: AudioGrant): void {
    if (this.grant !== grant) return;
    if (this.ctx?.state === 'closed') { this.end('worker'); return; }
    const analyser = this.analyser, freq = this.freq, time = this.time;
    if (!this.paused && analyser && freq && time && this.ctx) {
      analyser.getFloatFrequencyData(freq);
      analyser.getFloatTimeDomainData(time);
      const levels: AudioLevels = { level: rmsLevel(time), bands: bandLevels(freq, this.ctx.sampleRate) };
      this.onLevels(levels);
      if (!this.inIPC) {
        this.inIPC = true;
        void this.luma.audioLevels(grant.token, grant.generation, ++this.seq, levels)
          .catch(() => false)
          .finally(() => { if (this.grant === grant) this.inIPC = false; });
      }
    }
    this.schedule(grant);
  }
}

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Audio Sync capture policy. Electron-free so it can be tested; capture.ts owns the single
// display-media and permission handlers and asks this module what an audio session may get.
//
// - System audio: getDisplayMedia answered with { video: our own frame, audio: 'loopback' }.
//   Electron documents loopback for Windows; Linux is attempted (Chromium's PulseAudio/PipeWire
//   loopback) and labelled experimental. No screen or window is ever offered to an audio session;
//   the renderer stops the video track of its own page at once.
// - Input: getUserMedia for audio only, from the default recording device.
// - Either way the grant is single use, tied to the session generation, and short lived.

import type { AudioSource, AudioSupport } from '../shared/types';

/** Which audio paths a platform offers. Audio Sync always captures real audio, demo or not. */
export function audioSupportFor(platform: NodeJS.Platform): AudioSupport {
  const system = platform === 'win32' || platform === 'linux';
  return { system, systemExperimental: platform === 'linux', input: platform === 'win32' || platform === 'linux' || platform === 'darwin' };
}

export class AudioGrants {
  private grant?: { source: AudioSource; generation: number; expires: number };
  private readonly now: () => number;
  private readonly grantMs: number;

  constructor(options: { now?: () => number; grantMs?: number } = {}) {
    this.now = options.now ?? Date.now;
    this.grantMs = options.grantMs ?? 10_000;
  }

  issue(source: AudioSource, generation: number): void { this.grant = { source, generation, expires: this.now() + this.grantMs }; }

  /** The live grant's source, without using it (permission checks). */
  peek(generation: number): AudioSource | undefined {
    const g = this.grant;
    return g && g.generation === generation && g.expires >= this.now() ? g.source : undefined;
  }

  /** Single use: always clears the grant. */
  consume(generation: number): AudioSource | undefined {
    const source = this.peek(generation);
    this.grant = undefined;
    return source;
  }

  revoke(): void { this.grant = undefined; }
}

/** getUserMedia for an input-source audio session asks for audio and nothing else. */
export function audioOnly(mediaTypes: readonly string[] | undefined): boolean {
  return !!mediaTypes && mediaTypes.length > 0 && mediaTypes.every((t) => t === 'audio');
}

export interface DisplayRequest {
  /** The request comes from our top-level renderer document. */
  trustedFrame: boolean;
  userGesture: boolean;
  videoRequested: boolean;
  audioRequested: boolean;
}

export interface DisplayContext {
  sessionKind: 'screen' | 'audio';
  /** The live session is still waiting for its capture. */
  awaiting: boolean;
  /** False while a Linux lock observer reports locked or unknown. */
  unlocked: boolean;
  /** Real screen capture is enabled (connected mode on Windows/Linux). */
  realScreen: boolean;
  systemAudio: boolean;
  /** Already consumed single-use grants for this generation. */
  screenGrant?: { id: string; name: string };
  audioGrant?: AudioSource;
}

export type DisplayDecision = { kind: 'refuse' } | { kind: 'screen'; source: { id: string; name: string } } | { kind: 'loopback' };

/**
 * One getDisplayMedia request. A screen session gets only its chosen source, video only; an
 * audio session gets only system-audio loopback (with our own page as the required video).
 * Neither ever gets the other's capture.
 */
export function displayMediaDecision(req: DisplayRequest, ctx: DisplayContext): DisplayDecision {
  if (!req.trustedFrame || !req.userGesture || !req.videoRequested || !ctx.awaiting || !ctx.unlocked) return { kind: 'refuse' };
  if (ctx.sessionKind === 'screen') return ctx.realScreen && !req.audioRequested && ctx.screenGrant ? { kind: 'screen', source: ctx.screenGrant } : { kind: 'refuse' };
  return ctx.systemAudio && req.audioRequested && ctx.audioGrant === 'system' ? { kind: 'loopback' } : { kind: 'refuse' };
}

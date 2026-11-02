// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Screen Sync capture adapter for Windows and Linux (Electron desktopCapturer +
// getDisplayMedia). On Linux Wayland, getSources opens the xdg-desktop-portal picker, so
// that pick is the user's explicit choice and is not re-enumerated at Start; X11 and
// Windows re-enumerate. Platform specifics stay here and in linux-platform.ts; sync.ts,
// stream.ts and sync-math.ts are platform-neutral (a macOS adapter could reuse them).
//
// - Sources are enumerated only when the user asks, without thumbnails or icons.
// - getDisplayMedia is granted only to our top-level renderer, video only, with a user
//   gesture, for the single source chosen and re-validated at Start (single-use grant).
// - Linux has no powerMonitor lock event, so a systemd-logind lock observer (linux-lock.ts) gates every
//   enumeration and Start and stops the session on lock or on losing the observer.
// - Demo and non-Windows: desktopCapturer is never called and every request is refused.
// - Audio Sync shares these handlers (Electron allows one of each): an audio session gets only
//   system-audio loopback or an audio-only microphone/input grant, never a screen or window
//   (policy in audio-capture.ts). Audio Sync always uses real audio, including in demo.

import { desktopCapturer, powerMonitor, screen, session, type BrowserWindow, type WebContents } from 'electron';
import { CaptureGrants, type SyncController } from './sync';
import { createLinuxLockMonitor } from './linux-lock';
import { AudioGrants, audioOnly, displayMediaDecision } from './audio-capture';
import { LumaError } from '../core/model';
import type { AudioSupport } from '../shared/types';

const SYNTHETIC = [
  { id: 'synthetic:film', name: 'Synthetic film (demo)', kind: 'screen' as const },
  { id: 'synthetic:game', name: 'Synthetic game (demo)', kind: 'window' as const },
];

export interface CaptureAdapterOptions {
  real: boolean;
  /** False where enumeration is the OS picker itself (Linux Wayland portal). */
  revalidate: boolean;
  sync: SyncController;
  window: () => BrowserWindow | undefined;
  rendererURL: () => string;
  audioSupport: AudioSupport;
}

export function createCaptureAdapter({ real, revalidate, sync, window, rendererURL, audioSupport }: CaptureAdapterOptions) {
  const audio = new AudioGrants();
  const grants = new CaptureGrants(real
    ? async () => (await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 0, height: 0 }, fetchWindowIcons: false }))
      // Our own windows (window:<id>:1) are useless to sample.
      .filter((s) => !/^window:\d+:1$/.test(s.id))
      .map((s) => ({ id: s.id, name: s.name, kind: s.id.startsWith('screen:') ? 'screen' as const : 'window' as const }))
    : async () => SYNTHETIC, { revalidate });

  // Real Linux only (undefined for demo, Windows and macOS): nothing is enumerated or started unless
  // the observer affirms "unlocked", and a lock or a lost observer revokes and stops like a sleep.
  const lock = createLinuxLockMonitor({ real, platform: process.platform, env: process.env, needed: () => sync.active });
  const guarded = <T>(run: (confirm: () => void) => Promise<T>) => lock ? lock.guard(run) : run(() => {});

  const ours = (wc: WebContents | null | undefined) => { const win = window(); return !!win && !win.isDestroyed() && wc === win.webContents; };

  session.defaultSession.setDisplayMediaRequestHandler((request, callback) => {
    const win = window(), frame = request.frame, main = win && !win.isDestroyed() ? win.webContents.mainFrame : undefined;
    const trustedFrame = !!frame && !!main && frame.processId === main.processId && frame.routingId === main.routingId && frame.url === rendererURL();
    // Both grants are single use, whatever the outcome.
    const screenGrant = grants.consume(sync.generation), audioGrant = audio.consume(sync.generation);
    const decision = displayMediaDecision(
      { trustedFrame, userGesture: request.userGesture, videoRequested: request.videoRequested, audioRequested: request.audioRequested },
      { sessionKind: sync.kind, awaiting: sync.awaitingCapture(sync.generation), unlocked: !lock || lock.unlocked, realScreen: real, systemAudio: audioSupport.system, screenGrant, audioGrant },
    );
    if (decision.kind === 'screen') callback({ video: { id: decision.source.id, name: decision.source.name } });
    // Our own page satisfies getDisplayMedia's required video; the renderer stops that track at once.
    else if (decision.kind === 'loopback' && frame) callback({ video: frame, audio: 'loopback' });
    else callback(null);
  });

  // Display capture for a screen session (or system audio), audio-only media for an input audio
  // session; only for our window while a session waits for or holds its capture.
  const allow = (wc: WebContents | null, permission: string, mediaTypes?: readonly string[]) => {
    if (!ours(wc) || !sync.active) return false;
    if (permission === 'display-capture') return sync.kind === 'screen' ? real : audioSupport.system;
    return permission === 'media' && sync.kind === 'audio' && audioOnly(mediaTypes) && (sync.phase !== 'starting' || audio.peek(sync.generation) === 'input');
  };
  session.defaultSession.setPermissionRequestHandler((wc, permission, cb, details) => {
    const mediaTypes = (details as { mediaTypes?: string[] }).mediaTypes;
    const ok = allow(wc, permission, mediaTypes) && (permission !== 'media' || audio.consume(sync.generation) === 'input');
    cb(ok);
  });
  session.defaultSession.setPermissionCheckHandler((wc, permission, _origin, details) => allow(wc, permission, (details as { mediaType?: string }).mediaType ? [(details as { mediaType: string }).mediaType] : undefined));

  // Lock, sleep and display changes stop the session. Nothing restarts capture afterwards.
  // Offered sources are revoked even when idle: on Wayland a listed source is not re-enumerated at Start.
  const stop = (reason: string) => () => { grants.revoke(); audio.revoke(); if (sync.active) void sync.stop(reason); };
  powerMonitor.on('suspend', stop('The PC went to sleep.'));
  powerMonitor.on('lock-screen', stop('The PC was locked.'));
  lock?.onLock((kind) => stop(kind === 'locked' ? 'The PC was locked.' : 'Screen lock detection stopped working.')());
  // Display changes end a screen session only; audio does not depend on the displays.
  for (const event of ['display-added', 'display-removed', 'display-metrics-changed'] as const) screen.on(event as 'display-added', () => { if (sync.kind === 'screen') stop('Displays changed.')(); else grants.revoke(); });

  return {
    list: () => guarded(() => grants.list()),
    /** Re-validates the chosen source, starts the session and issues the single-use grant. */
    start: (sourceKey: unknown, lights: unknown) => guarded(async (confirm) => {
      const source = await grants.resolve(sourceKey);
      grants.current(source.epoch); // a revoke after resolve settled must not start a session
      confirm(); // a lock seen while resolving must not start a session either
      const { token, generation } = sync.start(lights, source.name);
      if (real) grants.issue(source, generation);
      return { token, generation, synthetic: !real };
    }),
    /** Starts an Audio Sync session and issues its single-use capture grant. */
    startAudio: (source: unknown, lights: unknown, options: unknown) => guarded(async (confirm) => {
      if (source !== 'system' && source !== 'input') throw new LumaError('Invalid audio source.');
      if (!audioSupport[source]) throw new LumaError(source === 'system' ? 'Computer audio capture is not available on this system. Choose Default input.' : 'Audio input is not available on this system.');
      if (sync.active) throw new LumaError('Screen or Audio Sync is already active. Stop it first.', 409);
      if (options !== undefined) sync.setAudio(options);
      confirm();
      grants.revoke();
      const { token, generation } = sync.start(lights, source === 'system' ? 'Computer audio' : 'Default audio input', 'audio');
      audio.issue(source, generation);
      return { token, generation, source };
    }),
    revoke: () => { grants.revoke(); audio.revoke(); },
    dispose: () => lock?.dispose(),
  };
}

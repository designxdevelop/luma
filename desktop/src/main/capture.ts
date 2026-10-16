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

import { desktopCapturer, powerMonitor, screen, session, type BrowserWindow, type WebContents } from 'electron';
import { CaptureGrants, type SyncController } from './sync';
import { createLinuxLockMonitor } from './linux-lock';

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
}

export function createCaptureAdapter({ real, revalidate, sync, window, rendererURL }: CaptureAdapterOptions) {
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
    const trusted = real && !!frame && !!main && frame.processId === main.processId && frame.routingId === main.routingId &&
      frame.url === rendererURL() && request.videoRequested && !request.audioRequested && request.userGesture;
    const source = grants.consume(sync.generation); // single use, whatever the outcome
    if (!trusted || !source || (lock && !lock.unlocked) || !sync.awaitingCapture(sync.generation)) { callback(null); return; }
    callback({ video: { id: source.id, name: source.name } });
  });

  // Only display capture, only for our window while a session waits for or holds its capture.
  const allow = (wc: WebContents | null, permission: string) => real && permission === 'display-capture' && ours(wc) && sync.active;
  session.defaultSession.setPermissionRequestHandler((wc, permission, cb) => cb(allow(wc, permission)));
  session.defaultSession.setPermissionCheckHandler((wc, permission) => allow(wc, permission));

  // Lock, sleep and display changes stop the session. Nothing restarts capture afterwards.
  // Offered sources are revoked even when idle: on Wayland a listed source is not re-enumerated at Start.
  const stop = (reason: string) => () => { grants.revoke(); if (sync.active) void sync.stop(reason); };
  powerMonitor.on('suspend', stop('The PC went to sleep.'));
  powerMonitor.on('lock-screen', stop('The PC was locked.'));
  lock?.onLock((kind) => stop(kind === 'locked' ? 'The PC was locked.' : 'Screen lock detection stopped working.')());
  for (const event of ['display-added', 'display-removed', 'display-metrics-changed'] as const) screen.on(event as 'display-added', stop('Displays changed.'));

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
    revoke: () => grants.revoke(),
    dispose: () => lock?.dispose(),
  };
}

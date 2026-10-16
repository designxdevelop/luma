// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Linux session / secret-backend / capture-portal policy. Pure and Electron-free: main.ts
// passes Electron values in, so these helpers run under plain node tests.

export type LinuxSession = 'wayland' | 'x11' | 'unknown';

/** XDG_SESSION_TYPE wins; WAYLAND_DISPLAY then DISPLAY are fallbacks (XWayland sets both, so Wayland is checked first). */
export function linuxSessionType(env: Record<string, string | undefined>): LinuxSession {
  const declared = env.XDG_SESSION_TYPE?.trim().toLowerCase();
  if (declared === 'wayland' || declared === 'x11') return declared;
  // 'tty', 'mir', '' and anything else are not trusted: infer from the display variables.
  if (env.WAYLAND_DISPLAY?.trim()) return 'wayland';
  if (env.DISPLAY?.trim()) return 'x11';
  return 'unknown';
}

/**
 * Chromium switches to append before app 'ready' when running connected on this session.
 * Wayland: ask Chromium for the PipeWire (xdg-desktop-portal) capturer. The Electron desktopCapturer docs
 * list no required Linux switch, and this flag is not validated on a real compositor by this project
 * (EXPERIMENTAL; harmless if Chromium already defaults it on). X11 and unknown need none.
 * `--no-sandbox` is never returned. Callers must merge into any existing `enable-features` value,
 * because app.commandLine.appendSwitch replaces rather than appends.
 */
export function linuxCaptureSwitches(session: LinuxSession): Array<[name: string, value?: string]> {
  return session === 'wayland' ? [['enable-features', 'WebRTCPipeWireCapturer']] : [];
}

/**
 * Wayland: desktopCapturer.getSources() itself opens the portal picker (the user's explicit choice) and
 * returns that one source; enumerating again at Start would open a second picker, so do not.
 * X11: enumeration is silent, so re-enumerate and re-validate like Windows.
 * Unknown: true. Unknown has no portal evidence, so treat it like X11 (silent enumeration, fresh
 * validation); a source that cannot be re-found fails closed, which is the safe side.
 */
export function linuxRevalidatesSources(session: LinuxSession): boolean {
  return session !== 'wayland';
}

/** Real keyrings only. basic_text (plaintext), unknown and anything unrecognized are refused. */
const SECURE_BACKENDS: ReadonlySet<string> = new Set(['gnome_libsecret', 'kwallet', 'kwallet5', 'kwallet6']);
export function isSecureLinuxBackend(backend: string): boolean {
  return typeof backend === 'string' && SECURE_BACKENDS.has(backend);
}

/** Connected-mode secrets require both Electron's availability flag and a real keyring backend. */
export function linuxSecretsAvailable(encryptionAvailable: boolean, backend: string): boolean {
  return encryptionAvailable === true && isSecureLinuxBackend(backend);
}

/** Separate from the Windows profile so the two never share state. */
export const LINUX_PROFILE_DIR = 'LumaLinux';

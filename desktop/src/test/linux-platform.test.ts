import test from 'node:test';
import assert from 'node:assert/strict';
import {
  LINUX_PROFILE_DIR, isSecureLinuxBackend, linuxCaptureSwitches, linuxRevalidatesSources,
  linuxSecretsAvailable, linuxSessionType,
} from '../main/linux-platform';

test('session classification: XDG_SESSION_TYPE first, then WAYLAND_DISPLAY, then DISPLAY', () => {
  assert.equal(linuxSessionType({ XDG_SESSION_TYPE: 'wayland' }), 'wayland');
  assert.equal(linuxSessionType({ XDG_SESSION_TYPE: 'X11' }), 'x11');
  assert.equal(linuxSessionType({ XDG_SESSION_TYPE: ' Wayland ', DISPLAY: ':0' }), 'wayland');
  // Declared x11 wins over a stray WAYLAND_DISPLAY.
  assert.equal(linuxSessionType({ XDG_SESSION_TYPE: 'x11', WAYLAND_DISPLAY: 'wayland-0' }), 'x11');
  // XWayland exports both: Wayland is the real session.
  assert.equal(linuxSessionType({ WAYLAND_DISPLAY: 'wayland-0', DISPLAY: ':0' }), 'wayland');
  assert.equal(linuxSessionType({ DISPLAY: ':99' }), 'x11');
  // tty/mir/empty/garbage are not trusted and fall through.
  assert.equal(linuxSessionType({ XDG_SESSION_TYPE: 'tty', DISPLAY: ':0' }), 'x11');
  assert.equal(linuxSessionType({ XDG_SESSION_TYPE: 'tty' }), 'unknown');
  assert.equal(linuxSessionType({ XDG_SESSION_TYPE: '', WAYLAND_DISPLAY: '  ', DISPLAY: '' }), 'unknown');
  assert.equal(linuxSessionType({}), 'unknown');
});

test('secure secret backends: only real keyrings are allowed', () => {
  for (const ok of ['gnome_libsecret', 'kwallet', 'kwallet5', 'kwallet6']) assert.equal(isSecureLinuxBackend(ok), true, ok);
  for (const bad of ['basic_text', 'unknown', '', 'KWALLET', 'kwallet7', 'gnome_libsecret ', 'gnome-libsecret', 'plain', '__proto__', 'constructor']) {
    assert.equal(isSecureLinuxBackend(bad), false, bad);
  }
  assert.equal(isSecureLinuxBackend(undefined as unknown as string), false);
  assert.equal(isSecureLinuxBackend(null as unknown as string), false);
});

test('secrets availability needs both isEncryptionAvailable and a real keyring (no plaintext fallback)', () => {
  assert.equal(linuxSecretsAvailable(true, 'gnome_libsecret'), true);
  assert.equal(linuxSecretsAvailable(true, 'kwallet6'), true);
  // Electron reports true for basic_text because it encrypts with a hard-coded key; that is not secure.
  assert.equal(linuxSecretsAvailable(true, 'basic_text'), false);
  assert.equal(linuxSecretsAvailable(true, 'unknown'), false);
  assert.equal(linuxSecretsAvailable(false, 'gnome_libsecret'), false);
  assert.equal(linuxSecretsAvailable(false, 'basic_text'), false);
});

test('capture policy per session', () => {
  assert.equal(linuxRevalidatesSources('x11'), true);
  assert.equal(linuxRevalidatesSources('wayland'), false); // a second getSources() would open a second portal picker
  assert.equal(linuxRevalidatesSources('unknown'), true);
  assert.deepEqual(linuxCaptureSwitches('x11'), []);
  assert.deepEqual(linuxCaptureSwitches('unknown'), []);
  assert.deepEqual(linuxCaptureSwitches('wayland'), [['enable-features', 'WebRTCPipeWireCapturer']]);
  // Never weaken the sandbox or enable audio capture through a switch.
  for (const s of ['x11', 'wayland', 'unknown'] as const) {
    for (const [name, value] of linuxCaptureSwitches(s)) {
      assert.doesNotMatch(`${name}=${value ?? ''}`, /sandbox|audio|disable-web-security/i);
    }
  }
});

test('Linux profile is separate from the Windows profile', () => {
  assert.equal(LINUX_PROFILE_DIR, 'LumaLinux');
  assert.notEqual(LINUX_PROFILE_DIR, 'LumaWindows');
});

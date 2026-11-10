// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Secret storage for the headless Luma Bridge (no Electron safeStorage). One backend per data
// folder, chosen at setup and recorded in bridge.json:
//   keychain        macOS login keychain via /usr/bin/security (secret passed on stdin, never argv)
//   secret-service  Linux keyring via secret-tool (libsecret; needs a D-Bus session and an unlocked keyring)
//   dpapi           Windows DPAPI (CurrentUser) via Windows PowerShell; files hold only encrypted blobs
//   file            explicit opt-in: owner-only files (0600 in a 0700 folder). Not encrypted at rest. Refused on Windows.
// Nothing ever falls back to another backend. Values are base64-encoded so PEM newlines/quotes survive.
// Commands run with execFileSync and fixed argv (no shell).

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, unlinkSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { LumaError } from '../core/model';
import { atomicWrite, type SecretStore } from '../main/storage';

export const SECRET_BACKENDS = ['keychain', 'secret-service', 'dpapi', 'file'] as const;
export type SecretBackend = (typeof SECRET_BACKENDS)[number];

const SERVICE = 'app.luma.bridge';
const TIMEOUT = 15_000;

/** The OS keyring for this platform. The file backend is never a default. */
export function defaultBackend(platform = process.platform): SecretBackend | undefined {
  return platform === 'darwin' ? 'keychain' : platform === 'linux' ? 'secret-service' : platform === 'win32' ? 'dpapi' : undefined;
}

export function describeBackend(backend: SecretBackend): string {
  return {
    keychain: 'macOS login keychain',
    'secret-service': 'Linux Secret Service keyring (secret-tool)',
    dpapi: 'Windows DPAPI (current user)',
    file: 'owner-only files (0600). Not encrypted at rest: anyone with this account or root can read them',
  }[backend];
}

type Raw = { read(name: string): string | undefined; write(name: string, value: string): void; delete(name: string): void; available(): boolean };

/** Caches values in memory: the daemon reads the sync token on every status view. */
class CachedStore implements SecretStore {
  private readonly cache = new Map<string, string | undefined>();
  private probed?: boolean;
  constructor(private readonly raw: Raw) {}
  get available(): boolean { return (this.probed ??= this.raw.available()); }
  read(name: string): string | undefined {
    check(name);
    if (!this.available) return undefined;
    if (!this.cache.has(name)) this.cache.set(name, this.raw.read(name));
    return this.cache.get(name);
  }
  write(name: string, value: string): void {
    check(name);
    if (!this.available) throw new LumaError('Secure storage is unavailable; nothing was saved.');
    this.raw.write(name, value);
    this.cache.delete(name);
    // Read back: a keyring that silently refused must not look saved.
    if (this.read(name) !== value) { this.cache.delete(name); throw new LumaError('Secure storage did not keep the secret; nothing was saved.'); }
  }
  delete(name: string): void {
    check(name);
    this.cache.delete(name);
    if (this.available) this.raw.delete(name);
  }
}

const check = (name: string) => { if (!/^[a-z-]{1,32}$/.test(name)) throw new LumaError('Invalid secret name.'); };
const b64 = (s: string) => Buffer.from(s, 'utf8').toString('base64');
const unb64 = (s: string) => Buffer.from(s.trim(), 'base64').toString('utf8');
/** Keyring entries of different data folders never collide (tests, or two bridges on one account). */
const folderTag = (folder: string) => createHash('sha256').update(resolve(folder)).digest('hex').slice(0, 12);
const status = (error: unknown) => (error as { status?: number }).status;
const stderr = (error: unknown) => String((error as { stderr?: unknown }).stderr ?? '').trim().slice(0, 200);

function keychain(folder: string, keychainPath = process.env.LUMA_BRIDGE_KEYCHAIN): Raw {
  const kc = keychainPath ? [keychainPath] : [];
  const account = (name: string) => `${folderTag(folder)}:${name}`;
  return {
    available: () => process.platform === 'darwin' && existsSync('/usr/bin/security'),
    read(name) {
      try { return unb64(execFileSync('/usr/bin/security', ['find-generic-password', '-s', SERVICE, '-a', account(name), '-w', ...kc], { encoding: 'utf8', timeout: TIMEOUT, stdio: ['ignore', 'pipe', 'pipe'] })); }
      catch (error) {
        if (status(error) === 44) return undefined; // errSecItemNotFound
        throw new LumaError(`The keychain could not be read (is it locked?): ${stderr(error) || 'security failed'}`);
      }
    },
    write(name, value) {
      // `security -i` reads the command from stdin, so the secret never appears in the process list.
      // It splits on spaces: every word here is space-free (base64, fixed names), except a test keychain path, which is quoted.
      const line = ['add-generic-password', '-U', '-s', SERVICE, '-a', account(name), '-l', `luma-bridge-${name}`, '-w', b64(value), ...kc.map((p) => JSON.stringify(p))].join(' ');
      try { execFileSync('/usr/bin/security', ['-i'], { input: `${line}\n`, timeout: TIMEOUT, stdio: ['pipe', 'ignore', 'pipe'] }); }
      catch (error) { throw new LumaError(`The keychain refused the secret: ${stderr(error).split('\n')[0] || 'security failed'}`); }
    },
    delete(name) {
      try { execFileSync('/usr/bin/security', ['delete-generic-password', '-s', SERVICE, '-a', account(name), ...kc], { timeout: TIMEOUT, stdio: 'ignore' }); }
      catch (error) { if (status(error) !== 44) throw new LumaError('The keychain item could not be removed.'); }
    },
  };
}

function secretService(folder: string): Raw {
  const attrs = (name: string) => ['service', SERVICE, 'dir', folderTag(folder), 'name', name];
  const run = (args: string[], input?: string) => execFileSync('secret-tool', args, { encoding: 'utf8', timeout: TIMEOUT, input, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'] });
  return {
    available() {
      if (process.platform !== 'linux') return false;
      // A lookup that finds nothing exits 1 with empty stderr; no D-Bus/keyring prints an error.
      try { run(['lookup', ...attrs('probe')]); return true; }
      catch (error) { return status(error) === 1 && stderr(error) === ''; }
    },
    read(name) {
      try { return unb64(run(['lookup', ...attrs(name)])); }
      catch (error) {
        if (status(error) === 1 && stderr(error) === '') return undefined;
        throw new LumaError(`The keyring could not be read (is it unlocked?): ${stderr(error) || 'secret-tool failed'}`);
      }
    },
    write(name, value) {
      try { run(['store', `--label=Luma Bridge ${name}`, ...attrs(name)], b64(value)); }
      catch (error) { throw new LumaError(`The keyring refused the secret: ${stderr(error) || 'secret-tool failed'}`); }
    },
    delete(name) { try { run(['clear', ...attrs(name)]); } catch { /* nothing stored */ } },
  };
}

function dpapi(folder: string): Raw {
  const dir = join(folder, 'secrets');
  const file = (name: string) => join(dir, `${name}.dpapi`);
  const ps = (op: 'Protect' | 'Unprotect', input: string) => execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    `Add-Type -AssemblyName System.Security; $d=[Convert]::FromBase64String([Console]::In.ReadToEnd().Trim()); [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::${op}($d,$null,'CurrentUser'))`],
  { encoding: 'utf8', input, timeout: 30_000, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true }).trim();
  return {
    available: () => process.platform === 'win32',
    read(name) {
      if (!existsSync(file(name))) return undefined;
      try { return unb64(ps('Unprotect', readFileSync(file(name), 'utf8'))); }
      catch { throw new LumaError('A saved secret could not be decrypted with this Windows account (DPAPI). Set it again.'); }
    },
    write(name, value) {
      mkdirSync(dir, { recursive: true });
      atomicWrite(file(name), ps('Protect', b64(value)));
    },
    delete(name) { if (existsSync(file(name))) unlinkSync(file(name)); },
  };
}

function fileStore(folder: string): Raw {
  const dir = join(folder, 'secrets');
  const file = (name: string) => join(dir, name);
  const ownerOnly = (path: string) => (statSync(path).mode & 0o077) === 0;
  return {
    available: () => process.platform !== 'win32',
    read(name) {
      if (!existsSync(file(name))) return undefined;
      if (!ownerOnly(dir) || !ownerOnly(file(name))) throw new LumaError(`Refusing to read ${file(name)}: it or its folder is readable by other users. Run chmod 700 on the folder and 600 on the file.`);
      return unb64(readFileSync(file(name), 'utf8'));
    },
    write(name, value) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      chmodSync(dir, 0o700);
      atomicWrite(file(name), b64(value));
    },
    delete(name) { if (existsSync(file(name))) unlinkSync(file(name)); },
  };
}

export function createSecretStore(backend: SecretBackend, folder: string): SecretStore {
  const raw = { keychain, 'secret-service': secretService, dpapi, file: fileStore }[backend];
  if (!raw) throw new LumaError('Unknown secret storage.');
  return new CachedStore(raw(folder));
}

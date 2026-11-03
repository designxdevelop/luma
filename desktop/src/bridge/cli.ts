#!/usr/bin/env node
// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// luma-bridge: command line for the headless Luma Bridge. See docs/LOCAL-BRIDGE.md.
// Commands that change state hold the data-folder lock, so they refuse while the bridge runs.
// Secrets (Govee key, pairing code, relay token) are read from stdin or a hidden prompt, never argv,
// and are read BEFORE the home is opened: an open home is a live runner (schedule tick, doorbell relay).

import { X509Certificate } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { userInfo } from 'node:os';
import { join, resolve } from 'node:path';
import { certPin, formatPairingCode, SYNC_PORT } from '../core/schedule-sync';
import { lanAddresses } from '../main/schedule-sync';
import { HomeStorage } from '../main/storage';
import { fingerprint, spkiPin } from '../core/certificate';
import { message } from '../core/model';
import type { Home } from '../main/home';
import {
  CONFIG_FILE, acquireLock, defaultDataDir, doorbellOf, openHome, prepareDataDir, readConfig, readState, startBridge, writeConfig,
  type BridgeConfig, type BridgeStatus,
} from './bridge';
import { SECRET_BACKENDS, createSecretStore, defaultBackend, describeBackend, type SecretBackend } from './secret-store';

const VERSION = (() => { try { return (JSON.parse(readFileSync(join(__dirname, '..', '..', 'package.json'), 'utf8')) as { version: string }).version; } catch { return '0.0.0'; } })();

const USAGE = `Luma Bridge ${VERSION}: runs shared Luma schedules on this computer without a window.

Usage: luma-bridge <command> [--data-dir DIR]

  setup [--secrets keychain|secret-service|dpapi|file] [--port N]
                         Make this bridge the runner and print its pairing code.
  start                  Run in the foreground (use a service manager to keep it running).
  status [--json]        Running or not, paired devices, last runs, warnings. Exit 0 only when running.
  pairing-code           Print the pairing code(s) again.
  rotate-pairing         Replace the pairing code. Every device must pair again.
  pair [--secrets B] [--port N]
                         Pair with the current runner (code from stdin or a hidden prompt).
  take-over [--force] [--port N]
                         After "pair": move the schedules here; the old runner stops running them.
  turn-off               Stop sharing schedules on this bridge.
  configure [--port N] [--keep-awake on|off] [--lan on|off] [--webhook off|local|lan] [--webhook-port N]
            [--govee-key] [--forget-govee-key]
  import-backup FILE [--secrets B]
                         Load a "luma-home-backup" file (lights, rooms, scenes, schedules) before setup.
  webhook-info [--show-token]
  alert status|enable|disable|set FILE|relay URL|forget-relay|alexa-code|unlink
                         Doorbell alert (when this build includes it).
  service launchd|systemd|systemd-system|windows
                         Print a service definition to review and install yourself. Nothing is installed.

Data folder: ${defaultDataDir()} (override with --data-dir or LUMA_BRIDGE_DATA).
Commands other than start/status/pairing-code/webhook-info/service need the bridge stopped.`;

class Usage extends Error {}

function parse(argv: string[]): { command: string; args: string[]; flags: Map<string, string | true> } {
  const flags = new Map<string, string | true>(), args: string[] = [];
  const valued = new Set(['data-dir', 'secrets', 'port', 'keep-awake', 'lan', 'webhook', 'webhook-port']);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (!a.startsWith('--')) { args.push(a); continue; }
    const [name, inline] = a.slice(2).split('=', 2) as [string, string | undefined];
    if (valued.has(name)) {
      const value = inline ?? argv[++i];
      if (value === undefined) throw new Usage(`--${name} needs a value.`);
      flags.set(name, value);
    } else flags.set(name, true);
  }
  return { command: args.shift() ?? 'help', args, flags };
}

const onOff = (v: string | true | undefined, name: string): boolean | undefined => {
  if (v === undefined) return undefined;
  if (v === 'on' || v === 'off') return v === 'on';
  throw new Usage(`--${name} takes on or off.`);
};
const port = (v: string | true | undefined, name: string): number | undefined => {
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 1024 || n > 65535) throw new Usage(`--${name} must be a whole number from 1024 to 65535.`);
  return n;
};

/** Hidden prompt on a terminal; otherwise all of stdin (for pipes such as a password manager). */
export async function readSecret(prompt: string): Promise<string> {
  const stdin = process.stdin;
  if (!stdin.isTTY) {
    const chunks: Buffer[] = [];
    for await (const c of stdin) chunks.push(c as Buffer);
    return Buffer.concat(chunks).toString('utf8').trim();
  }
  process.stderr.write(`${prompt}: `);
  stdin.setRawMode(true);
  stdin.resume();
  return new Promise((done, fail) => {
    let value = '';
    const finish = (error?: Error) => { stdin.setRawMode(false); stdin.pause(); stdin.off('data', onData); process.stderr.write('\n'); if (error) fail(error); else done(value.trim()); };
    const onData = (data: Buffer) => {
      for (const ch of data.toString('utf8')) {
        if (ch === '\r' || ch === '\n') return finish();
        if (ch === '\u0003') return finish(new Error('Cancelled.'));
        if (ch === '\u007f' || ch === '\b') value = value.slice(0, -1);
        else if (ch >= ' ') value += ch;
      }
    };
    stdin.on('data', onData);
  });
}

/**
 * Creates bridge.json (secret backend chosen once per folder) without changing the sharing role,
 * so `setup`, `pair` and `import-backup` all work on a fresh folder. Fails if the store is unreachable.
 */
function ensureConfig(dir: string, wanted: string | true | undefined): void {
  if (wanted !== undefined && !SECRET_BACKENDS.includes(wanted as SecretBackend)) throw new Usage(`--secrets takes ${SECRET_BACKENDS.join(', ')}.`);
  prepareDataDir(dir);
  const release = acquireLock(dir);
  try {
    const existing = readConfig(dir);
    const backend = (wanted as SecretBackend | undefined) ?? existing?.secrets ?? defaultBackend();
    if (!backend) throw new Error('This system has no supported secure storage. Use --secrets file (owner-only files, not encrypted).');
    if (existing && existing.secrets !== backend) throw new Error(`Already set up with ${existing.secrets} secrets. Changing it would lose the pairing secret; use a new --data-dir instead.`);
    if (backend === 'file' && process.platform === 'win32') throw new Error('The file backend is refused on Windows (file modes do not protect it there). Use dpapi.');
    if (!createSecretStore(backend, dir).available) {
      throw new Error(backend === 'secret-service'
        ? 'No Secret Service keyring is reachable (common on a headless Raspberry Pi or over SSH). Either run inside a desktop session with an unlocked keyring, or choose --secrets file to keep secrets in owner-only files (not encrypted at rest).'
        : `${describeBackend(backend)} is not available here.`);
    }
    if (!existing) writeConfig(dir, { version: 1, secrets: backend, lan: true, webhook: false });
  } finally { release(); }
}

/** One locked operation on the home, then a clean shutdown. */
async function withHome<T>(dir: string, work: (home: Home, config: BridgeConfig) => Promise<T>): Promise<T> {
  prepareDataDir(dir);
  const release = acquireLock(dir);
  try {
    const config = readConfig(dir);
    if (!config) throw new Error(`Not set up. Run "luma-bridge setup" first (data folder ${dir}).`);
    const home = openHome(dir, config, VERSION);
    try { return await work(home, config); } finally { await home.shutdown(); }
  } finally { release(); }
}

function printCodes(codes: string[]): void {
  if (!codes.length) { console.log('No pairing code: this bridge has no IPv4 LAN address, or it is not the runner.'); return; }
  console.log('Pairing code (paste it in Luma > Automations > Shared schedules on your iPhone, Mac or PC):');
  for (const c of codes) console.log(`  ${c}`);
  console.log('The code contains this bridge\'s access token. Share it only with your own devices. Replace it with "luma-bridge rotate-pairing".');
}

/** Read-only: works while the bridge runs. */
function pairingCodes(dir: string): string[] {
  const config = readConfig(dir);
  if (!config) throw new Error(`Not set up. Run "luma-bridge setup" first (data folder ${dir}).`);
  const file = join(dir, 'schedule-sync.json');
  const saved = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) as { role?: string; port?: number; runner?: { retiredTo?: unknown } } : {};
  if (saved.role !== 'runner' || saved.runner?.retiredTo) throw new Error('This bridge is not the active runner, so it has no pairing code.');
  const secrets = createSecretStore(config.secrets, dir);
  const token = secrets.read('schedule-sync-token'), tls = secrets.read('schedule-sync-tls');
  if (!token || !tls) throw new Error('No pairing secret yet. Run "luma-bridge start" once.');
  const pin = certPin(new X509Certificate((JSON.parse(tls) as { cert: string }).cert).raw);
  const p = saved.port || SYNC_PORT;
  return lanAddresses().map((host) => formatPairingCode({ host, port: p, pin, token }));
}

function ago(ms: number | undefined): string {
  if (!ms) return 'never';
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  return s < 90 ? `${s} s ago` : s < 5400 ? `${Math.round(s / 60)} min ago` : s < 172800 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} days ago`;
}

function printStatus(dir: string, json: boolean): number {
  const state = readState(dir);
  const configured = existsSync(join(dir, CONFIG_FILE));
  if (json) { console.log(JSON.stringify({ dataDir: dir, configured, ...state }, null, 2)); return state.state === 'running' ? 0 : 3; }
  const s: BridgeStatus | undefined = state.status;
  const head = state.state === 'running' ? `running (pid ${s!.pid}, up since ${new Date(s!.startedAt).toLocaleString()})`
    : state.state === 'stale' ? `not responding (pid ${state.pid} holds the lock, last heartbeat ${ago(s?.updatedAt)})`
      : configured ? `stopped${s?.stoppedAt ? ` (${ago(s.stoppedAt)})` : ''}` : 'not set up';
  console.log(`Luma Bridge: ${head}`);
  console.log(`Data folder: ${dir}`);
  if (!s) return state.state === 'running' ? 0 : 3;
  if (state.state !== 'running') console.log('(Details below are from the last time it ran.)');
  console.log(`Secrets: ${describeBackend(s.secrets as SecretBackend)}`);
  console.log(`Role: ${s.role}${s.mayExecute && s.role === 'runner' ? ' (runs schedules)' : ''} as "${s.deviceName}", time zone ${s.timeZone}`);
  if (s.runner) console.log(`Schedule sync: ${s.runner.status}${s.runner.keepAwake ? ' · keep awake on' : ''}`);
  if (s.paired) console.log(`Paired with ${s.paired.runnerName} (${s.paired.host}) · last sync ${ago(s.paired.lastSync)}${s.paired.unsent ? ` · ${s.paired.unsent} not delivered` : ''}${s.paired.lastError ? ` · ${s.paired.lastError}` : ''}`);
  console.log(`Schedules: ${s.schedules}, scenes: ${s.scenes}. Lights: ${s.lights.total} (${s.lights.lan} on LAN), Govee cloud ${s.lights.cloudConnected ? 'connected' : 'not connected'}.`);
  if (s.runner?.clients.length) {
    console.log('Paired devices:');
    for (const c of s.runner.clients) console.log(`  ${c.name} (${c.platform}) · last seen ${ago(c.lastSeen)}`);
  } else if (s.runner) console.log('Paired devices: none yet.');
  if (s.runner?.runs.length) {
    console.log('Last runs:');
    for (const r of [...s.runner.runs].sort((a, b) => b.at - a.at).slice(0, 10)) console.log(`  ${new Date(r.at).toLocaleString()} · ${r.status}${r.detail ? ` · ${r.detail}` : ''} (schedule ${r.scheduleID.slice(0, 8)})`);
  }
  console.log(`Webhook API: ${s.webhook.status}`);
  if (s.doorbell) console.log(`Doorbell alert: ${s.doorbell.enabled ? 'on' : 'off'}${s.doorbell.relayState ? ` · relay ${s.doorbell.relayState}` : ''}${s.doorbell.status ? ` · ${s.doorbell.status}` : ''}`);
  for (const w of s.warnings) console.log(`Warning: ${w}`);
  for (const e of s.recentErrors.slice(0, 5)) console.log(`Error ${ago(e.time)}: ${e.message}`);
  return state.state === 'running' ? 0 : 3;
}

const xml = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const quoted = (s: string) => `"${s.replace(/(["\\$`])/g, '\\$1')}"`;

export function serviceDefinition(kind: string, dir: string, node = process.execPath, cli = resolve(__filename)): string {
  const user = userInfo().username;
  switch (kind) {
    case 'launchd': return `<?xml version="1.0" encoding="UTF-8"?>
<!-- Save as ~/Library/LaunchAgents/app.luma.bridge.plist, then:
       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.luma.bridge.plist
     Stop: launchctl bootout gui/$(id -u)/app.luma.bridge
     A LaunchAgent (not a LaunchDaemon) so the login keychain is reachable; it runs while you are logged in. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>app.luma.bridge</string>
  <key>ProgramArguments</key>
  <array><string>${xml(node)}</string><string>${xml(cli)}</string><string>start</string><string>--data-dir</string><string>${xml(dir)}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Standard</string>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>${xml(join(process.env.HOME ?? '~', 'Library', 'Logs', 'LumaBridge.log'))}</string>
  <key>StandardErrorPath</key><string>${xml(join(process.env.HOME ?? '~', 'Library', 'Logs', 'LumaBridge.log'))}</string>
</dict>
</plist>`;
    case 'systemd': return `# Save as ~/.config/systemd/user/luma-bridge.service, then:
#   systemctl --user daemon-reload && systemctl --user enable --now luma-bridge
#   journalctl --user -u luma-bridge -f
# A user service stops when you log out. To keep it running after logout or start it at boot
# without logging in, an administrator runs once: sudo loginctl enable-linger ${user}
# (user services cannot wait for network-online.target; Restart= covers an early start).
[Unit]
Description=Luma Bridge (shared Luma schedules)

[Service]
ExecStart=${quoted(node)} ${quoted(cli)} start --data-dir ${quoted(dir)}
Restart=on-failure
RestartSec=15
UMask=0077
NoNewPrivileges=yes

[Install]
WantedBy=default.target
`;
    case 'systemd-system': return `# System service running as ${user} (needs admin to install; never run the bridge as root).
# Use with --secrets file: a system service has no desktop keyring session.
# Save as /etc/systemd/system/luma-bridge.service, then:
#   sudo systemctl daemon-reload && sudo systemctl enable --now luma-bridge
# On a Raspberry Pi (no real-time clock), enable systemd-time-wait-sync.service so time-sync.target
# means the clock is set before schedules are checked.
[Unit]
Description=Luma Bridge (shared Luma schedules)
Wants=network-online.target
After=network-online.target time-sync.target

[Service]
User=${user}
ExecStart=${quoted(node)} ${quoted(cli)} start --data-dir ${quoted(dir)}
Restart=on-failure
RestartSec=15
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${quoted(dir)}
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
`;
    case 'windows': return `# PowerShell, as your normal (non-admin) user. Runs at logon under your account, so DPAPI can
# read the saved secrets. Review, then paste:
$action = New-ScheduledTaskAction -Execute '${node.replace(/'/g, "''")}' -Argument '"${cli.replace(/'/g, "''")}" start --data-dir "${dir.replace(/'/g, "''")}"'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'Luma Bridge' -Action $action -Trigger $trigger -Settings $settings
# Stop: Stop-ScheduledTask -TaskName 'Luma Bridge'   Remove: Unregister-ScheduledTask -TaskName 'Luma Bridge'
# Windows Firewall asks once whether node.exe may accept connections: allow Private networks only.
`;
    default: throw new Usage('service takes launchd, systemd, systemd-system or windows.');
  }
}

async function main(argv: string[]): Promise<number> {
  const { command, args, flags } = parse(argv);
  const dir = resolve(typeof flags.get('data-dir') === 'string' ? flags.get('data-dir') as string : defaultDataDir());
  switch (command) {
    case 'help': case '--help': case '-h': console.log(USAGE); return 0;
    case 'version': case '--version': console.log(VERSION); return 0;

    case 'setup': {
      const requestedPort = port(flags.get('port'), 'port');
      ensureConfig(dir, flags.get('secrets'));
      await withHome(dir, async (home) => {
        if (requestedPort !== undefined) await home.scheduleSync.setPort(requestedPort);
        const role = home.scheduleSync.role;
        if (role === 'off') await home.scheduleSync.becomeRunner();
        else console.log(`Already set up (${role}).`);
        console.log(`Secrets: ${describeBackend(readConfig(dir)!.secrets)}.`);
        if (home.scheduleSync.role === 'runner') printCodes(home.scheduleSync.view().runner?.pairingCodes ?? []);
      });
      console.log(`Next: add lights ("luma-bridge configure --govee-key", or LAN Control in the Govee app), then "luma-bridge start" or install a service ("luma-bridge service ${process.platform === 'darwin' ? 'launchd' : process.platform === 'win32' ? 'windows' : 'systemd'}").`);
      return 0;
    }

    case 'start': {
      const runtime = await startBridge({ dataDir: dir, version: VERSION });
      await new Promise<void>((done) => {
        const stop = () => { void runtime.stop().finally(done); };
        for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.once(signal, stop);
        process.once('uncaughtException', (error) => { process.stderr.write(`Unexpected error: ${error.message}\n`); process.exitCode = 1; stop(); });
      });
      return Number(process.exitCode ?? 0);
    }

    case 'status': return printStatus(dir, flags.has('json'));
    case 'pairing-code': printCodes(pairingCodes(dir)); return 0;

    case 'rotate-pairing':
      await withHome(dir, async (home) => { await home.scheduleSync.rotatePairing(); printCodes(home.scheduleSync.view().runner?.pairingCodes ?? []); });
      return 0;

    case 'pair': {
      if (args.length) throw new Usage('pair reads the code from stdin or a prompt, so it stays out of your shell history.');
      const requestedPort = port(flags.get('port'), 'port');
      const code = await readSecret('Pairing code from the current runner');
      ensureConfig(dir, flags.get('secrets'));
      await withHome(dir, async (home) => {
        if (requestedPort !== undefined) await home.scheduleSync.setPort(requestedPort);
        await home.scheduleSync.pair(code);
        const v = home.scheduleSync.view();
        console.log(`Paired with ${v.paired?.runnerName}. This bridge doesn't run schedules yet. Run "luma-bridge take-over" to move them here.`);
        for (const n of v.notices) console.log(`Note: ${n}`);
      });
      return 0;
    }

    case 'take-over': {
      const force = flags.has('force');
      const requestedPort = port(flags.get('port'), 'port');
      await withHome(dir, async (home) => {
        if (requestedPort !== undefined) await home.scheduleSync.setPort(requestedPort);
        await home.scheduleSync.takeOver(force);
        const v = home.scheduleSync.view();
        if (v.runner?.waitingFor) console.log(`The old runner (${v.runner.waitingFor}) didn't confirm. This bridge runs nothing until it does; "luma-bridge start" keeps asking every 30 s.`);
        else console.log('Schedules now run on this bridge.');
        printCodes(v.runner?.pairingCodes ?? []);
      });
      return 0;
    }

    case 'turn-off':
      await withHome(dir, async (home) => { await home.scheduleSync.turnOff(); console.log('Schedule sharing is off on this bridge.'); });
      return 0;

    case 'configure': {
      const keepAwake = onOff(flags.get('keep-awake'), 'keep-awake'), lan = onOff(flags.get('lan'), 'lan');
      const syncPort = port(flags.get('port'), 'port'), webhookPort = port(flags.get('webhook-port'), 'webhook-port');
      const webhook = flags.get('webhook');
      if (webhook !== undefined && !['off', 'local', 'lan'].includes(webhook as string)) throw new Usage('--webhook takes off, local or lan.');
      const key = flags.has('govee-key') ? await readSecret('Govee API key') : undefined;
      await withHome(dir, async (home, config) => {
        if (syncPort !== undefined) { await home.scheduleSync.setPort(syncPort); console.log(`Schedule sync port ${syncPort}. Pair devices again with the new code.`); }
        if (keepAwake !== undefined) await home.scheduleSync.setKeepAwake(keepAwake);
        if (webhook !== undefined || webhookPort !== undefined) {
          const w = home.snapshot().webhook;
          home.setWebhookConfig(webhookPort ?? w.port, webhook === undefined ? w.allowLAN : webhook === 'lan');
          home.persistNow();
        }
        if (flags.has('forget-govee-key')) home.disconnect();
        if (key !== undefined) await home.connect(key);
        writeConfig(dir, { ...config, ...(lan === undefined ? {} : { lan }), ...(webhook === undefined ? {} : { webhook: webhook !== 'off' }) });
        console.log('Saved. Restart the bridge to apply.');
      });
      return 0;
    }

    case 'import-backup': {
      const file = args[0];
      if (!file) throw new Usage('import-backup FILE');
      const text = readFileSync(file, 'utf8');
      ensureConfig(dir, flags.get('secrets'));
      await withHome(dir, async (home) => { const r = home.restoreBackup(text); console.log(`Imported ${r.scenes} scenes, ${r.schedules} schedules, ${r.lightsUpdated} lights.`); });
      return 0;
    }

    case 'webhook-info': {
      const config = readConfig(dir);
      if (!config) throw new Error('Not set up.');
      const secrets = createSecretStore(config.secrets, dir);
      const token = secrets.read('webhook-token'), tls = secrets.read('webhook-tls');
      const saved = new HomeStorage(dir).load();
      console.log(`Webhook API: ${config.webhook ? 'on' : 'off'} · port ${saved.webhookPort} · ${saved.allowLAN ? 'local network' : 'this computer only'}`);
      if (!token || !tls) { console.log('No token or certificate yet: turn it on ("configure --webhook local") and start the bridge once.'); return 0; }
      const cert = new X509Certificate((JSON.parse(tls) as { cert: string }).cert);
      console.log(`Certificate SHA-256: ${fingerprint(cert.raw)}\nSPKI pin: ${spkiPin(cert.publicKey)}`);
      console.log(flags.has('show-token') ? `Token: ${token}` : `Token: ${token.slice(0, 3)}…${token.slice(-4)} (add --show-token to print it)`);
      return 0;
    }

    case 'alert': {
      const [action, arg] = args;
      const relayToken = action === 'relay' ? await readSecret('Relay token') : undefined;
      const settings = action === 'set' ? JSON.parse(arg === '-' || arg === undefined ? await readSecret('Settings JSON') : readFileSync(arg, 'utf8')) as unknown : undefined;
      await withHome(dir, async (home) => {
        const doorbell = doorbellOf(home);
        if (!doorbell) throw new Error('This build of Luma has no doorbell alert.');
        const config = doorbell.view().config;
        switch (action) {
          case undefined: case 'status': break;
          case 'enable': case 'disable': await doorbell.command('update', { ...config, enabled: action === 'enable' }); break;
          case 'set': await doorbell.command('update', settings); break;
          case 'relay': if (!arg) throw new Usage('alert relay URL'); await doorbell.command('saveRelay', arg, relayToken); break;
          case 'forget-relay': await doorbell.command('forgetRelay'); break;
          case 'unlink': await doorbell.command('unlink'); break;
          case 'alexa-code': {
            await doorbell.command('pairingCode');
            const pairing = (doorbell.view() as { pairing?: { code: string; expiresAt: number } }).pairing;
            if (pairing) console.log(`Alexa account-linking code: ${pairing.code} (expires ${new Date(pairing.expiresAt).toLocaleTimeString()}). Enter it when the Alexa app links the skill.`);
            break;
          }
          default: throw new Usage('alert status|enable|disable|set FILE|relay URL|forget-relay|alexa-code|unlink');
        }
        const { pairing: _hidden, ...view } = doorbell.view() as Record<string, unknown>;
        console.log(JSON.stringify(view, null, 2));
      });
      return 0;
    }

    case 'service': console.log(serviceDefinition(args[0] ?? '', dir)); return 0;
    default: throw new Usage(`Unknown command "${command}".`);
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (error) => {
    process.stderr.write(`luma-bridge: ${message(error)}\n`);
    if (error instanceof Usage) process.stderr.write('Run "luma-bridge help" for usage.\n');
    process.exit(error instanceof Usage ? 2 : 1);
  });
}

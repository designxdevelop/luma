# Luma Bridge (headless schedule runner)

Luma Bridge runs your shared Luma schedules on an always-on computer with no Luma window open: a Mac, a Windows or Linux PC, or a Raspberry Pi. It is the same runner the Windows/Linux app uses (see [SCHEDULE-SYNC.md](SCHEDULE-SYNC.md)), hosted in a plain Node.js process:

- The protocol is the same: port 8788, pinned TLS and the `luma1/…` pairing code.
- The iPhone, iPad, Mac and Windows/Linux apps pair with it unchanged. Paired devices edit, pause, disable and delete schedules; the bridge runs them.
- Lights are controlled through the desktop app's existing Govee LAN and cloud transport.
- The existing webhook API and the doorbell alert run on it as well.

It works on your home network only. No cloud relay is used or implied.

## Requirements

- Node.js 22.12 or later. It has no npm dependencies and no native modules.
- Tested here: macOS (Apple Silicon) and Linux arm64 (`node:22-slim`, the same CPU architecture as a 64-bit Raspberry Pi OS).
- Windows is not tested yet (see [Limits](#limits-and-what-is-not-verified)).
- 32-bit Raspberry Pi OS (armv7) works wherever Node 22 runs; Node's official armv7 builds are experimental.

## Install

Build from the repository:

```sh
cd desktop
npm ci
npm run bridge:pack        # writes release/luma-bridge-<version>.tar.gz (about 100 KB)
```

Copy the tarball to the target computer, then unpack it:

```sh
tar -xzf luma-bridge-1.0.0.tar.gz          # makes ./luma-bridge
alias luma-bridge="node $PWD/luma-bridge/dist/bridge/cli.js"
luma-bridge help
```

In a development checkout you can run `npm run build`, then `node dist/bridge/cli.js …` (or `npm run bridge -- …`).

## Set up

```sh
luma-bridge setup                     # this bridge becomes the runner; prints the pairing code
luma-bridge configure --govee-key     # optional: Govee cloud (hidden prompt, or the key on stdin)
luma-bridge start                     # foreground; Ctrl+C stops it cleanly
```

1. **Pair your devices.** Paste the pairing code in Luma on each device: Automations, then Shared schedules, then Pair with a computer. The code contains the bridge's access token. Treat it like a password. `luma-bridge rotate-pairing` replaces it, and every device must then pair again.
2. **Add lights.** The bridge only controls lights it knows about. Use one or more of:
   - Turn on LAN Control in the Govee app. The bridge scans on start and every 10 minutes.
   - Add a Govee API key.
   - Before `setup`, run `luma-bridge import-backup home.luma-backup.json` with a backup exported from any Luma app. It brings light names, rooms, scenes and schedules. Restore is refused while sharing, as in the apps.
3. **Set the time zone.** Schedule times are wall-clock times in the bridge's own time zone. `status` warns when the zone is UTC, which is the Raspberry Pi default. Set it, for example with `sudo timedatectl set-timezone America/New_York`.

The pairing code can also be printed while the bridge runs, with `luma-bridge pairing-code`.

**Secrets from 1Password, without showing them.** `--govee-key`, `pair` and `alert relay` read a value from stdin when stdin isn't a terminal. With the `2password` CLI, the value goes from 1Password straight into the bridge and never appears in your terminal or shell history:

```sh
2password run --env "GOVEE_KEY=op://Personal/Govee API Key/credential" -- sh -c 'printf %s "$GOVEE_KEY" | luma-bridge configure --govee-key'
```

Don't pass a secret as a command-line argument: the bridge refuses one for `pair`, and arguments show up in the process list.

### Where secrets are kept

`setup --secrets …` picks the storage once per data folder; it is recorded in `bridge.json`. The bridge never falls back to another backend. If the store can't be reached, the bridge refuses to start.

| Backend | Default on | Storage | Notes |
| --- | --- | --- | --- |
| `keychain` | macOS | Login keychain, service `app.luma.bridge` | Each secret is passed on stdin, never in a command line. Needs a logged-in session: use a LaunchAgent, not a LaunchDaemon. A locked keychain makes the bridge refuse to start. |
| `secret-service` | Linux | GNOME Keyring or KWallet, through `secret-tool` (package `libsecret-tools`) | Needs a D-Bus session with an unlocked keyring, so it works in a desktop session. Usually **not** available on a headless Pi or over SSH. |
| `dpapi` | Windows | DPAPI (CurrentUser) through Windows PowerShell | Files in `secrets\` hold only encrypted blobs. |
| `file` | never (explicit opt-in) | `secrets/` in the data folder, files 0600 in a 0700 folder | **Not encrypted at rest.** Anyone with your account or root can read it. The bridge refuses a file or folder that other users can read. Refused on Windows. This is the expected choice on a headless Raspberry Pi. |

The bridge stores these secrets:
- The sync token and TLS identity (shared by every paired device).
- The Govee API key, if you add one.
- The webhook token and certificate, if you turn the webhook API on.
- The Alexa relay token, if the doorbell alert is installed.

Secrets are never written to `bridge.json`, `bridge-status.json`, `home.json`, `schedule-sync.json` or the log. Pairing codes and tokens appear only when you ask for them (`setup`, `pairing-code`, `rotate-pairing`, `take-over`, `webhook-info --show-token`).

## Moving the runner between the Luma app and the bridge

Only one computer runs shared schedules. Moving them uses the protocol's own hand-off: the old runner confirms it stopped before the new one runs anything. Don't copy data folders between them.

- **From the Windows/Linux app (or another bridge) to this bridge:**
  1. Stop the bridge if it's running.
  2. On the app, copy its pairing code. Then run `luma-bridge pair` and paste the code; it is read from a hidden prompt or stdin, never from the command line. On a fresh folder, `pair` also takes `--secrets` and `--port`, and no `setup` is needed.
  3. Run `luma-bridge take-over`.
  4. Start the bridge.
  5. Pair your phones with the bridge's new code.

  **App and bridge on the same computer:** the retired app keeps answering on port 8788, so the bridge can't bind it. Give the bridge another port (`pair --port 8789` or `take-over --port 8789`), or turn sharing off in the app after the hand-off.

  If the old runner is unreachable, `take-over --force` waits: the bridge runs nothing until the old runner confirms. A started bridge asks again every 30 s.
- **From this bridge to an app:**
  1. In the app, pair with the bridge's code.
  2. Choose "Run schedules here instead". The bridge saves that it retired and answers 410, which tells devices where schedules went.
  3. Run `luma-bridge turn-off` when you're done with it.
- **Native Mac app:** it can't pair with another runner yet. It runs its own runner, or none. Don't run both on the same Mac. The second one fails to bind port 8788 and says so.

## One owner per data folder

These rules stop two processes from running the same schedules or writing the same files:

- **Own data folder.** The bridge uses a folder separate from every Luma app profile. The default is:
  - macOS: `~/Library/Application Support/LumaBridge`
  - Linux: `~/.config/luma-bridge`
  - Windows: `%APPDATA%\LumaBridge`

  Override it with `--data-dir` or `LUMA_BRIDGE_DATA`. A folder that belongs to a Luma app is refused: `LumaWindows`, `LumaLinux`, `Luma`, a sandbox container, or any folder with Chromium profile files.
- **Exclusive lock.** `bridge.lock` holds the owner's process ID, start time and host name. A second `start` is refused while the owner lives, and so are state-changing commands (`setup`, `pair`, `configure`, …): stop the service first.
  - A lock left by a crash or power cut is cleared automatically. The lock counts as stale if its process is gone or started before the last boot, because PIDs repeat after a reboot.
- **Port.** The runner's server needs its port. If it can't bind (for example, a Luma window on the same computer already runs schedules on 8788), `start` exits non-zero with the reason instead of running silently without a server. `configure --port N` picks another port; devices then pair again.

## Keeping it running

`luma-bridge service <kind>` prints a service definition that fills in this computer's Node path, the CLI path and the data folder. Nothing is installed for you. Review the output, then install it:

- **macOS:** `luma-bridge service launchd > ~/Library/LaunchAgents/app.luma.bridge.plist`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.luma.bridge.plist`. It is a LaunchAgent, so it runs while you're logged in and the keychain is unlocked. The log goes to `~/Library/Logs/LumaBridge.log`.
- **Linux desktop or Pi with your user:**
  1. Run `luma-bridge service systemd > ~/.config/systemd/user/luma-bridge.service`.
  2. Run `systemctl --user enable --now luma-bridge`.
  3. Read the log with `journalctl --user -u luma-bridge -f`.

  To keep the service running after logout, or to start it at boot with no login, an administrator runs `sudo loginctl enable-linger <user>` once.
- **Headless Pi as a system service:** `luma-bridge service systemd-system` prints a unit that:
  - Runs as your user (`User=`), never root.
  - Orders on `network-online.target` and `time-sync.target`.
  - Uses `ProtectSystem=strict` with write access only to the data folder.

  It needs `--secrets file`. Enable `systemd-time-wait-sync.service`, since a Pi has no real-time clock.
- **Windows:** `luma-bridge service windows` prints a PowerShell `Register-ScheduledTask` snippet. It runs at logon under your account so DPAPI works, and restarts on failure. Allow `node.exe` on **Private** networks when the firewall asks.

**Keep awake.** `configure --keep-awake on` holds `caffeinate -i` on macOS, or `systemd-inhibit --what=idle:sleep` on Linux. Both helpers end when the bridge exits. Windows has no keep-awake in the bridge: set the power plan instead. Nothing stops a closed lid or a manual sleep, and runs that fall in sleep are reported as missed, as in the app.

## Is it working?

`luma-bridge status` (or `status --json`) reads `bridge-status.json`. The bridge rewrites that file after every change and every 15 s. Exit code 0 means running; 3 means stopped or not responding. It shows:

- **State:** running, stopped, or not responding (the lock is held but the heartbeat is old).
- **Setup:** role, port, secret backend and time zone.
- **Paired devices:** each one, with its platform and **last seen** time.
- **Runs:** the last runs (`started`, `completed`, `failed`, `missed`, `paused`), with reasons.
- **Lights and services:** lights known, LAN or cloud, the webhook API and the doorbell alert state.
- **Warnings:**
  - No lights are reachable.
  - The time zone is UTC.
  - The bridge is paired with another runner rather than running.
  - The bridge was handed off, or is waiting for the old runner.
  - The server is not listening.
  - The secret store is unreadable.
- **Errors:** the most recent ones.

Paired devices already show whether the runner is reachable: "Not reachable", "N changes not yet delivered", and the last sync time. A bridge that is off is never silent on the devices.

## Webhook API and doorbell alert

- **Webhook API.** `configure --webhook local|lan [--webhook-port N]` starts the existing webhook API (see the desktop README) with the bridge:
  - It is bearer-token authenticated and uses its own TLS certificate.
  - Its routes are a fixed, typed set (scenes, actions, runs), with no shell.
  - `webhook-info` prints the certificate fingerprint and SPKI pin; `--show-token` also prints the token.
- **Doorbell alert.** When the doorbell alert is included in the build (see [DOORBELL-ALERT.md](DOORBELL-ALERT.md)), the bridge hosts it in full: settings, the outbound Alexa relay poll, and `/v1/alerts/doorbell` on the webhook API. No Luma window is needed. Manage it with:
  - `luma-bridge alert status`, `alert enable`, `alert disable`
  - `alert set settings.json`
  - `alert relay https://…`: the relay token is read from a hidden prompt or stdin.
  - `alert forget-relay`, `alert unlink`
  - `alert alexa-code`: the account-linking code you enter in the Alexa app.

  The relay must be deployed by you first. Nothing here claims a live Blink or Alexa connection.

  **Run the doorbell alert in one place only:** either the bridge or a Luma window, never both. Its settings aren't shared through schedule sync. The relay allows one poller, and two hosts would flash the same lights twice. When the bridge hosts the alert, turn it off in the app (Automations, then Doorbell alert).

## Remote access

- The bridge listens on your LAN only. It never opens a public endpoint, port forward or tunnel.
- To manage schedules away from home, use a VPN to your home network, such as WireGuard or Tailscale. Changes made while you can't reach the bridge wait on the device and are delivered when you can.
- The pairing code lists every non-loopback IPv4 address of the bridge, so a VPN address appears there too.
- VPN pairing is not tested.
- Don't expose port 8788 or the webhook port to the internet.

## Command reference

| Command | Needs the bridge stopped | What it does |
| --- | --- | --- |
| `setup [--secrets B] [--port N]` | yes | Picks the secret backend, becomes the runner and prints the pairing code. If already set up, prints the code again. |
| `start` | (takes the lock) | Runs in the foreground. SIGINT, SIGTERM or SIGHUP stop it cleanly with exit code 0. |
| `status [--json]` | no | See above. |
| `pairing-code` | no | Prints the code(s) again. |
| `rotate-pairing` | yes | Creates a new token. All devices pair again. |
| `pair [--secrets B] [--port N]` / `take-over [--force] [--port N]` / `turn-off` | yes | Hand-off, as described above. `pair` works on a fresh folder. |
| `configure …` | yes | Options: `--port`, `--keep-awake on/off`, `--lan on/off`, `--webhook off/local/lan`, `--webhook-port`, `--govee-key`, `--forget-govee-key`. |
| `import-backup FILE [--secrets B]` | yes | Restores a `luma-home-backup` file. Use it on a fresh folder before `setup`. Refused while sharing. |
| `webhook-info [--show-token]` | no | Prints the webhook certificate pins and token. |
| `alert …` | yes | Doorbell alert settings, when the build includes it. |
| `service KIND` | no | Prints a service definition. |

## Limits and what is not verified

**Verified in this change (2026-11-02):**
- `desktop/src/test/bridge.test.ts` spawns the built CLI as a real process:
  - A paired client's edits and pause survive a restart.
  - SIGTERM gives exit 0 and releases the lock.
  - A second instance and state-changing commands are refused while it runs.
  - A wrong pin sends nothing; a wrong token gets 401.
  - No token, pin or code appears in the daemon output or data files, and the files are owner-only.
  - It refuses to start when not set up, in an app profile, on a port clash, with damaged `schedule-sync.json`, or with group-readable secrets.
  - A read-only data folder answers 503 and nothing is saved.
  - A stale lock is cleared, including one left by a process with the same PID, which is common for PID 1 in a container.
  - Hand-off between two bridges: `pair` on a fresh folder (code on stdin), then `take-over`. The old runner retires (`mayExecute: false`, 410 to devices), and the new one serves the schedules on its own port.
  - `import-backup` on a fresh folder, then `setup`, shares the imported schedules.
  - After a restart, the bridge executes due schedules. In-process, with the clock advanced: a paused schedule reports `paused`, and a schedule whose light isn't known reports `failed` with the reason. No write is sent. Run reports are saved.
  - The doorbell alert is configurable headless, when the alert patch is present.
- **Linux arm64 container** (`node:22-slim`, packed tarball only, no `node_modules`): setup, start, status and a clean stop. The `secret-service` backend was tested against a real gnome-keyring in a D-Bus session.
- **macOS keychain backend:** a throwaway keychain (`LUMA_BRIDGE_KEYCHAIN`) for setup, start and pairing-code. A locked keychain made the bridge refuse to start. The user's login keychain and keychain list were not touched.
- **Swift `URLSession` pinned client** (`swift test --filter liveElectronRunner`) against the running bridge: pull, pause applied on the bridge, wrong token 401, wrong pin refused.

**Not verified:**
- Windows: the DPAPI backend, the Task Scheduler snippet and the firewall prompt.
- A real Raspberry Pi: the container shares its CPU architecture, not its OS image or hardware clock.
- A real iPhone on Wi-Fi pairing with the bridge.
- The systemd and launchd units as installed services. They were generated and reviewed, not installed on a real account.
- `caffeinate` and `systemd-inhibit` holding off sleep.
- The macOS Local Network permission prompt for `node` under launchd.
- Physical lights running a scheduled scene: no light was written during this work.
- VPN pairing.

## For developers

- **Code:**
  - `desktop/src/bridge/bridge.ts`: runtime, lock, status, keep-awake.
  - `desktop/src/bridge/secret-store.ts`: the secret backends.
  - `desktop/src/bridge/cli.ts`: the CLI and service definitions.
  - `scripts/pack-bridge.mjs`: packaging.
- **Known core behavior:** `becomeRunner` silently leaves out a scene or schedule that the protocol refuses, for example a scene with no steps. This is unchanged from the app.
- **Reuse:** the bridge builds the same `Home` (`desktop/src/main/home.ts`) the Electron app builds. It adds two small `ScheduleSync` members (`listening`, `port`/`setPort`). The protocol and the schedule semantics are unchanged.
- **Embedding:** `startBridge({ dataDir, version })` returns `{ home, status(), stop() }`. `doorbellOf(home)` gives the optional doorbell controller.

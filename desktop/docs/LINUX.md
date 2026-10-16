# Luma on Linux

Status: **experimental, unsigned, untested on a real desktop.** The Linux build is verified only with synthetic demo data inside a virtual X display (Xvfb). Nothing here has been run on a real GNOME/KDE session, a real keyring, a real compositor, a real portal or real lights. Treat every "untested" row below as unproven.

## Support matrix

| Area | Status | Evidence |
| --- | --- | --- |
| Unit tests and typecheck (Node 22.12+, any OS) | Tested | `npm run typecheck`, `npm test` |
| x64 and arm64 portable `tar.gz` builds | Built (cross-built on macOS arm64); unsigned | `electron-builder.linux.cjs`, `release-linux/` |
| Demo (`--demo`) synthetic Screen Sync flow, arm64, Xvfb in a Docker container | Tested by root QA (see `docs/VERIFICATION.md` for results) | `scripts/linux-smoke.mjs` |
| Demo smoke on x64 and arm64 native Ubuntu 24.04 runners (setuid sandbox on) | CI defined in `.github/workflows/linux.yml`; **not yet run** | |
| Connected mode with GNOME Keyring / libsecret | **Untested** | policy tested in `src/test/linux-platform.test.ts` |
| Connected mode with KWallet 4/5/6 | **Untested** | same |
| X11 session real screen/window capture | **Untested** | |
| Wayland session capture via xdg-desktop-portal + PipeWire | **Untested, experimental** | |
| AppImage and `.deb` targets | **Not built, not tested** (opt-in on the command line) | |
| Other CPU architectures, snap, flatpak, rpm | Unsupported | |

Report hardware results by distro, version, desktop environment, session type and model SKU. No API keys or device IDs in shared reports.

## Runtime prerequisites

- 64-bit x64 or arm64 distro that can run Electron 44 / Chromium (glibc, GTK 3, NSS, `libgbm`, ALSA). Ubuntu 24.04 package names: `libgtk-3-0t64 libnss3 libgbm1 libasound2t64 libxss1 libxtst6 libatspi2.0-0t64 xdg-utils`.
- **A real keyring for cloud API keys and webhook tokens** (see below). LAN-only discovery and Screen Sync do not require a cloud key.
- A running desktop session. Demo and connected mode both need a display; headless use needs a virtual display such as Xvfb.
- Screen Sync capture needs an X11 session, or a Wayland session with `xdg-desktop-portal`, a compositor backend for it, and PipeWire.
- Screen Sync capture also needs **lock reporting**: a systemd-logind session (`loginctl`), `gdbus` (`libglib2.0-bin`), and a **GNOME or KDE Plasma** desktop (`XDG_CURRENT_DESKTOP`). See "Screen lock on Linux" below. Without it capture is refused with an explanatory message; LAN and cloud control still work.

## Install the portable tarball

```sh
tar -xzf luma-<version>-linux-<arch>.tar.gz
cd luma-<version>-linux-<arch>
./luma --demo        # synthetic, isolated, no network
./luma               # connected mode; cloud keys/webhook tokens need a keyring
```

Pick the archive for your CPU (`x64` or `arm64`); the architecture is in the file name. No FUSE and no installer are needed. The archives are **unsigned**; verify the SHA-256 listed in `SHA256SUMS.txt` or a CI `SHA256SUMS-*.txt` before running them.

### The Chromium sandbox stays on

Luma never ships or recommends `--no-sandbox`. An archive extracted by an ordinary user cannot establish the root ownership required by the setuid helper, so the bundled `chrome-sandbox` needs an appropriate sandbox environment after extraction. Chromium then needs one of:

1. **Unprivileged user namespaces** (most distros allow this). Nothing to do.
2. **The setuid helper**, installed by you as an operator, once, in a directory you control:
   ```sh
   sudo chown root:root chrome-sandbox
   sudo chmod 4755 chrome-sandbox
   ```
   Luma and its scripts never run `chmod`/`chown` for you.
3. On Ubuntu 23.10+/24.04, AppArmor restricts unprivileged user namespaces, so option 2 (or a distro-provided AppArmor profile) is required. Do **not** disable the AppArmor restriction system-wide just for this app.

If Electron aborts with "The SUID sandbox helper binary was found, but is not configured correctly", apply option 2. A `.deb` installs the helper with the right mode (when built; not yet tested).

The Docker QA script uses `--disable-setuid-sandbox` (user-namespace sandbox) together with `--security-opt seccomp=unconfined`. Those are **container-only** concessions to run Chromium under Docker's default seccomp profile, not desktop guidance.

## Secrets: keyring required, no plaintext fallback

Connected mode saves the Govee API key with Electron `safeStorage`. On Linux, Electron picks a backend from the desktop session; Luma accepts only a real keyring:

| `safeStorage.getSelectedStorageBackend()` | Luma connected-mode secrets |
| --- | --- |
| `gnome_libsecret` (GNOME, Cinnamon, XFCE, Pantheon, Deepin, UKUI, Unity) | allowed |
| `kwallet`, `kwallet5`, `kwallet6` (KDE) | allowed |
| `basic_text` | **refused** (plaintext/hard-coded key) |
| `unknown` (before app ready) | **refused** |
| anything else, or `isEncryptionAvailable() === false` | **refused** |

When refused, the UI says secure storage is unavailable and nothing is saved. Install and unlock a Secret Service provider (GNOME Keyring or KeePassXC with Secret Service enabled) or KWallet, then restart Luma. Do not start Luma with `--password-store=basic` or call `setUsePlainTextEncryption`; Luma will still refuse. The refusal logic is `isSecureLinuxBackend` / `linuxSecretsAvailable` in `src/main/linux-platform.ts`.

Connected data lives in Electron's app-data directory under **`LumaLinux`** (separate from the Windows `LumaWindows` profile): `~/.config/LumaLinux` by default. Encrypted secret files are separate from the home file. Demo uses a throwaway profile under the temp directory.

## Screen Sync on Linux

Same privacy rules as every platform: nothing starts at launch; you choose the source, lights and regions, then press Start; video only (no audio); no recording, thumbnails, pixel logs or uploads; source IDs are in-memory and never saved; a vanished or changed source fails closed. Demo uses generated synthetic frames and never calls the screen-capture APIs.

- **X11:** Luma lists screens/windows only when you ask, then re-enumerates at Start to confirm the chosen source still exists (same as Windows).
- **Wayland:** Electron's `desktopCapturer` uses the xdg-desktop-portal picker through PipeWire. [Electron documents](https://www.electronjs.org/docs/latest/api/desktop-capturer) that `getSources()` "only returns a single source on Linux when using Pipewire", and that a cancelled picker is a refusal. So on Wayland your choice happens in the system picker when you press **Choose screen or window**, Luma does **not** enumerate again at Start (a second call would open a second picker), and nothing is auto-selected. Re-choosing means a new portal prompt. Luma adds `--enable-features=WebRTCPipeWireCapturer` on Wayland; Electron's documentation lists no required switch, so this flag is a best-effort, **unvalidated** hint.
- **Unknown session** (no `XDG_SESSION_TYPE`/`WAYLAND_DISPLAY`/`DISPLAY`): treated like X11 (re-validate at Start); capture will simply fail closed if nothing is found.
- Session detection: `XDG_SESSION_TYPE` (`wayland`/`x11`), else `WAYLAND_DISPLAY`, else `DISPLAY`. XWayland sets both, so Wayland wins.
- **Screen lock** is observed by `src/main/linux-lock.ts`; see the next section. Capture is refused where the lock cannot be observed.
- Portal behavior, picker wording, restore-token handling, window-versus-screen results, sleep/lock, and display changes differ between GNOME, KDE, wlroots and others. None of it has been validated here.

### Screen lock on Linux

Electron's `powerMonitor` `lock-screen` event exists only on macOS and Windows, so Luma reads systemd-logind's `Session.LockedHint` itself ([org.freedesktop.login1](https://github.com/systemd/systemd/blob/main/man/org.freedesktop.login1.xml)), read-only:

- `loginctl show-session <XDG_SESSION_ID or self> -p LockedHint --value` (fixed arguments, no shell, 2 s timeout, 1 KB output cap; a session id that is not a short plain token is refused).
- `gdbus monitor --system --dest org.freedesktop.login1` keeps a D-Bus signal subscription open. A `Session.Lock` signal or `LockedHint` becoming true invalidates **immediately** (any session's lock counts, so Luma may over-stop on a multi-session machine), without waiting for a read, so a quick Lock then Unlock cannot slip past; other lock-related signals trigger a fresh read. If `login1` vanishes or changes owner (logind restart) the subscription is treated as lost, because gdbus keeps running but silently unsubscribes.
- Luma accepts "unlocked" only from a read taken after the subscription was reported ready, and only while it stays alive. gdbus prints its "name is owned by" line *before* it subscribes (GLib `gdbus-tool.c`), so that line is not an acknowledgement: Luma waits 300 ms after it and refuses an attempt that sees a lock before then. A lock/unlock pair missed before subscription can remain undetected; the delay is a heuristic, not a subscription acknowledgement.
- While offered sources exist (about two minutes after Choose), or a session is running or paused, it also re-reads every 500 ms. Nothing is spawned at launch, in demo, on Windows or on macOS; the first spawn is your first Choose or Start. The subscription is stopped when Luma quits.

**Fails closed:** a locked report, an unsupported desktop, a missing or failing `loginctl`/`gdbus`, an unreadable or timed-out answer, or a lost subscription each revoke offered sources and stop the session (no restore, nothing restarts on unlock) and refuse Choose and Start until a fresh read affirms "unlocked" again.

**Limits, stated plainly:**

- `LockedHint` is set by the desktop's screen locker, not by logind. A desktop that never sets it reports "no" (unlocked) forever, which looks the same as unlocked. Luma therefore allows only GNOME and KDE Plasma, which are expected to set it, and refuses every other desktop (XFCE, Cinnamon, MATE, i3/sway lockers and others) rather than guess. Even on GNOME and KDE this is **unvalidated on real desktops**; the lock-then-unlock-quickly and third-party-locker cases are untested.
- Polling catches a lock that remains set when read; it cannot detect an entire lock/unlock pair whose signals were missed. The signal path is not proven on a real session.
- Pausing, muting and hiding the window are not treated as lock detection.
- Release gate: on GNOME and KDE (X11 and Wayland), lock with the session menu, `loginctl lock-session` and the idle timeout while a session is running, paused, and with sources only offered; confirm each stops capture and that unlocking does not restart it; confirm a desktop outside the allowlist is refused.

## Build

From the repo (Node 22.12+; build host may be macOS or Linux):

```sh
npm ci && npm run runtime:install
npm run typecheck && npm test
npm run dist:linux     # x64 + arm64 tar.gz into release-linux/
```

`dist:linux` is `npm run build && electron-builder --config electron-builder.linux.cjs --linux tar.gz --x64 --arm64`. The config inherits the shared `build` block from `package.json` and drops the Windows `win`/`nsis` sections, so Windows packaging is unchanged. Artifacts are named `luma-<version>-linux-<arch>.tar.gz`; the unpacked directories are `release-linux/linux-unpacked` (x64) and `release-linux/linux-arm64-unpacked` (arm64). Cross-building from macOS downloads the Linux Electron zips into the standard Electron cache on first use. Add `AppImage` or `deb` to the `--linux` list only on a host that has the required tools; those targets are untested here. (The electron.build Linux page could not be read when this was written, so no AppImage/deb tooling claims are made.)

## Verify

Synthetic only. The smoke test launches `--demo` with a loopback-only DevTools port and drives the real renderer: preload sandbox, refusal of `getDisplayMedia` (video and audio), choose a synthetic source and light, Start (real frame pump and module worker), Pause, Resume, Stop with counters stable, stale-frame rejection, confirmed light state unchanged, and renderer reload ending a paused session.

```sh
# Linux with a display or Xvfb (run as a normal user, never root):
xvfb-run -a node scripts/linux-smoke.mjs --app release-linux/linux-unpacked/luma
# Dev tree:
xvfb-run -a node scripts/linux-smoke.mjs
# Docker (image: docker build -t luma-linux-qa:node24 qa/linux; no network; container-only sandbox concessions):
scripts/linux-container-smoke.sh release-linux/linux-arm64-unpacked luma
```

The script refuses `--no-sandbox` and refuses to run as root. A container's architecture must match the bundle (an arm64 Docker daemon runs the arm64 bundle).

CI (`.github/workflows/linux.yml`) runs typecheck, tests, builds the tarball and smoke-tests the **extracted tarball** with the setuid sandbox on, on `ubuntu-24.04` (x64) and `ubuntu-24.04-arm` (arm64), then uploads unsigned artifacts with SHA-256 hashes. It has not run yet.

## Release gate (operator, real desktop)

1. Install/unpack on a clean user on each target distro; set up the sandbox helper as above; launch demo.
2. Connect with an existing API key; confirm it is stored in the keyring (not plaintext) and survives restart; confirm refusal with the keyring locked/absent.
3. LAN: discovery, UDP 4002 conflict reporting, webhook listener only when deliberately enabled; firewall changes are the operator's deliberate action.
4. X11: choose a screen and a window, Start, Pause, Stop, change displays, lock/suspend; confirm capture ends and does not restart on its own.
5. Wayland (per compositor): the portal picker appears only on Choose, cancel leaves no capture, one pick yields one source, Start opens no second picker, and display change/lock/suspend stop the session.
6. Record distro/version, desktop, session type, architecture, artifact SHA-256, app version, and pass/fail evidence. Unsigned artifacts must not be described as signed.

# Contributing to Luma

Luma is an experimental open-source project built by **Design X Develop LLC**, provided as is under the [MIT License](LICENSE). Issues and pull requests are welcome.

## Report a problem

[Open an Issue](https://github.com/designxdevelop/luma/issues) with your Luma version, operating system, Govee model, connection type (LAN or cloud), and reproduction steps. Describe the expected and actual behavior. Screen Sync reports should also identify display/window selection, compositor on Linux, and whether the problem occurs with the synthetic demo.

Never post API keys, webhook tokens, passwords, secret-store contents, personal device inventories, or private screen captures. Redact logs and screenshots before sharing them.

## Make a change

1. Fork and clone the repository, then create a branch for your change.
2. For native macOS, use Swift 6.2+ on macOS 14+: `./scripts/verify.sh`, then `./scripts/build-app.sh`. Follow [the Mac guide](MACOS.md) to try the isolated demo.
3. For Windows/Linux, run `npm ci`, `npm run runtime:install`, `npm run typecheck`, and `npm test` from `desktop/`. Use `npm run demo` for synthetic UI checks. See [the desktop guide](desktop/README.md).
4. Open a pull request describing the behavior change, why it helps, and what you verified. State the actual OS/runtime and whether real hardware was involved.

Use focused changes and tests that establish behavior. Keep reported device state separate from pending user requests. Preserve ordered writes, cancellation, bounded network work, and slider/toggle regressions. Use each model's advertised capabilities and bounds instead of assuming support from its name.

Screen capture must remain an explicit user choice. Keep frames local, never save or upload pixels, and preserve stop, pause, lock/sleep, and manual-override behavior. Use synthetic frames and lights during automated testing. Build success on one OS is not proof of another platform's runtime behavior.

App data belongs outside the repository. Never commit personal home configurations, credentials, private captures, dependency folders, or generated application bundles.

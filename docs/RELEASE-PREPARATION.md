# Beta release preparation — 2026-11-02

Source: PR #5, e3a3d8d450d8d74e47a1dfcbb9d48bf3a9bb632c. Local changes only affect bridge tests and this note; no merge or public release performed.

## Apple

Release archives succeeded with CODE_SIGNING_ALLOWED=NO and candidate CURRENT_PROJECT_VERSION=202611021:

- /tmp/luma-release/Luma-iOS.xcarchive — iPhone/iPad, embedded LumaWatch.app.
- /tmp/luma-release/Luma-macOS.xcarchive — native macOS.

These are unsigned preparation artifacts, not TestFlight submissions. Build number uniqueness against App Store Connect has not been checked. Only Apple Development identity was available; no distribution identity was found. No connected App Store Connect tool was discovered. 2password saved-token access failed; its desktop route also failed to connect to 1Password. No passwords or authentication settings were changed. Restore secure credential access and configure distribution signing/team before signed archive/export/upload. Xcode beta SDK acceptance by App Store Connect also requires validation.

## Encryption review

GoveeBLECrypto.swift uses Apple's CommonCrypto AES/RC4 and CryptoKit AES-GCM. This is operating-system crypto, not a bundled implementation. Apple's guidance lists crypto functionality within Apple's operating system among documentation exemptions, supporting the existing ITSAppUsesNonExemptEncryption=NO as an inference. The vendor protocol and actual App Store Connect questionnaire must still be reviewed before submission; no legal classification or questionnaire answers were invented.

Primary references:
- https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
- https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations

## Desktop

Windows run 41517047689 failed before installer creation: bridge fixtures selected the intentionally forbidden file backend and assumed POSIX path separators. Fixtures now choose DPAPI on Windows and normalize path expectations. Production restrictions and CI checks remain intact. All 271 desktop tests passed locally on macOS; Windows DPAPI behavior and installer require a fresh Windows CI run. Changes are uncommitted for the parent to integrate.

Linux packaging uses npm run dist:linux -- --publish never in desktop. Both x64 and arm64 tar.gz builds completed successfully under desktop/release-linux. Archive listing integrity and SHA-256 hashes are recorded under /tmp/luma-release. These are cross-built packages, unverified on Linux hardware. Windows packaging is npm run dist:win -- --publish never on Windows; no Windows installer is claimed ready.

## Beta limitations

Unverified on physical hardware. No platform parity promise. Android project/configuration absent; Android implementation must begin only after PR merge. No Android task started.

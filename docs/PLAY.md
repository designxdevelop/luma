# Google Play: internal testing

Internal testing is Play's equivalent of TestFlight. You add up to 100 testers by email. Each tester opens an opt-in link once and then installs Luma from the Play Store. A new build usually reaches testers within minutes and doesn't wait for a full review.

`versionName` always stays `1.0`. Each upload needs a higher `versionCode`: pass `-PversionCode=N`, or let CI use `GITHUB_RUN_NUMBER`.

## 1. Create the upload key (once)

```bash
android/scripts/new-upload-key.sh
```

This creates `~/.android/luma-upload.jks` with alias `luma-upload`. `keytool` asks for a password. Save it in 1Password, for example as **Luma Android Upload Keystore** in the Automation vault, and back up the `.jks` file. With Play App Signing, Google holds the real app-signing key, and a lost upload key can be reset through Play support.

## 2. Build a signed bundle

```bash
cd android
2password run --env "LUMA_UPLOAD_PASSWORD=op://Automation/Luma Android Upload Keystore/credential" -- \
  env LUMA_UPLOAD_KEYSTORE=$HOME/.android/luma-upload.jks ./gradlew bundleRelease -PversionCode=2
```

The output is `android/app/build/outputs/bundle/release/app-release.aab`. Without `LUMA_UPLOAD_KEYSTORE`, the release build is unsigned, and `assembleDebug`/`test` never need it.

## 3. Play Console steps (you do these)

1. **Create app:**
   - Name: Luma.
   - Default language: English (US).
   - App, not game. Free.
   - Accept the declarations.
2. **App content:**
   - **Privacy policy:** https://luma.designxdevelop.com/privacy
   - **Ads:** No.
   - **App access:** All functionality is available without special access. Reviewers can tap **Try demo** on the first screen.
   - **Content rating:** answer the questionnaire as a utility with no user content. It should come out Everyone.
   - **Target audience:** 18+. This avoids the Families policy; the app isn't designed for children.
   - **Data safety:** see the draft below. **Confirm it before you submit.**
   - **Government apps / financial features / health:** No.
3. **Testing → Internal testing:**
   - Create a release.
   - Upload the AAB. The first upload must be manual; this also enrols Play App Signing.
   - Add a tester email list, then save and roll out.
   - Copy the opt-in link and send it to testers.
4. **Main store listing:** use the copy below. Screenshots: phone captures from `docs/qa/android/` work for internal testing. Production needs at least 2 phone screenshots, a 512×512 icon and a 1024×500 feature graphic.

If this developer account is a personal account created after November 13, 2023, production access needs a closed test first: at least 12 testers opted in for 14 days in a row. Internal testing has no such requirement.

The app targets API 36, which meets Play's target-API requirement for new apps in 2026. Check Play Console's warning banner if that changes.

## Wear OS app

`./gradlew bundleRelease` also builds `android/wear/build/outputs/bundle/release/wear-release.aab`, with the same package and the same `versionName` 1.0. To ship it:

1. In Play Console → **Test and release → Advanced settings → Form factors**, add **Wear OS**.
2. Upload this AAB to the Wear OS internal track. It's signed with the same upload key. Its `versionCode` is automatically the phone's plus 100000, so the two bundles never collide.

The CI workflow uploads only the phone bundle.

## 4. Optional: upload from CI

`.github/workflows/android-release.yml` is a manual workflow (**Actions → Android release → Run workflow**). It builds a signed AAB, with `versionCode` set to the run number, and uploads it to the internal track. It skips the upload unless these repository secrets exist:

| Secret | Value |
| --- | --- |
| `LUMA_UPLOAD_KEYSTORE_BASE64` | `base64 -i ~/.android/luma-upload.jks` |
| `LUMA_UPLOAD_PASSWORD` | the keystore password |
| `PLAY_SERVICE_ACCOUNT_JSON` | JSON key for a Google Cloud service account invited in Play Console (Users and permissions) with **Release to testing tracks** |

It only works after the first manual upload in step 3.

## Store listing copy (adapted from `docs/app-store/LISTING.md`)

**App name:** Luma: Smart Light Control

**Short description (80):** Control Govee lights by room, with scenes, schedules and local Wi-Fi control.

**Full description:**

Luma is an experimental, open-source app for controlling Govee lights.

- Lights grouped by room, with a room switch and Adjust for brightness and white
- Power, brightness, color and white temperature for each light, plus Govee effects
- Scenes: save the current look and run it with one tap
- Schedules that run a scene at a time of day
- Direct LAN control over Wi-Fi, with no account needed, or Govee cloud control with your own free API key
- DreamView on/off for TV backlights
- Backup and restore that works with Luma on iPhone, Mac, Windows and Linux
- Demo mode with sample lights, no hardware needed
- No account, no ads, no tracking

Good to know: Android can stop apps in the background, so a schedule can be missed while Luma is closed. Model support varies. Luma is open source (MIT) and is not affiliated with or endorsed by Govee.

**Category:** Tools. **Contact email / website:** https://luma.designxdevelop.com/support

## Data safety (draft; the answers are your decision)

Features that send or capture data, and how each is handled:

| Feature | What happens | Likely answer |
| --- | --- | --- |
| Govee cloud (optional API key) | The key, light IDs and commands go to `openapi.api.govee.com` at your request. The key is stored encrypted on the phone. | Sent to a service the user chose; not shared or sold |
| Govee Home sign-in (optional) | Your email and password go to `app2.govee.com` to read rooms, groups and automations. The password isn't stored; the session token is sealed on the phone. | **Personal info → Email address**: collected, not shared, optional, for app functionality |
| Camera (Screen Sync) | Frames are reduced to a color grid in memory and never saved or sent. | Not collected (processed only on the device) |
| Microphone (Audio Sync) | Reduced to loudness and 8 levels in memory; no audio is kept or sent. | Not collected (processed only on the device) |
| Bluetooth scan | Finds Govee TV backlights. `neverForLocation` on Android 12+; Android 11 and earlier require location permission to scan, and no location is read. | Not collected |
| Schedule sync | Scenes and schedules go only to your own computer on your network, over pinned TLS. | Not collected (no third party) |
| Exact alarms | `SCHEDULE_EXACT_ALARM` runs schedules on time. | Not a data type |

The App Store label is "Data Not Collected". With Govee Home sign-in on Android, answering **Email address** as collected (optional) is the safer choice. Also declare the `SCHEDULE_EXACT_ALARM` use in Play Console's exact-alarm declaration, if it asks.

### Earlier draft

- **Does your app collect or share any of the required user data types?** No.
- **Rationale to check:**
  - Luma has no server. The Govee API key you enter is stored encrypted on the phone.
  - The key is sent only to Govee's API (`openapi.api.govee.com`), along with light IDs and commands, so Govee can control your own lights at your request.
  - Light state and names stay on the device.
  - Exported backups go only where you save them.

  Play treats data sent to a service at the user's request as not "shared". Whether it's "collected" depends on whether you consider the Govee API key and device IDs to be data the app collects. If you're unsure, answer *Yes* for **App info and performance → Other** or **Device or other IDs**, marked as *not shared*, *processed ephemerally: no*, and *required for cloud control (optional feature)*.
- **Encrypted in transit:** Yes (HTTPS to Govee; local LAN control is plain UDP on your own network, as Govee's protocol requires).
- **Can users request deletion?** Remove the key in Settings, or uninstall. Nothing is stored off the device.

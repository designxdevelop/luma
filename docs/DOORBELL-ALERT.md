# Doorbell alert

When the doorbell rings, Luma flashes the lights you chose with slow pulses. Then it puts each light back the way it was.

The trigger path is an Alexa routine that runs a smart home **scene**:

> When the **Blink doorbell is pressed**, then **Control scene: Doorbell Alert**.

The scene comes from a small, private Alexa skill that you deploy to your own accounts. The skill passes the press to Luma through a relay. Luma opens an outbound HTTPS long poll to the relay, so nothing on your Mac or PC is opened to the internet.

Home Assistant and scripts can ring the same alert through Luma's existing authenticated webhook server.

## What it does

- **Lights.** Rooms are looked up when the bell rings, so a light you add to a room later is included. You can also pick individual lights. Appliances and sensors are never included. At most 20 lights are alerted.
- **Effect.**
  1. Power on (only for lamps that were off).
  2. Set the alert color.
  3. Pulse between full brightness and 20%.

  You set the color, the length (5–60 s), the pulse (2–6 s per cycle, so at most 0.5 Hz), and a brightness cap. Quiet hours can lower the cap, or set it to 0 to leave the lights alone.
- **Snapshot first, never guessed.** Before the first write, Luma reads every light fresh: LAN status within 1.5 s, or a cloud state read within 3 s.
  - A light is skipped if Luma doesn't know its power, its brightness, and its color or white.
  - A light is also skipped if it is offline or doesn't answer the read.
  - The saved state from earlier is never used.
- **Restore.** Luma writes color or white first, then brightness, then power. A lamp that was off goes back off without holding the alert color hidden. Luma then reads each light once.
  - The summary says *restored* only for lights that reported the snapshot back.
  - Lights that didn't report it back are listed as *sent but not confirmed*.
- **Conflicts.**
  - Lights that are skipped:
    - Lights in Screen Sync or Audio Sync.
    - Lights with DreamView on.
    - Lights with a change still pending.
  - While a light flashes, Screen Sync frames are held off it.
  - Any change you make in Luma during the alert takes that light: a control, a room action, a scene, a schedule or a webhook. The alert stops flashing it and does **not** restore over your change.
- **Repeated rings.**
  - A ring during an alert (or during its restore) joins the running alert; alerts never stack.
  - A replay of the same event ID is ignored for 10 minutes.
  - After an alert, a cooldown (20 s by default) ignores new rings.
- **Rate limits.**
  - LAN lights get at most one brightness change per second, with 20 ms between lights.
  - Cloud-only lights hold the alert color instead of pulsing. Each cloud light uses about 7 requests per alert and is not alerted again within 60 s. Govee documents 10,000 cloud requests a day. The figure of about 10 per device per minute comes from integrators, not Govee.
- **Stop and quit.**
  - **Stop** (in the app, `POST …/stop`, or "Alexa, turn off Doorbell Alert") ends the pulse early and restores.
  - Quitting during an alert sends the owed restores at once. This is best effort: LAN restores are sent immediately, and cloud restores get about 2 s and may not finish.

## Limits

- Luma must be running, and the Mac or PC must be awake. On iPhone and iPad, iOS suspends the long poll in the background, so the alert works only while Luma is open.
- Changes made **outside Luma** during the alert aren't detected. This includes the Govee Home app, the Govee Alexa skill, and a physical switch. In those cases the restore can overwrite them.
- If a Govee built-in scene or DIY effect was playing, the light comes back to its last reported color. The effect doesn't resume, because Luma can't read which effect is running.
- Expect about 1–3 s from press to flash: Alexa's routine plus one relay hop.
- None of this has been tested with a real Blink doorbell, Echo, or Govee light. The automated tests use fakes and the demo home. See [Verification](#verification).

## How the Alexa route works, and why this one

Amazon documents Blink doorbell presses as an Alexa **routine trigger**. Blink's own help pages say a routine can start "when someone presses the Blink Video Doorbell" once the Blink SmartHome skill is enabled ([Blink: Alexa routines](https://support.blinkforhome.com/it_IT/routines-alexa)).

A routine can't call a private URL. It can control smart home devices and **scenes** that a skill discovered. A scene is an `Alexa.SceneController` endpoint: the skill reports it during discovery, and Alexa sends `Activate` to the skill when a routine runs it ([SceneController](https://developer.amazon.com/en-US/docs/alexa/device-apis/alexa-scenecontroller.html)). Homey uses the same pattern for its flows ([Homey: Start Flows with Alexa](https://support.homey.app/hc/en-us/articles/4409837342354-Start-Flows-with-Amazon-Alexa)).

Smart home skills must run on AWS Lambda and must use OAuth account linking ([Steps to build a smart home skill](https://developer.amazon.com/en-US/docs/alexa/smarthome/steps-to-build-a-smart-home-skill.html)).

```
Blink press → Alexa routine → Control scene "Doorbell Alert"
  → Alexa.SceneController.Activate → your Lambda (forwarder, ~30 lines)
  → POST /alexa on your relay (Cloudflare Worker + Durable Object)
  → queued ≤30 s → Luma's outbound long poll (POST /hub/next) → alert
```

Options considered:

| Route | Verdict |
| --- | --- |
| **Private smart home skill scene + your own relay** (built) | Uses only Alexa's documented trigger and scene features. Nothing on your network listens. The relay can only queue *activate* or *deactivate*: it carries no commands or light data. Costs: one-time setup in three consoles (Amazon developer, AWS, Cloudflare), and a cloud hop. |
| Matter virtual device on the LAN (Alexa as controller) | Local, with no cloud. But Luma would need a full Matter accessory stack (commissioning, CASE, attestation). Alexa's acceptance of uncertified test devices is uncertain, and native Swift has no accessory library. Not built. |
| Third-party "URL switch" or virtual-switch services | They need Luma reachable from the internet, or a key embedded in a URL. Rejected. |
| Alexa routine controlling Govee lights directly (Govee skill) | Works today without Luma, but it can't save and restore each light's exact state, and it doesn't know about conflicts. |
| Home Assistant (Blink integration or an Alexa virtual switch) → Luma webhook | Supported now with `POST /v1/alerts/doorbell`, below. |

## Set-up (about 30 minutes)

You need these, each in your own name:

- A free [Amazon Developer](https://developer.amazon.com) account, signed in with the **same Amazon account as your Alexa app**. A private skill in development mode is available to that account only.
- An AWS account (Lambda free tier).
- A Cloudflare account. The Workers free plan with Durable Objects is enough: Luma's always-held poll uses about 0.125 GB × 86,400 s ≈ 10,800 GB-s a day, against a free limit of 13,000 GB-s a day and 100,000 requests a day. Run only **one** Luma against a relay; a second always-on poller would go over the free duration limit.

Nothing is deployed for you, and no credential goes into this repository.

### 1. Deploy the relay

```sh
cd alexa-relay
npm test                      # 4 contract tests, no network
wrangler deploy               # note the https://luma-alexa-relay.<you>.workers.dev URL
openssl rand -base64 32       # HUB_TOKEN: Luma's key to the relay
openssl rand -base64 32       # LAMBDA_SECRET
openssl rand -base64 24       # ALEXA_CLIENT_SECRET
wrangler secret put HUB_TOKEN
wrangler secret put LAMBDA_SECRET
wrangler secret put ALEXA_CLIENT_ID          # any name, e.g. luma-alexa
wrangler secret put ALEXA_CLIENT_SECRET
```

`ALEXA_REDIRECT_URIS` is set in step 3. Keep these values in your password manager.

### 2. Create the skill and the Lambda

1. In the [Alexa developer console](https://developer.amazon.com/alexa/console/ask), create a skill.
   - **Name:** Luma Doorbell Alert
   - **Model:** Smart Home
   - **Hosting:** Provision your own

   Copy the **Skill ID**.
2. In AWS Lambda, create a **Node.js 22** function in **us-east-1 (N. Virginia)**. Other regions by locale:
   - **eu-west-1:** UK, DE, FR, IT, ES, IN
   - **us-west-2:** AU, JP

   Then set it up:
   1. Paste `alexa-relay/lambda/index.mjs` into the function.
   2. Set the environment variables `RELAY_URL` (your Worker URL) and `LAMBDA_SECRET`.
   3. Add an **Alexa Smart Home** trigger with *Skill ID verification* set to your Skill ID.
3. In the skill's **Smart Home** page, set the *Default endpoint* to the Lambda ARN. `skill-package/skill.json` is an equivalent manifest if you use the ASK CLI.

### 3. Account linking

On the skill's **Account Linking** page:

| Field | Value |
| --- | --- |
| Authorization grant type | Auth Code Grant |
| Web Authorization URI | `https://<relay>/oauth/authorize` |
| Access Token URI | `https://<relay>/oauth/token` |
| Your Client ID / Secret | your `ALEXA_CLIENT_ID` / `ALEXA_CLIENT_SECRET` |
| Authentication scheme | HTTP Basic (body credentials also work) |
| Scope | `doorbell` (the relay ignores it) |

Copy the **Alexa Redirect URLs** listed on that page into the relay, comma-separated:

```sh
wrangler secret put ALEXA_REDIRECT_URIS
```

### 4. Connect Luma

1. Open **Automations › Doorbell alert**.
2. Choose rooms or lights, set the look, and turn it on.
3. Under *Alexa and your doorbell*, enter the relay address and `HUB_TOKEN`. Luma stores the token in the Keychain (Mac and iOS), DPAPI (Windows), or the keyring (Linux), and never shows it again.
4. Check that the status says **Connected · waiting for Alexa**.
5. Press **Get Pairing Code**.

### 5. Link, discover, add the routine

1. In the Alexa app, open **More › Skills & Games › Your Skills › Dev › Luma Doorbell Alert › Enable**.
2. Enter Luma's pairing code on the relay page. The code is single use, lasts 10 minutes, and allows 5 tries.
3. Let Alexa discover devices. The scene **Doorbell Alert** appears.
4. Make sure the **Blink SmartHome** skill is enabled and linked.
5. Go to **Routines › +** and set it up:
   - **When this happens:** Smart Home › your Blink doorbell › *pressed*. The exact label is set by Alexa, so pick the doorbell-press event your app shows.
   - **Action:** Smart Home › Control scene › **Doorbell Alert**.
6. Test it: "Alexa, turn on Doorbell Alert", or press the bell.

To revoke access, use **Unlink Alexa** in Luma (this deletes every token on the relay), or rotate `HUB_TOKEN`.

## Home Assistant and scripts (webhook)

The ring route is on the existing webhook server. It has the same HTTPS, bearer token and certificate pinning as everything else (see [MACOS.md](../MACOS.md#webhook-api) or [desktop/README.md](../desktop/README.md)):

```sh
curl --cacert luma.pem -X POST https://127.0.0.1:8787/v1/alerts/doorbell \
  -H "Authorization: Bearer $LUMA_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"eventId\":\"ha-$(uuidgen)\",\"timestamp\":$(date +%s)}"
```

- **Body.** `eventId` is 8–128 characters from `A–Z a–z 0–9 - _ . :`. Repeats are reported as `duplicate`. `timestamp` is Unix seconds within ±120 s of Luma's clock, otherwise the reply is 409.
- **Reply.** `202 {"outcome": "started" | "coalesced" | "cooldown" | "duplicate" | "quiet"}`, or 409 when the alert is off.
- **Other routes.** `GET /v1/alerts/doorbell` returns status. `POST /v1/alerts/doorbell/stop` stops the alert and restores.

## Where it runs

The alert runs inside whichever Luma process owns the lights: the Mac or iOS app, or the Windows or Linux app.

The desktop alert code (`desktop/src/core/doorbell.ts` and `desktop/src/main/doorbell.ts`) has no Electron dependency. A headless Luma on an always-on host can create `DoorbellController` with its own light hooks.

The relay only carries Alexa's doorbell scene to Luma. It is not a general hub, and its pairing code exists only for Alexa account linking. Pairing between Luma computers stays with schedule sync ([SCHEDULE-SYNC.md](SCHEDULE-SYNC.md)).

## Security summary

- **Luma ↔ relay.** HTTPS with the `HUB_TOKEN` bearer, outbound from Luma only.
- **Events.** An event older than 30 s is dropped at the relay. Luma ignores events more than 60 s from its clock and de-duplicates by Alexa message ID.
- **Lambda → relay.** A shared `LAMBDA_SECRET`, plus the Lambda trigger restricted to your Skill ID.
- **OAuth.**
  - Only exact configured redirect URLs are accepted.
  - The pairing code is single use (10 min, 5 tries).
  - Auth codes are single use (2 min).
  - Access tokens last 1 h. Refresh tokens rotate.
  - All of these are stored only as SHA-256 hashes.
  - Unknown, expired or forged tokens get Alexa's credential errors.
- **No shell, no arbitrary commands.** The relay and the ring route can only start or stop this one alert.

## Verification

- **Swift (`./scripts/verify.sh`).** 210 tests, 18 of them for this feature. The core runs on a virtual clock. It covers:
  - the timed sequence and pulse rate
  - exact restore of an off white lamp
  - cloud hold
  - skipping lights with unknown state
  - manual takeover
  - coalesce, duplicate and cooldown
  - failed writes and offline lights
  - stop, quiet hours, and room membership at ring time
  - the cloud reuse guard and shutdown hand-back
  - config bounds

  The store tests use **actual cloud transport** through a stubbed URLSession. On the wire they assert this order: a fresh read, then `colorRgb` and `brightness`, then the exact restore, then a confirming read. They also cover:
  - rejection of bad, replayed and stale webhook rings
  - a manual control winning
  - DreamView lights being skipped
  - restore at shutdown
  - white outside 2000–9000 K restoring by cloud, not LAN
- **Desktop (`npm test`).** 247 tests, 9 of them for this feature. These include a fake UDP light that shows the **LAN wire**: a `devStatus` read, `colorwc`, brightness 100/20 pulses, the exact restore, and a confirming `devStatus`. They also cover the relay client, and a light with a saved IP but no live LAN session being treated as cloud (it holds the color and doesn't pulse).
- **Relay (`alexa-relay`, `npm test`).** 4 tests:
  - pairing → OAuth → discovery → `Activate` reaching a waiting long poll, and `AcceptGrant`
  - the Lambda forwarder
  - forged callers, wrong redirects, reused codes and guessed pairing codes
  - offline hub, stale events, expiry, refresh rotation, and unlink

  `wrangler deploy --dry-run` bundles the Worker.
- **UI.** Demo-mode QA of Test Alert on an iOS 27.2 simulator and on the Electron demo: *Flashing* → "Flashed 3 lights; restored 3."
- **Not verified.** A real Blink doorbell, the Alexa routine, account linking against Amazon, deployed Lambda and Worker, and real Govee lights.

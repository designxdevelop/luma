# Govee control protocols: research for a native macOS app

Researched 2026-10-15. Read-only: no credentials were used, no device was contacted, and no light was changed. Every packet example below was generated offline with `python3 -I`.

**Evidence labels:** **[OFFICIAL]** = Govee developer docs. **[IMPL]** = maintained open-source code (commit pinned below). **[UNDOC]** = a reverse-engineered or undocumented Govee endpoint, which can break without notice. **[INFERRED]** = my reading, not stated by any source.

No Govee binary was supplied, so this contains no APK or IPA reverse engineering. No third-party APKs were acquired.

## Sources (pinned)

| Source | Ref |
|---|---|
| Govee OpenAPI index | https://developer.govee.com/llms.txt |
| Get devices | https://developer.govee.com/reference/get-you-devices |
| Control device | https://developer.govee.com/reference/control-you-devices |
| Get device state | https://developer.govee.com/reference/get-devices-status |
| Dynamic and DIY scenes | https://developer.govee.com/reference/get-light-scene |
| Subscribe device event (MQTT) | https://developer.govee.com/reference/subscribe-device-event |
| Apply for an API key | https://developer.govee.com/reference/apply-you-govee-api-key |
| Key rotation policy (2026-05-15) | https://developer.govee.com/changelog/important-policy-update-important-notice-regarding-api-key-security-management |
| Official LAN guide (client-rendered, see the note below) | https://app-h5.govee.com/user-manual/wlan-guide |
| govee-local-api (the library behind Home Assistant's `govee_light_local`) | https://github.com/Galorhallen/govee-local-api @ `413fb740feda579d04f92405a618ab08e6a85eae` |
| govee2mqtt | https://github.com/wez/govee2mqtt @ `6f5a8449ca63da8bdc7cc696288a993681ff2a69` |
| OpenRGB Govee controller (Razer/DreamView) | https://gitlab.com/CalcProgrammer1/OpenRGB/-/blob/6a10f77c15e4be47c792b89f1a3cc4e992389684/Controllers/GoveeController/GoveeController.cpp |
| Govee BLE reverse engineering | https://github.com/egold555/Govee-Reverse-Engineering @ `900b003174f5ecd6708b3d5266ea0514926aefa1` |
| openHAB Govee LAN binding | https://www.openhab.org/addons/bindings/govee/ |

The official WLAN guide renders its text from i18n bundles and loads its SKU list from an API, so I could not read its body directly. The LAN details below are credited to the four implementations, which all agree. Use the guide's URL only as the user-facing "how to enable LAN control" link.

---

## 1. Cloud: Govee OpenAPI v1 router [OFFICIAL]

- **Base URL:** `https://openapi.api.govee.com/router/api/v1`
- **Headers:** `Content-Type: application/json` and `Govee-API-Key: <key>`. The docs show `Host: https://…`, which is a doc bug. Let the HTTP client set Host.
- **Status:** the developer platform describes itself as **beta**.

| Purpose | Method and path | Rate limit [OFFICIAL] |
|---|---|---|
| Enumerate devices and capabilities | `GET /user/devices` | 30/min per account (burst 30) |
| Read state | `POST /device/state` | 30/min per device (burst 30) |
| Control | `POST /device/control` | 12/s per account (burst 80), **2/s per device (burst 6)** |
| List dynamic scenes (`lightScene`) | `POST /device/scenes` | 30/min per device |
| List DIY scenes | `POST /device/diy-scenes` | not stated |

A rate-limit hit returns HTTP **429**. An invalid key returns **401**. Validation errors return **400**, with messages such as "Parameter value out of range". An unknown instance or device returns **404**.

The commonly cited "10,000 requests/day" cap comes from secondary sources (Home Assistant forums, apis.io) and describes the **legacy** `developer-api.govee.com/v1` API. The OpenAPI docs state no daily cap. My keyless probe of `https://developer-api.govee.com/v1/devices` returned 401. That shows the host is still reachable, not that the API still works. **Do not build on legacy v1.**

### 1.1 Device enumeration

```sh
curl -s https://openapi.api.govee.com/router/api/v1/user/devices \
  -H "Govee-API-Key: $GOVEE_KEY"
```

Illustrative response, condensed from the official page. The `deviceName` value and the option shapes are mine:

```json
{"code":200,"message":"success","data":[{"sku":"H605C","device":"AA:BB:CC:DD:EE:FF:00:11","deviceName":"Desk","type":"devices.types.light",
 "capabilities":[
  {"type":"devices.capabilities.on_off","instance":"powerSwitch","parameters":{"dataType":"ENUM","options":[{"name":"on","value":1},{"name":"off","value":0}]}},
  {"type":"devices.capabilities.range","instance":"brightness","parameters":{"dataType":"INTEGER","range":{"min":1,"max":100,"precision":1}}}]}]}
```

The `device` field is an opaque ID, not a network MAC. For some models it is a superset of the BLE MAC (govee2mqtt `docs/FAQ.md`).

**Capability types** (each is `devices.capabilities.<x>`): `on_off`, `toggle`, `range`, `mode`, `color_setting`, `segment_color_setting`, `music_setting`, `dynamic_scene`, `work_mode`, `temperature_setting`, `online` (state only), `event` (push only), `diy_color_setting` (seen in the diy-scenes response).

Each capability's `parameters` holds one of three data types:

- `ENUM` with `options[{name, value}]`
- `INTEGER` with `range{min, max, precision}` (and optionally `unit`)
- `STRUCT` with `fields[{fieldName, dataType, ...}]`

**Rule:** build the UI from these schemas at runtime. Don't hard-code ranges or instance names per SKU. The docs say valid instances and values depend on the device.

### 1.2 Control: exact bodies [OFFICIAL unless marked]

The envelope is the same for every command:

```sh
curl -s -X POST https://openapi.api.govee.com/router/api/v1/device/control \
  -H "Govee-API-Key: $GOVEE_KEY" -H 'Content-Type: application/json' \
  -d '{"requestId":"<uuid>","payload":{"sku":"H605C","device":"AA:BB:CC:DD:EE:FF:00:11","capability":{ ... }}}'
```

| Goal | `capability` value |
|---|---|
| Power on or off | `{"type":"devices.capabilities.on_off","instance":"powerSwitch","value":1}` (0 = off) |
| Brightness | `{"type":"devices.capabilities.range","instance":"brightness","value":50}` (1–100, check the range) |
| RGB | `{"type":"devices.capabilities.color_setting","instance":"colorRgb","value":16711680}`, where value = R×65536 + G×256 + B, 0–16777215 |
| Color temperature | `{"type":"devices.capabilities.color_setting","instance":"colorTemperatureK","value":4000}` (2000–9000 in the example; the real range is per device) |
| Segment color | `{"type":"devices.capabilities.segment_color_setting","instance":"segmentedColorRgb","value":{"segment":[0,1,2],"rgb":255}}` |
| Segment brightness | `{"type":"devices.capabilities.segment_color_setting","instance":"segmentedBrightness","value":{"segment":[0,1,2],"brightness":50}}` |
| Dynamic scene | `{"type":"devices.capabilities.dynamic_scene","instance":"lightScene","value":{"paramId":4280,"id":3853}}`, using the option value from `/device/scenes` |
| DIY scene **[INFERRED]** | `{"type":"devices.capabilities.diy_color_setting","instance":"diyScene","value":8216930}`, using the integer from `/device/diy-scenes`. Govee gives no control example for this. |
| Music mode **[IMPL]** | `{"type":"devices.capabilities.music_setting","instance":"musicMode","value":{"musicMode":<enum>,"sensitivity":100,"autoColor":1}}`. Read the field names and enums from the device's STRUCT `fields`. Source: [govee2mqtt platform_api.rs#L334](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/platform_api.rs#L334). |
| Static scene (night light) | `{"type":"devices.capabilities.mode","instance":"nightlightScene","value":1}`. The official example uses H7131. **The options come inline from `/user/devices`**, not from `/device/scenes`. |
| Preset scene | `devices.capabilities.mode` / `presetScene`, documented only for aroma diffusers. Values are ENUM options from `/user/devices`. |
| HDMI source | `devices.capabilities.mode` / `hdmiSource`, values 1–4 (example: H6604) |
| Toggles | `{"type":"devices.capabilities.toggle","instance":"<x>","value":0\|1}`. Documented instances include `gradientToggle`, `dreamViewToggle`, `nightlightToggle`, `mainLightToggle`, `backgroundLightToggle`, `leftLightToggle`, `rightLightToggle`, `pillarLightToggle`, `baseLightToggle`, `socketToggle1`/`2` and `oscillationToggle`. The only example body in the docs is `oscillationToggle`. |
| Snapshots | These appear at runtime as an extra instance under the device's `dynamic_scene` or `mode` capabilities. I did not confirm the instance name, so read it from `/user/devices`. |

Doc pitfalls:

- The docs type `value` as a String, but the examples use ints and objects. Follow the examples.
- One example writes `0x0000ff`, which is invalid JSON. Send decimal.
- The segment example uses indices 0–14. The real index range is in each device's STRUCT field `segment` (`elementRange`, `size`).

A 200 response does **not** confirm the light changed. Forum reports describe 200 responses where the bulb did nothing, and govee2mqtt's FAQ describes model-specific segment quirks. After a control, wait at least 1 second, then re-read state or use LAN `devStatus`.

### 1.3 State

```sh
curl -s -X POST https://openapi.api.govee.com/router/api/v1/device/state \
  -H "Govee-API-Key: $GOVEE_KEY" -H 'Content-Type: application/json' \
  -d '{"requestId":"<uuid>","payload":{"sku":"H605C","device":"AA:BB:CC:DD:EE:FF:00:11"}}'
```

The response is `payload.capabilities[]` with a `state.value` for each capability.

- **`devices.capabilities.online` / `online`:** when this is `false`, every other value is historical and should not be shown as live.
- **Empty values:** a `""` value means the instance is not queryable.
- **Event capabilities:** these are never returned by the state endpoint.

### 1.4 Scenes

- **Dynamic scenes:** `POST /device/scenes` with the same body as state. It returns `dynamic_scene` / `lightScene` ENUM options `{name, value:{paramId, id}}`.
- **DIY scenes:** `POST /device/diy-scenes` returns `diy_color_setting` / `diyScene` options with integer values.

Known gap: govee2mqtt documents that the platform API sometimes returns an incomplete scene list. It patches the list from the undocumented catalog in §3.2 ([undoc_api.rs#L385](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/undoc_api.rs#L385), `synthesize_platform_api_scene_list`).

### 1.5 Push events: MQTT, not webhooks [OFFICIAL]

- **Broker:** `mqtts://mqtt.openapi.govee.com:8883`
- **Login:** the username and the password are both the API key.
- **Topic:** the docs say `GA/<api-key>`, but the docs' own sample subscribes to the bare key. **This needs a test on a real account.** Subscribe to `GA/<key>` first, and fall back to the bare key if that fails.

Example payload:

```json
{"sku":"H5127","device":"…","deviceName":"…","capabilities":[{"type":"devices.capabilities.event","instance":"bodyAppearedEvent","state":[{"name":"Presence","value":1}]}]}
```

Only `devices.capabilities.event` instances are pushed. The documented examples are `lackWaterEvent` (ice maker H7172, dehumidifier H7151) and `bodyAppearedEvent` (presence sensor H5127).

**Lights do not push state changes through the official API.** Govee has no webhook product.

### 1.6 Auth and key provisioning [OFFICIAL]

- To get a key: in the Govee Home app, go to **Settings → Apply for API Key** and submit the form. The official page doesn't say how the key is delivered; community reports say email. **[INFERRED]** There appear to be no OAuth or per-app scopes, so one key gives full control of every device on the account.
- **Since 2026-05-15, generating a new key immediately disables the account's older keys.** If the user already runs Home Assistant or Homebridge on a key, generating a new one for this app breaks those integrations.
- **App behavior:**
  - Let the user paste an *existing* key.
  - Store it in the Keychain.
  - Treat a sudden 401 as "the key was rotated elsewhere" and prompt the user to re-enter it.
  - Never log the key, because it is also the MQTT password.

---

## 2. LAN API: UDP JSON [IMPL, all four implementations agree]

**Prerequisites:**

- The device must have Wi-Fi.
- **LAN Control** must be switched on in the Govee app, separately for each device. The toggle can take several minutes to appear (openHAB).
- Only SKUs on Govee's list support LAN control. The list is behind the WLAN guide. govee-local-api keeps its own copy in `SUPPORTED_DEVICES.md`.

| Traffic | Destination |
|---|---|
| Discovery (client → devices) | multicast `239.255.255.250:4001` |
| Replies (device → client) | the sender's IP, **always to UDP port 4002**, not to the sender's source port |
| Commands (client → device) | `<device-ip>:4003` |

Every message has the same envelope: `{"msg":{"cmd":"<name>","data":{...}}}`, sent as UTF-8 JSON with one message per datagram.

| cmd | data sent | reply |
|---|---|---|
| `scan` | `{"account_topic":"reserve"}` | `{"ip","device","sku","bleVersionHard","bleVersionSoft","wifiVersionHard","wifiVersionSoft"}` |
| `devStatus` | `{}` | `{"onOff":0\|1,"brightness":0-100,"color":{"r","g","b"},"colorTemInKelvin":N}` |
| `turn` | `{"value":0\|1}` | none |
| `brightness` | `{"value":0-100}` | none |
| `colorwc` | `{"color":{"r":255,"g":0,"b":0},"colorTemInKelvin":0}`. For white: rgb 0,0,0 and a Kelvin value in the device's range (default 2000–9000). | none |
| `ptReal` | `{"command":["<base64 BLE packet>", ...]}` | none. This wraps the 20-byte BLE packets from §4. **[UNDOC]** |
| `razer` | `{"pt":"<base64>"}` | none. DreamView streaming, §2.2. **[UNDOC]** |

Sources: [govee-local-api message.py#L37-L151](https://github.com/Galorhallen/govee-local-api/blob/413fb740feda579d04f92405a618ab08e6a85eae/src/govee_local_api/message.py#L37-L151) (ports in [controller.py#L42-L45](https://github.com/Galorhallen/govee-local-api/blob/413fb740feda579d04f92405a618ab08e6a85eae/src/govee_local_api/controller.py#L42-L45)), [govee2mqtt lan_api.rs#L174-L214](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/lan_api.rs#L174-L214) and [#L304-L308](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/lan_api.rs#L304-L308), and [OpenRGB GoveeController.cpp](https://gitlab.com/CalcProgrammer1/OpenRGB/-/blob/6a10f77c15e4be47c792b89f1a3cc4e992389684/Controllers/GoveeController/GoveeController.cpp).

Test commands (do not run against the user's lights without asking):

```sh
echo -n '{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}' | nc -u -w1 239.255.255.250 4001   # listen on 4002 separately
echo -n '{"msg":{"cmd":"devStatus","data":{}}}' | nc -u -w1 192.168.1.50 4003                                    # the reply also goes to port 4002
```

The LAN API has no authentication. Anyone on the LAN can control these devices. It is also not rate-limited by the cloud.

### 2.1 ptReal: segments and scenes over LAN [UNDOC]

Every packet is 20 bytes: 19 bytes of content, zero-padded, plus an XOR of the 19 bytes.

| Example | Hex and JSON |
|---|---|
| Power on | `3301010000000000000000000000000000000033`. This matches the egold H6061 test vector. |
| Segment 1 red (govee-local-api layout: `33 05 15 01 RR GG BB`, 5 zero bytes, then a 2-byte LE segment bitmask at offset 12) | hex `33051501ff0000000000000001000000000000dc`, sent as `{"msg":{"cmd":"ptReal","data":{"command":["MwUVAf8AAAAAAAAAAQAAAAAAANw="]}}}` |
| Built-in scene code 0x00 "sunrise" (`33 05 04 <code>`) | `{"msg":{"cmd":"ptReal","data":{"command":["MwUEAAAAAAAAAAAAAAAAAAAAADI="]}}}` |

**The segment layout depends on the SKU.** The egold H6061 vectors put the mask at offsets 9–10 (`33051501ff0000000001…dc`), not offset 12. Prefer the cloud `segmentedColorRgb` command. Use ptReal segments only for SKUs you have verified.

**Full catalog scenes over LAN** (the method govee2mqtt uses: [ble.rs#L377-L415](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/ble.rs#L377-L415) `SetSceneCode::encode`, and [lan_api.rs#L263](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/lan_api.rs#L263)):

1. Get `sceneCode` and `scenceParam` (sic) from the §3.2 catalog.
2. Base64-decode `scenceParam`.
3. Split it into `a3`-prefixed multi-line packets. The first line starts `a3 00 01 <lineCount> 02`. Later lines are `a3 <n>`, and the last line uses `a3 ff`. Each line is padded to 19 bytes plus the XOR byte.
4. Append the packet `33 05 04 <code_lo> <code_hi>`.
5. Send all of it in one `ptReal` command array.

The hard-coded `SCENE_CODES` table in govee-local-api ([light_capabilities.py#L117](https://github.com/Galorhallen/govee-local-api/blob/413fb740feda579d04f92405a618ab08e6a85eae/src/govee_local_api/light_capabilities.py#L117)) only fits some SKUs.

### 2.2 DreamView / Razer streaming [UNDOC]

| Packet | Bytes | JSON |
|---|---|---|
| Enable | `BB 00 01 B1 01 0A` | `{"msg":{"cmd":"razer","data":{"pt":"uwABsQEK"}}}` |
| Disable | `BB 00 01 B1 00 0B` | |
| Frame | `BB <len_hi> <len_lo> B0 01 <count> (R G B)×count <xor>`, where len = 2 + 3×count | 2 pixels (red, blue) = `uwAIsAEC/wAAAAD/AA==` |

Source: [OpenRGB GoveeController.cpp#L190-272](https://gitlab.com/CalcProgrammer1/OpenRGB/-/blob/6a10f77c15e4be47c792b89f1a3cc4e992389684/Controllers/GoveeController/GoveeController.cpp#L190-272).

- If no frame arrives for about 1 minute, the device drops back to its own effect, so stream continuously or send keep-alive frames.
- Only DreamView/Razer-capable SKUs support this.
- This is the only route to real per-LED real-time color. It is **not** a general replacement for segment control.

---

## 3. Undocumented Govee app cloud [UNDOC, optional, ship off by default]

### 3.1 Real-time light state push (AWS IoT)

govee2mqtt's flow ([undoc_api.rs#L157-L235](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/undoc_api.rs#L157-L235), [iot.rs#L230-L300](https://github.com/wez/govee2mqtt/blob/6f5a8449ca63da8bdc7cc696288a993681ff2a69/src/service/iot.rs#L230-L300)):

1. `POST https://app2.govee.com/account/rest/account/v1/login` with the account's **email and password**. It sends the headers `appVersion` (`6.5.02` in the code), `clientId` (a UUIDv5 of the email), `clientType: 1` and `iotVersion: 0`.
2. `GET https://app2.govee.com/app/v1/account/iot/key` with `Authorization: Bearer <token>`. This returns a client certificate, a private key and an AWS IoT endpoint.
3. Connect with MQTT over TLS to `<endpoint>:8883`.
4. Subscribe to the account topic from the login response. Device status messages arrive there.

This is the only push path for **light** state. The risks:

- The app holds the user's password, not just an API key.
- It is outside Govee's documented developer terms.
- It breaks whenever the app version, login or certificate flow changes.
- An `appVersion` the server rejects fails without a useful error.

### 3.2 Scene catalog

`GET https://app2.govee.com/appsku/v1/light-effect-libraries?sku=<SKU>` needs **no auth** (it sends only `AppVersion` and `User-Agent`). It returns categories, then scenes, then `lightEffects[]` with `sceneCode`, `scenceParam` and `scenceParamId`. govee2mqtt caches it for 1 day (soft TTL) and 1 week (hard TTL).

Other undocumented endpoints seen: `app2.govee.com/device/rest/devices/v1/list`, `community-api.govee.com/os/v1/login` and `app2.govee.com/bff-app/v1/exec-plat/home` (Tap-to-Run shortcuts).

---

## 4. BLE [IMPL / UNDOC]

| Item | Value |
|---|---|
| Service | egold gives no service UUID. Discover all services, then match the 2b11/2b10 characteristics. Scanning by service UUID needs a UUID verified on the user's device. |
| Write characteristic | `00010203-0405-0607-0809-0a0b0c0d2b11` ([egold H6061/utils.py#L4](https://github.com/egold555/Govee-Reverse-Engineering/blob/900b003174f5ecd6708b3d5266ea0514926aefa1/Products/H6061/utils.py#L4), write without response) |
| Notify characteristic | `00010203-0405-0607-0809-0a0b0c0d2b10` |
| Packet format | 20 bytes = 19 content bytes plus an XOR checksum. Byte 0 is `0x33` (command), `0xaa` (keep-alive or status reply) or `0xa1`/`0xa3` (DIY or multi-line data). |
| Power | `33 01 <00\|01>` |
| Brightness | `33 04 <level>` |
| Color mode | `33 05 <mode>`: `02` manual, `01` music, `04` scene, `0a` DIY |
| Segment color | `33 05 15 01 RR GG BB …mask` |
| Segment brightness | `33 05 15 02 …` |

- The H6127 page notes that **brightness scales differ by model**: some use 0–100, others use about 0x14–0xFE. Calibrate per SKU.
- The keep-alive is an `0xaa`-prefixed packet, but egold does not give its exact bytes. Capture them from a real session before shipping. Don't guess.
- A DIY upload is a sequence: keep-alive, start-data packet, 1–3 data packets, end packet, then the DIY-mode command ([H6127.md#L174](https://github.com/egold555/Govee-Reverse-Engineering/blob/900b003174f5ecd6708b3d5266ea0514926aefa1/Products/H6127.md#L174)).

**BLE-only devices** have no Wi-Fi:

- They are invisible to both the cloud API and the LAN API. The cloud returns "devices not belong you" for them (govee2mqtt FAQ).
- BLE is the only way to control them, and only within radio range of the Mac.
- Some models need a pairing or auth handshake first, per SKU (egold `H5080/pair.py`).

**macOS constraint:** CoreBluetooth does not expose MAC addresses, only a per-host UUID. You cannot join a cloud `device` ID to a BLE peripheral by MAC. Match on the advertised local name (community-reported patterns such as `ihoment_H6127_XXXX` / `Govee_H6xxx_XXXX`, MAC tail; **unverified here**) and on manufacturer data, then ask the user to confirm the match.

---

## 5. Truthful full-control gaps

| Feature | Cloud OpenAPI | LAN | BLE |
|---|---|---|---|
| Power, brightness, RGB, Kelvin | ✅ | ✅ | ✅ (per-SKU quirks) |
| Read state | ✅ (poll, 30/min/device) | ✅ `devStatus` (power, brightness, color, Kelvin only) | partial (notify replies) |
| Segments | ✅ where the capability is advertised | ptReal, SKU-specific [UNDOC] | ✅ SKU-specific |
| Catalog scenes | ✅ (list can be incomplete) | ptReal plus catalog [UNDOC] | ✅ same packets |
| DIY scenes | apply only, by ID [INFERRED body] | no | upload sequence [UNDOC] |
| *Creating or editing* DIY scenes | ❌ | ❌ | reverse-engineered, fragile |
| Static/night-light scenes | apply advertised options | not in basic protocol | SKU-specific [UNDOC] |
| Preset scenes | when advertised | not in basic protocol | SKU-specific [UNDOC] |
| HDMI source | when advertised | not in basic protocol | not established |
| Model-specific toggles | when advertised | basic power only | SKU-specific [UNDOC] |
| Snapshots | apply, if advertised | ❌ | ❌ |
| Music mode | select mode and sensitivity. The device's own mic does the sound-reactive work. | ❌ | `33 05 01` |
| Mac-audio-reactive / screen sync (DreamView) | on/off only (`dreamViewToggle`, where advertised); no streaming | `razer` streaming on capable SKUs [UNDOC] | ❌ |
| Video effects / DreamView camera modes | ❌ beyond the toggle (govee2mqtt FAQ: the API "doesn't support returning video effects") | ❌ | ❌ |
| Tap-to-Run, automations, schedules, groups | ❌ (undocumented bff endpoint only) | ❌ | ❌ |
| Push of light state changes | ❌ | ❌ | notify, only while connected |
| Push of sensor/appliance events | ✅ MQTT | ❌ | ❌ |
| Segment power off | ❌ (only color and brightness) | ❌ | ❌ |
| Inbound webhooks | ❌ Govee has none | | |

**"Webhooks" therefore means the app builds them.**

- *Outbound*: the app turns MQTT events, poll deltas and LAN `devStatus` deltas into POSTs to a URL the user configures.
- *Inbound*: the app runs a local HTTP listener that maps requests to commands. It must be authenticated with a token the app generates and bound to localhost or the LAN by explicit choice.

Remote inbound webhooks need a tunnel or relay. The app should not open router ports.

---

## 6. Implementation guidance (macOS)

1. **Transport order for each device:** use LAN when the device answered a `scan`, fall back to the cloud, and use BLE only for BLE-only devices. Routing through LAN avoids the cloud's 2/s per-device control cap and its 30/min state cap. Use the cloud for capability schemas, scene lists and features LAN lacks, such as segments and DIY.
2. **Rate limiting:** run a token bucket per device and one per account, matching §1. Coalesce slider drags so only the last value is sent, at no more than 2/s per device. On a 429, back off exponentially. Cache `/user/devices` and the scene lists, since govee2mqtt treats them as slow-changing.
3. **State polling:** poll LAN `devStatus` every 2–5 s (openHAB defaults to 5 s). Poll cloud state no more often than every 2–3 s per device, and only while that device is visible in the UI. Show the `online=false` state as offline or stale.
4. **Networking, using Network.framework or BSD sockets:**
   - Bind UDP **4002** with `SO_REUSEADDR`/`SO_REUSEPORT`. Expect a conflict if Home Assistant, govee2mqtt or another Govee tool runs on the same Mac, because only one of them receives the replies.
   - Send discovery to the multicast group, and also offer **broadcast** and **unicast-to-static-IP** fallbacks. Many routers drop Wi-Fi to LAN multicast (govee2mqtt `docs/LAN.md`).
   - Drop non-JSON datagrams on 4002 without reporting an error, because SSDP and mDNS noise lands there too.
5. **macOS entitlements and Info.plist:**
   - `NSLocalNetworkUsageDescription` (Local Network privacy prompt).
   - Sandbox: `com.apple.security.network.client` and `com.apple.security.network.server` (needed to bind 4002).
   - `com.apple.security.device.bluetooth` and `NSBluetoothAlwaysUsageDescription`.
   - **Unverified:** whether macOS, like iOS, needs the `com.apple.developer.networking.multicast` entitlement for `NWConnectionGroup` multicast. Test early. Plain BSD UDP sockets are the fallback.
6. **Secrets:** keep the API key, and any optional account password for §3.1, in the Keychain. Never write either to logs or exported diagnostics. Keep the §3.1 path behind an explicit "experimental" switch that is off by default, with its own consent text.
7. **Model the UI on capabilities:** render controls from capability schemas (`ENUM` → picker, `INTEGER` → slider bounded by min/max/precision, `STRUCT` → grouped fields). LAN-only capabilities come from a small per-SKU table, such as govee-local-api's `SUPPORTED_DEVICES.md`/`light_capabilities.py`, marked "verified on device" or not.
8. **Verify writes:** after each control, re-read state (LAN `devStatus` or the cloud) and show a mismatch instead of trusting the 200 response.

## 7. Risks

- **The OpenAPI is beta.** Instance names and doc examples contain errors (`teargetTemperature`, `temperature_range` vs `temperature_setting`, a `0x0000ff` literal).
- **Key rotation:** a new key disables the old ones, so this app and the user's other integrations break each other.
- **The MQTT topic is ambiguous** (`GA/<key>` vs the bare key).
- **Undocumented paths** (`ptReal`, `razer`, `app2.govee.com`) can break with any firmware or app update and may be outside Govee's developer terms. Ship them as best-effort with feature flags.
- **Per-SKU packet layouts** (segment mask offset, brightness scale): a wrong layout can send a malformed packet. That has no lasting effect, but it gives silent wrong behavior. Gate each layout on a verified-SKU list.
- **LAN has no authentication.** The app's inbound webhook listener must not become an open relay to it.
- **Cannot verify here:** the user's actual SKUs, LAN eligibility, MQTT topic behavior, and BLE keep-alive bytes. All of these need a supervised test on the user's devices. Begin with read-only `scan`/`devStatus` and cloud `GET /user/devices`.

## Connected-home follow-up

After this research, live capability enumeration showed that H66A0 advertises a STRUCT `movieMode` capability. This qualifies the broad video-mode gap above: advertised movie controls are exposed by the app, while complete camera/DreamView parity and streaming remain unverified. A supported test light also returned dynamic scene options. See `VERIFICATION.md` for observed cloud-control readback and LAN-discovery limits. Account-specific inventory is excluded from these public notes. No private app binary was analyzed.

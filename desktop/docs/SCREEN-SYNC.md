# Screen Sync

Screen Sync maps colors from a user-selected monitor or window to whole compatible LAN lights. This MVP uses documented Govee UDP RGB commands, not private Govee Desktop APIs or per-LED streaming.

## Privacy and capture boundary

Capture is an explicit action: choose a source, choose lights and regions, then Start. Capture must never start at launch or resume automatically after interruption. Stop releases capture; Pause disables video delivery and suspends frame processing/light updates while retaining the capture session until Stop; the UI must show whether capture is active. Pixels are processed locally, without AI vision, audio, frame recording, screenshot files, uploads or pixel logs. Only derived RGB values cross into the LAN sender. Source enumeration uses names/IDs without thumbnails.

Demo uses generated synthetic frames and fake lights. It must not call desktop source enumeration or getDisplayMedia, request capture permissions, bind transport sockets, or persist user edits. All development verification on this Mac uses this synthetic path.

## Scope and platform choices

The processing core is platform-neutral: sampling, black-border trimming, region mapping, smoothing and a bounded latest-only stream queue. Desktop capture is a separate adapter. This Electron app enables production capture adapters on Windows and Linux. The native Mac app at the repository root uses the same math (`Sources/LumaCore/ScreenSync.swift` mirrors `src/shared/sync-math.ts`); change both together.

- **Windows:** Electron desktopCapturer and getDisplayMedia for a selected monitor or window, behind a trusted-frame, video-only grant. Native Windows capture and real light latency need Windows runtime QA.
- **Mac:** the native app uses ScreenCaptureKit; see [MACOS.md](../../MACOS.md#screen-sync).
- **Linux:** implemented adapter and portable x64/arm64 tar builds. X11 revalidates selected sources at Start; Wayland/PipeWire uses the portal-selected source without opening a second picker. Portal/compositor capture remains experimental until real desktop QA. See [Linux build and runtime instructions](LINUX.md).

Cloud-only lights are unsupported in this mode. There is no rapid cloud fallback and no cloud readback for each frame. Per-LED/segment streaming is a separate experimental, model-specific effort requiring protocol and hardware verification. A reverse-engineered DreamView/Razer implementation documented elsewhere is not evidence of verified support in this app. No Govee Desktop binary was supplied or analyzed for this feature.

## Regions and sampling

The worker reduces each 96×54 frame (bars cropped) to a grid of at most 30×18 cells of linear-light sums, and only that grid crosses IPC; the main process validates it and computes each light's region color with the current settings. Regions: whole picture; left/right/top/bottom thirds; left/right/top/bottom edges; four corners; and eight half edges. **Edge depth** (5–33%, default 15%) sets how deep edges, corners and half edges reach and moves in one-cell steps. **Vivid** (off by default) weights each pixel by 0.05 + chroma², so colorful content outweighs gray UI and text; colorless pictures keep their average. Region names match the native Mac app.

## Tuning defaults

| Setting | Previous default | Default | Previous max | Max |
| --- | --- | --- | --- | --- |
| Frame sampling | ~8 fps (125 ms) | ~30 fps (33 ms) | 15 fps request | 30 fps request |
| Smoothing | 0.6 per frame | 0.4 per 100 ms, eases off on large jumps | 0.95 | 0.95 |
| Change threshold | 3% | 2% | 20% | 20% |
| Update rate per light | 2/s | 5/s | 5/s | 10/s |
| Edge depth | — | 15% | — | 33% (min 5%) |
| Vivid | — | off | — | — |

Smoothing is normalized to elapsed time, so the same setting feels the same at any frame rate. A jump of a quarter of the sRGB range on any channel skips smoothing. The main process accepts at most 60 frames per second from the renderer. The sender sends one field per interval, latest only, without retries, so 10/s is at most 10 small UDP datagrams per second per light. Saved settings keep their values. Desktop has no latency instrumentation yet.

## Color and performance limits

Output is an SDR color approximation. HDR capture and tone mapping vary with Windows/Chromium, display and content; the MVP does not claim HDR fidelity. Region previews describe requested stream colors, not confirmed light telemetry. A successful UDP send does not confirm hardware application. Neither frame rate nor end-to-end light latency is promised; measure them on each supported Windows/model combination.

## Sources checked 2026-10-16

- [Electron desktopCapturer](https://www.electronjs.org/docs/latest/api/desktop-capturer): source enumeration and capture integration; monitor/window IDs must be selected rather than using an automatic first source. The sample's audio option is not used by Luma.
- [Electron Session](https://www.electronjs.org/docs/latest/api/session#setdisplaymediarequesthandlerhandler-opts): trusted request frame, video/audio flags, user gesture and capture grant handler. Installed Electron 44.8.0 type declarations were checked against these APIs.
- [Microsoft screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture): explicit capture selection, lifecycle and HDR-to-SDR considerations. This is native API context, not an API Luma calls directly.
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit): the native Mac capture API; native Mac implementation is separate from this shared Windows/Linux app.

## Verification and Windows gate

Final implementation behavior, automated coverage and actual test results are recorded in [VERIFICATION.md](VERIFICATION.md). Windows capture permissions, source disappearance, protected content, lock/sleep, monitor changes, HDR, capture-border behavior, LAN model support and measured latency require a Windows operator. No actual screen capture, recording permission change, Keychain access or real-light control is performed during Mac development.

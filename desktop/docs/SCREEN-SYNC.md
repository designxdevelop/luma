# Screen Sync

Screen Sync maps colors from a user-selected monitor or window to whole compatible LAN lights. This MVP uses documented Govee UDP RGB commands, not private Govee Desktop APIs or per-LED streaming.

## Privacy and capture boundary

Capture is an explicit action: choose a source, choose lights and regions, then Start. Capture must never start at launch or resume automatically after interruption. Stop releases capture; Pause disables video delivery and suspends frame processing/light updates while retaining the capture session until Stop; the UI must show whether capture is active. Pixels are processed locally, without AI vision, audio, frame recording, screenshot files, uploads or pixel logs. Only derived RGB values cross into the LAN sender. Source enumeration uses names/IDs without thumbnails.

Demo uses generated synthetic frames and fake lights. It must not call desktop source enumeration or getDisplayMedia, request capture permissions, bind transport sockets, or persist user edits. All development verification on this Mac uses this synthetic path.

## Scope and platform choices

The processing core is platform-neutral: sampling, black-border trimming, region mapping, smoothing and a bounded latest-only stream queue. Desktop capture is a separate adapter. This shared Electron candidate enables production capture adapters on Windows and Linux; the native Mac app is being developed separately.

- **Windows:** Electron desktopCapturer and getDisplayMedia for a selected monitor or window, behind a trusted-frame, video-only grant. Native Windows capture and real light latency need Windows runtime QA.
- **Mac:** native capture, consent and lifecycle work is being implemented in parallel by a separate agent using ScreenCaptureKit; this shared Electron workspace does not edit the native Mac app.
- **Linux:** implemented adapter and portable x64/arm64 tar builds. X11 revalidates selected sources at Start; Wayland/PipeWire uses the portal-selected source without opening a second picker. Portal/compositor capture remains experimental until real desktop QA. See [Linux build and runtime instructions](LINUX.md).

Cloud-only lights are unsupported in this mode. There is no rapid cloud fallback and no cloud readback for each frame. Per-LED/segment streaming is a separate experimental, model-specific effort requiring protocol and hardware verification. A reverse-engineered DreamView/Razer implementation documented elsewhere is not evidence of verified support in this app. No Govee Desktop binary was supplied or analyzed for this feature.

## Color and performance limits

Output is an SDR color approximation. HDR capture and tone mapping vary with Windows/Chromium, display and content; the MVP does not claim HDR fidelity. Region previews describe requested stream colors, not confirmed light telemetry. A successful UDP send does not confirm hardware application. Neither frame rate nor end-to-end light latency is promised; measure them on each supported Windows/model combination.

## Sources checked 2026-10-16

- [Electron desktopCapturer](https://www.electronjs.org/docs/latest/api/desktop-capturer): source enumeration and capture integration; monitor/window IDs must be selected rather than using an automatic first source. The sample's audio option is not used by Luma.
- [Electron Session](https://www.electronjs.org/docs/latest/api/session#setdisplaymediarequesthandlerhandler-opts): trusted request frame, video/audio flags, user gesture and capture grant handler. Installed Electron 44.8.0 type declarations were checked against these APIs.
- [Microsoft screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture): explicit capture selection, lifecycle and HDR-to-SDR considerations. This is native API context, not an API Luma calls directly.
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit): the native Mac capture API; native Mac implementation is separate from this shared Windows/Linux app.

## Verification and Windows gate

Final implementation behavior, automated coverage and actual test results are recorded in [VERIFICATION.md](VERIFICATION.md). Windows capture permissions, source disappearance, protected content, lock/sleep, monitor changes, HDR, capture-border behavior, LAN model support and measured latency require a Windows operator. No actual screen capture, recording permission change, Keychain access or real-light control is performed during Mac development.

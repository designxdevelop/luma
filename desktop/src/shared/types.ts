// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Type-only contracts shared by the main process, core, preload and renderer.
// This file must stay free of runtime code: it is compiled by both tsconfigs.

export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

/** A capability as advertised by Govee's /user/devices or scene endpoints. */
export interface Capability {
  type: string;
  instance: string;
  parameters?: JSONValue;
}

export interface CapabilityCommand {
  type: string;
  instance: string;
  value: JSONValue;
}

/** Confirmed (reported) device state. Never contains optimistic pending values. */
export interface LightDevice {
  id: string;
  sku: string;
  /** Display name: the user's `customName` when set, else the device's own. */
  name: string;
  /** User-set label that survives cloud refreshes (matches the native app's `customName`). */
  customName?: string;
  /** Govee's device type (e.g. devices.types.heater). Undefined or devices.types.light means a light. */
  deviceType?: string;
  room: string;
  ip?: string;
  capabilities: Capability[];
  power?: boolean;
  brightness?: number;
  rgb?: number;
  /** 0 means the light is in RGB mode. */
  colorTemperature?: number;
  /** Colors Luma last sent beyond the single reported one (painted segments, a known scene), in strip order. Display only. */
  palette?: number[];
  online?: boolean;
  /** Last reported cloud `dreamViewToggle` (1 = DreamView sync running). Never persisted. */
  dreamView?: boolean;
  /** Epoch milliseconds. */
  lastSeen?: number;
  isDemo?: boolean;
}

/** One reported value that has no dedicated control (sensor readings, appliance modes). In memory only. */
export interface DeviceReading {
  instance: string;
  label: string;
  /** Display text: number with its advertised unit, an option name, or compact JSON. */
  text: string;
  /** Epoch milliseconds when Luma read it. */
  readAt: number;
}

export interface SceneStep {
  id: string;
  deviceID: string;
  command: CapabilityCommand;
  delayMilliseconds: number;
}

export interface LightScene {
  id: string;
  name: string;
  /** One of SCENE_ICONS in the renderer. */
  icon: string;
  steps: SceneStep[];
}

export interface SceneSchedule {
  id: string;
  sceneID: string;
  hour: number;
  minute: number;
  /** 1 = Sunday … 7 = Saturday (matches the Mac app). */
  weekdays: number[];
  enabled: boolean;
  /** Epoch ms. Runs before this instant are skipped (Pause); shared through schedule sync. */
  pausedUntil?: number;
  lastRunMinute?: string;
}

export type RunStatus = 'running' | 'completed' | 'failed' | 'cancelled';

export interface AutomationRun {
  id: string;
  sceneID: string;
  name: string;
  status: RunStatus;
  /** Epoch milliseconds. */
  startedAt: number;
  finishedAt?: number;
  error?: string;
}

/** Persisted home data. Secrets are stored separately and never appear here. */
export interface SavedHome {
  version: 1;
  devices: LightDevice[];
  scenes: LightScene[];
  schedules: SceneSchedule[];
  webhookPort: number;
  allowLAN: boolean;
  appearance?: 'system' | 'light' | 'dark';
  syncSettings?: SyncSettings;
  syncAssignments?: SyncAssignment[];
  /** Native DreamView partner drafts, kept only so a backup round trip through Windows/Linux doesn't lose them. Never sent. */
  dreamViewDrafts?: Record<string, DreamViewDraft>;
}

/** Matches the native DreamViewDraft: member light IDs with screen areas 1…10. */
export interface DreamViewDraft { members: Array<{ deviceID: string; areas: number[] }> }

/** Matches the native FloorPlan (floor-plans/plans.json): x and y are 0…1 of the image itself. */
export interface FloorPlanPin { deviceID: string; x: number; y: number }
export interface FloorPlan { id: string; name: string; pins: FloorPlanPin[] }

export type ControlPhase = 'queued' | 'sending' | 'confirming';

export interface PendingView {
  instance: string;
  value: JSONValue;
  phase: ControlPhase;
}

export interface ActivityEntry {
  id: string;
  time: number;
  message: string;
  isError: boolean;
}

// ---------- Screen Sync ----------

/** Persisted values; they match the native Mac app's region names. */
export type SyncRegion =
  | 'full' | 'left' | 'right' | 'top' | 'bottom'
  | 'edgeLeft' | 'edgeRight' | 'edgeTop' | 'edgeBottom'
  | 'cornerTopLeft' | 'cornerTopRight' | 'cornerBottomLeft' | 'cornerBottomRight'
  | 'edgeLeftUpper' | 'edgeLeftLower' | 'edgeRightUpper' | 'edgeRightLower'
  | 'edgeTopLeft' | 'edgeTopRight' | 'edgeBottomLeft' | 'edgeBottomRight';

/**
 * A frame reduced to at most 30×18 cells over the cropped picture. Each cell is 8 numbers:
 * pixel count, linear r/g/b sums, vivid weight sum, weight × linear r/g/b sums.
 */
export interface SyncGrid { columns: number; rows: number; cells: number[] }
export type SyncPhase = 'idle' | 'starting' | 'running' | 'paused' | 'stopping';

export interface SyncSettings {
  /** 0 … 0.95, share of the old color kept per 100 ms; eases off on large jumps. */
  smoothing: number;
  /** 0.005 … 0.2, minimum change (share of range) worth sending. */
  threshold: number;
  /** 1 … 100 %. */
  brightnessCap: number;
  /** 0.5 … 10 updates per second per light (LAN cap). */
  updateHz: number;
  /** 0.05 … 0.33, how deep edges, corners and half edges reach into the picture. */
  edgeDepth: number;
  /** Weight colorful pixels over gray/white ones. */
  vivid: boolean;
  /** On an explicit Stop: restore last confirmed state (true) or leave lights as they are (false). */
  restore: boolean;
}

export interface SyncAssignment { id: string; region: SyncRegion; included: boolean }

export interface SyncSource { key: string; name: string; kind: 'screen' | 'window' }

/** The stream's latest requested values for a light (may still be waiting for its send slot). Never confirmed device state. */
export interface SyncLightView {
  id: string;
  name: string;
  region: SyncRegion;
  status: 'streaming' | 'excluded';
  requestedRGB?: number;
  requestedBrightness?: number;
}

export interface SyncView {
  phase: SyncPhase;
  /** Session generation; bumps on start and stop. */
  generation: number;
  sourceName?: string;
  /** Demo: synthetic frames only, never screen capture. */
  synthetic: boolean;
  /** Real capture is available (connected mode on Windows). */
  captureSupported: boolean;
  /** Screen or Audio Sync; meaningful while a session exists. */
  kind: SyncKind;
  audio: AudioOptions;
  audioSupport: AudioSupport;
  lights: SyncLightView[];
  eligibility: Array<{ id: string; name: string; eligible: boolean; reason?: string }>;
  settings: SyncSettings;
  stats: { frames: number; dropped: number; sent: number; errors: number; superseded: number };
  lastStop?: string;
}

export interface SyncGrant { token: string; generation: number; synthetic: boolean }

/** What a sync session follows: a captured screen/window, or captured computer audio. */
export type SyncKind = 'screen' | 'audio';
/** System audio = loopback of what the computer plays; input = the default recording device. */
export type AudioSource = 'system' | 'input';
export interface AudioOptions {
  /** pulse: all lights share one color and brightness; spectrum: lights spread bass → treble. */
  style: 'pulse' | 'spectrum';
  /** 0.5 … 2, gain applied after automatic level adjustment. */
  sensitivity: number;
}
export interface AudioSupport {
  /** Loopback capture of computer audio (Windows; attempted, unverified, on Linux). */
  system: boolean;
  systemExperimental: boolean;
  /** The default recording device (a microphone, line-in, or a routed monitor/loopback device). */
  input: boolean;
}
export interface AudioGrant { token: string; generation: number; source: AudioSource }

/** Everything the renderer needs to draw. Secrets are only ever masked here. */
export interface AppSnapshot {
  demo: boolean;
  platformSecretsAvailable: boolean;
  cloudConnected: boolean;
  hasSavedKey: boolean;
  scanning: boolean;
  busy: boolean;
  /** Reported devices with the latest-intent overlay already applied. */
  devices: LightDevice[];
  /** Pending intents keyed by device ID. */
  pending: Record<string, PendingView[]>;
  scenes: LightScene[];
  schedules: SceneSchedule[];
  runs: AutomationRun[];
  runningSceneID?: string;
  activity: ActivityEntry[];
  notice?: string;
  webhook: {
    running: boolean;
    status: string;
    fingerprint?: string;
    spkiPin?: string;
    port: number;
    allowLAN: boolean;
    /** e.g. "lm_…a1b2"; never the full token. */
    maskedToken?: string;
    available: boolean;
  };
  canSave: boolean;
  version: string;
  sync: SyncView;
  appearance: 'system' | 'light' | 'dark';
  syncAssignments: SyncAssignment[];
  /** Readings by device ID, from the last cloud state read. */
  readings: Record<string, DeviceReading[]>;
  /** Set while "Restore lights" can undo the last scene (name of the restore point). */
  restorePoint?: string;
  goveeHome: GoveeHomeView;
  scheduleSync: ScheduleSyncView;
  doorbell: DoorbellView;
  /** Local floor plans. Images are fetched separately (floorPlanImage); `imageVersion` changes when one is replaced. */
  floorPlans: Array<FloorPlan & { imageVersion: number }>;
  /** False when plans.json couldn't be read: the files are preserved and nothing is saved over them. */
  floorPlansWritable: boolean;
  dreamViewDrafts: Record<string, DreamViewDraft>;
  bluetooth: BluetoothView;
}

// ---------- Bluetooth lights ----------

export type BluetoothPhase = 'idle' | 'scanning' | 'connecting' | 'securing' | 'reading' | 'ready' | 'failed';
export interface BluetoothView {
  /** Web Bluetooth is available (connected mode, not demo). */
  supported: boolean;
  phase: BluetoothPhase;
  message?: string;
  nearby: Array<{ id: string; title: string; localName: string; account?: string; rssi?: number; note?: string; connectable: boolean }>;
  connected?: { id: string; title: string; encryption: string; limitation?: string; color: boolean; videoMode: boolean; dreamView: boolean; memberLimit: number };
  /** What the light reported this session; undefined = not read yet, so its control stays disabled. */
  readback: {
    power?: boolean; brightness?: number; firmware?: string; hardware?: string;
    video?: { movie: boolean; whole: boolean; saturation: number };
    groupEnabled?: boolean; groupArea?: number; groupContent?: number; groupSaturation?: number; memberSlots?: string;
  };
  capture?: { summary?: string; error?: string };
}
export type BluetoothAction =
  | { kind: 'power'; on: boolean } | { kind: 'brightness'; value: number } | { kind: 'color'; rgb: number }
  | { kind: 'video'; movie: boolean; whole: boolean; saturation: number }
  | { kind: 'groupEnabled'; on: boolean } | { kind: 'groupVideo'; whole: boolean; movie: boolean } | { kind: 'groupSaturation'; value: number };
export type BluetoothOp = 'scan' | 'scanEnded' | 'choose' | 'secure' | 'notify' | 'notifying' | 'closed' | 'send' | 'disconnect' | 'capture';

/** What one computer reported when it ran (or skipped) a shared schedule. Observed, not settings. */
export interface ScheduleRunReport { scheduleID: string; occurrence: string; at: number; status: string; detail?: string }

/** Schedule sync as the renderer shows it. Never contains a token except inside pairing codes. */
export interface ScheduleSyncView {
  available: boolean;
  role: 'off' | 'runner' | 'paired';
  deviceName: string;
  /** False when this computer must not run schedules (paired, handed off, or waiting for the old runner). */
  mayExecute: boolean;
  timeZone: string;
  notices: string[];
  runner?: {
    status: string; pairingCodes: string[]; keepAwake: boolean;
    clients: Array<{ id: string; name: string; platform: string; lastSeen: number }>;
    runs: ScheduleRunReport[]; retiredTo?: string; waitingFor?: string;
  };
  paired?: {
    host: string; runnerName: string; runnerPlatform?: string; runnerTimeZone?: string; runnerExecuting: boolean;
    lastSync?: number; lastError?: string; moved?: string; unsent: number; runs: ScheduleRunReport[];
  };
}

export interface DoorbellConfig {
  enabled: boolean;
  /** Room names, resolved to lights each time the bell rings. */
  rooms: string[];
  deviceIDs: string[];
  rgb: number;
  durationSeconds: number;
  /** One full bright-dim cycle; 2–6 s keeps the flash rate at or below 0.5 Hz. */
  pulseSeconds: number;
  brightnessCap: number;
  /** Minutes after local midnight; may cross midnight. */
  quietStart?: number;
  quietEnd?: number;
  /** 0 leaves the lights alone during quiet hours. */
  quietBrightnessCap: number;
  cooldownSeconds: number;
  /** HTTPS address of your own Alexa relay. Its token is in the secret store. */
  relayURL?: string;
}

/** Doorbell alert settings and state. The relay token itself never reaches the renderer. */
export interface DoorbellView {
  config: DoorbellConfig;
  phase: 'idle' | 'starting' | 'flashing' | 'restoring';
  status: string;
  relayState: string;
  relayTokenSaved: boolean;
  pairing?: { code: string; expiresAt: number };
}

// ---------- Govee Home account (read-only) ----------

export interface GoveeRoomChange { deviceID: string; name: string; currentRoom: string; goveeRoom: string }
export interface GoveeImportPlan { changes: GoveeRoomChange[]; unchanged: number; withoutRoom: number; notInLuma: number }
export interface GoveeHomeGroup { id: number; name: string; enabled: boolean; reportedLightCount?: number; mainDevice?: string; mainSKU?: string; isDreamView: boolean }
export interface GoveeAutomation { id: number; name: string; enabled: boolean; times: Array<{ hour: number; minute: number }>; repeatDays: number[]; targets: Array<{ sku: string; name: string; isDreamView: boolean }> }
export interface GoveeConflict { automation: string; scheduleID: string; light: string }
export interface GoveeHomeView {
  /** Connected mode with secure storage: sign-in is possible. */
  available: boolean;
  signedIn: boolean;
  /** Govee emailed a code; sign in again with it. */
  awaitingCode: boolean;
  busy: boolean;
  importedAt?: number;
  plan?: GoveeImportPlan;
  groups: GoveeHomeGroup[];
  automations: GoveeAutomation[];
  conflicts: GoveeConflict[];
  /** Account reads that failed without failing the room import. */
  unavailable: string[];
  /** Firmware version from the Govee Home device list, by Luma device ID. */
  firmware: Record<string, string>;
}

export interface BackupResult { scenes: number; schedules: number; lightsUpdated: number; lightsNotFound: number; scenesWithMissingLights: number }

/** Request kinds from renderer to main. Every handler validates its input. */
export type ScheduleSyncAction = 'runHere' | 'pair' | 'off' | 'syncNow' | 'takeOver' | 'forceTakeOver' | 'keepAwake' | 'rotate' | 'dismiss' | 'copyCode';
export interface LumaBridge {
  snapshot(): Promise<AppSnapshot>;
  scheduleSync(action: ScheduleSyncAction, arg?: unknown): Promise<void>;
  setAppearance(value: 'system' | 'light' | 'dark'): Promise<void>;
  setSyncAssignments(value: SyncAssignment[]): Promise<void>;
  clearActivity(): Promise<void>;
  copyDeviceID(id: string): Promise<void>;
  exploreDemo(): Promise<void>;
  onSnapshot(listener: (snapshot: AppSnapshot) => void): () => void;
  onNavigate(listener: (target: { deviceID?: string; tab?: string }) => void): () => void;
  /** Submits a control. `coalesce` is true for UI controls (sliders, toggles). */
  control(deviceID: string, command: CapabilityCommand): Promise<void>;
  refresh(deviceID: string): Promise<void>;
  connect(apiKey: string): Promise<void>;
  reconnect(): Promise<void>;
  disconnect(): Promise<void>;
  discover(): Promise<void>;
  loadEffects(deviceID: string, diy: boolean): Promise<void>;
  assignRoom(deviceID: string, room: string): Promise<void>;
  renameDevice(deviceID: string, name: string): Promise<void>;
  saveScene(scene: LightScene): Promise<void>;
  deleteScene(sceneID: string): Promise<void>;
  captureScene(name: string, icon: string, deviceIDs: string[]): Promise<LightScene>;
  validateSceneJSON(text: string): Promise<LightScene>;
  runScene(sceneID: string): Promise<string>;
  stopScene(): Promise<void>;
  saveSchedule(schedule: SceneSchedule): Promise<void>;
  deleteSchedule(scheduleID: string): Promise<void>;
  setWebhookConfig(port: number, allowLAN: boolean): Promise<void>;
  startWebhook(): Promise<void>;
  stopWebhook(): Promise<void>;
  rotateToken(): Promise<void>;
  /** Copies the full token to the clipboard in main; the renderer never receives it. */
  copyToken(): Promise<void>;
  copyFingerprint(): Promise<void>;
  copySpkiPin(): Promise<void>;
  exportCertificate(): Promise<void>;
  openExternal(url: 'repo' | 'issues' | 'apikey' | 'lan-guide'): Promise<void>;
  exportScene(sceneID: string): Promise<void>;
  importScene(): Promise<LightScene | undefined>;
  dismissNotice(): Promise<void>;
  /** Lists screens/windows on explicit request only (names, no thumbnails). Synthetic in demo. */
  syncSources(): Promise<SyncSource[]>;
  syncStart(sourceKey: string, lights: Array<{ id: string; region: SyncRegion }>): Promise<SyncGrant>;
  /** Region averages for one sampled frame; false when stale or rejected. */
  syncFrame(token: string, generation: number, seq: number, grid: SyncGrid): Promise<boolean>;
  syncPause(): Promise<void>;
  syncResume(token: string): Promise<void>;
  /** Explicit user Stop: applies the chosen leave/restore setting. */
  syncStop(): Promise<void>;
  /** Capture failed or ended in the renderer; stops without restoring. */
  syncEnded(token: string, reason: string): Promise<void>;
  syncSettings(settings: Partial<SyncSettings>): Promise<void>;
  /** Starts an Audio Sync session; call the audio pump right after it resolves (user activation). */
  audioStart(source: AudioSource, lights: Array<{ id: string }>, options: AudioOptions): Promise<AudioGrant>;
  /** One analysis frame: loudness and 8 band levels, all 0…1. */
  audioLevels(token: string, generation: number, seq: number, levels: { level: number; bands: number[] }): Promise<boolean>;
  audioOptions(options: Partial<AudioOptions>): Promise<void>;
  /** Room-wide brightness or white; each light is clamped to its own range. Lights only. */
  roomAction(room: string, action: { brightness?: number; kelvin?: number }): Promise<void>;
  /** Sends commands to one light in order, never coalesced (segment painter). */
  controlBatch(deviceID: string, commands: CapabilityCommand[]): Promise<void>;
  restoreBeforeScene(): Promise<void>;
  /** Doorbell alert: 'update' | 'test' | 'stop' | 'saveRelay' | 'forgetRelay' | 'pairingCode' | 'unlink'. */
  doorbell(action: string, arg?: unknown, arg2?: unknown): Promise<void>;
  /** Save dialog in main; the backup never contains keys, tokens, IPs or webhook settings. */
  exportBackup(): Promise<void>;
  /** Open dialog in main; undefined when cancelled. */
  importBackup(): Promise<BackupResult | undefined>;
  copyCompatibilityReport(): Promise<void>;
  /** Read-only Govee Home sign-in. The password is used once and never stored. */
  goveeSignIn(email: string, password: string, code?: string): Promise<'needsCode' | 'signedIn'>;
  goveeImport(): Promise<void>;
  goveeApplyRooms(deviceIDs: string[]): Promise<void>;
  goveeSignOut(): Promise<void>;
  /** Open dialog in main; the image is re-encoded as PNG (metadata such as GPS removed). Returns the new floor's ID, or undefined when cancelled. */
  floorPlanAdd(): Promise<string | undefined>;
  floorPlanReplace(id: string): Promise<void>;
  floorPlanRename(id: string, name: string): Promise<void>;
  floorPlanDelete(id: string): Promise<void>;
  floorPlanPlace(id: string, deviceID: string, x: number, y: number): Promise<void>;
  floorPlanRemovePin(id: string, deviceID: string): Promise<void>;
  /** PNG data URL, or undefined when the image can't be read. */
  floorPlanImage(id: string): Promise<string | undefined>;
  /** Local DreamView partner draft for a main light. Never sent to lights. */
  saveDreamViewDraft(lightID: string, draft: DreamViewDraft): Promise<void>;
  /** Bluetooth lights: the renderer carries GATT bytes; main runs the protocol. `secure` resolves false when nothing may be sent. */
  bluetooth(op: BluetoothOp, arg?: unknown): Promise<boolean | void>;
  /** Paced frames main wants written to the connected light (write without response). */
  onBluetoothWrite(listener: (frame: number[]) => void): () => void;
  onBluetoothDisconnect(listener: () => void): () => void;
}

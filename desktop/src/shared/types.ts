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
  name: string;
  room: string;
  ip?: string;
  capabilities: Capability[];
  power?: boolean;
  brightness?: number;
  rgb?: number;
  /** 0 means the light is in RGB mode. */
  colorTemperature?: number;
  online?: boolean;
  /** Epoch milliseconds. */
  lastSeen?: number;
  isDemo?: boolean;
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
}

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
  lights: SyncLightView[];
  eligibility: Array<{ id: string; name: string; eligible: boolean; reason?: string }>;
  settings: SyncSettings;
  stats: { frames: number; dropped: number; sent: number; errors: number; superseded: number };
  lastStop?: string;
}

export interface SyncGrant { token: string; generation: number; synthetic: boolean }

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
}

/** Request kinds from renderer to main. Every handler validates its input. */
export interface LumaBridge {
  snapshot(): Promise<AppSnapshot>;
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
}

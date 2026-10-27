// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Sandboxed preload: exposes a narrow, typed bridge. No Node APIs reach the renderer,
// and secrets never cross it (the token is copied to the clipboard in main).

import { contextBridge, ipcRenderer } from 'electron';
import type { AppSnapshot, LumaBridge } from '../shared/types';

const call = (channel: string) => (...args: unknown[]) => ipcRenderer.invoke(`luma:${channel}`, ...args);

const bridge: LumaBridge = {
  setAppearance: call('setAppearance') as LumaBridge['setAppearance'],
  setSyncAssignments: call('setSyncAssignments') as LumaBridge['setSyncAssignments'],
  clearActivity: call('clearActivity') as LumaBridge['clearActivity'],
  copyDeviceID: call('copyDeviceID') as LumaBridge['copyDeviceID'],
  exploreDemo: call('exploreDemo') as LumaBridge['exploreDemo'],
  snapshot: call('snapshot') as LumaBridge['snapshot'],
  onSnapshot(listener) {
    const handler = (_event: unknown, snapshot: AppSnapshot) => listener(snapshot);
    ipcRenderer.on('luma:snapshot-changed', handler);
    return () => { ipcRenderer.removeListener('luma:snapshot-changed', handler); };
  },
  onNavigate(listener) {
    const handler = (_event: unknown, target: { deviceID?: string; tab?: string }) => listener(target);
    ipcRenderer.on('luma:navigate', handler);
    return () => { ipcRenderer.removeListener('luma:navigate', handler); };
  },
  control: call('control') as LumaBridge['control'],
  refresh: call('refresh') as LumaBridge['refresh'],
  connect: call('connect') as LumaBridge['connect'],
  reconnect: call('reconnect') as LumaBridge['reconnect'],
  disconnect: call('disconnect') as LumaBridge['disconnect'],
  discover: call('discover') as LumaBridge['discover'],
  loadEffects: call('loadEffects') as LumaBridge['loadEffects'],
  assignRoom: call('assignRoom') as LumaBridge['assignRoom'],
  renameDevice: call('renameDevice') as LumaBridge['renameDevice'],
  saveScene: call('saveScene') as LumaBridge['saveScene'],
  deleteScene: call('deleteScene') as LumaBridge['deleteScene'],
  captureScene: call('captureScene') as LumaBridge['captureScene'],
  validateSceneJSON: call('validateSceneJSON') as LumaBridge['validateSceneJSON'],
  runScene: call('runScene') as LumaBridge['runScene'],
  stopScene: call('stopScene') as LumaBridge['stopScene'],
  saveSchedule: call('saveSchedule') as LumaBridge['saveSchedule'],
  deleteSchedule: call('deleteSchedule') as LumaBridge['deleteSchedule'],
  setWebhookConfig: call('setWebhookConfig') as LumaBridge['setWebhookConfig'],
  startWebhook: call('startWebhook') as LumaBridge['startWebhook'],
  stopWebhook: call('stopWebhook') as LumaBridge['stopWebhook'],
  rotateToken: call('rotateToken') as LumaBridge['rotateToken'],
  copyToken: call('copyToken') as LumaBridge['copyToken'],
  copyFingerprint: call('copyFingerprint') as LumaBridge['copyFingerprint'],
  exportCertificate: call('exportCertificate') as LumaBridge['exportCertificate'],
  openExternal: call('openExternal') as LumaBridge['openExternal'],
  exportScene: call('exportScene') as LumaBridge['exportScene'],
  importScene: call('importScene') as LumaBridge['importScene'],
  dismissNotice: call('dismissNotice') as LumaBridge['dismissNotice'],
  syncSources: call('syncSources') as LumaBridge['syncSources'],
  syncStart: call('syncStart') as LumaBridge['syncStart'],
  syncFrame: call('syncFrame') as LumaBridge['syncFrame'],
  syncPause: call('syncPause') as LumaBridge['syncPause'],
  syncResume: call('syncResume') as LumaBridge['syncResume'],
  syncStop: call('syncStop') as LumaBridge['syncStop'],
  syncEnded: call('syncEnded') as LumaBridge['syncEnded'],
  syncSettings: call('syncSettings') as LumaBridge['syncSettings'],
};

contextBridge.exposeInMainWorld('luma', bridge);

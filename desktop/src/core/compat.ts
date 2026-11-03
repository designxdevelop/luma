// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// A plain-text summary of what Luma can do with each model, for issue reports. Same
// rules as the native CompatibilityReport: models, capability names and data types,
// and connection paths only. Never device IDs, names, rooms, IP addresses or keys.

import type { LightDevice } from '../shared/types';
import { isObject } from './model';

/** Capabilities with their own controls in Luma for Windows/Linux; anything else uses the generic form. */
export const DEDICATED = new Set(['powerSwitch', 'brightness', 'colorRgb', 'colorTemperatureK', 'dreamViewToggle', 'lightScene', 'diyScene', 'snapshot', 'segmentedColorRgb', 'segmentedBrightness']);

/** DreamView member capacity per ha-govee-led-ble @ b845c59 services.yaml (same table as the native app). */
export const DREAMVIEW_MEMBER_LIMITS: Record<string, number> = { H6199: 5, H6097: 7, H6099: 7, H66A0: 10 };

export function compatibilityReport(devices: LightDevice[], app: string): string {
  const lines = ['Luma compatibility report', app, ''];
  const seen = new Set<string>();
  for (const d of [...devices].sort((a, b) => a.sku.localeCompare(b.sku))) {
    if (d.isDemo) continue;
    const caps = [...d.capabilities].sort((a, b) => a.instance.localeCompare(b.instance));
    const paths = [d.capabilities.length ? 'cloud' : undefined, d.ip ? 'LAN' : undefined].filter(Boolean);
    const entry = [`${d.sku} · ${paths.length ? paths.join(' + ') : 'no connection'}${d.deviceType && d.deviceType !== 'devices.types.light' ? ` · ${d.deviceType.replace('devices.types.', '')}` : ''}`];
    const own = caps.filter((c) => DEDICATED.has(c.instance)).map((c) => c.instance);
    const generic = caps.filter((c) => !DEDICATED.has(c.instance)).map((c) => {
      const type = isObject(c.parameters) && typeof c.parameters.dataType === 'string' ? c.parameters.dataType : '?';
      return `${c.instance} (${c.type.replace('devices.capabilities.', '')}, ${type})`;
    });
    if (own.length) entry.push(`  Luma controls: ${own.join(', ')}`);
    if (generic.length) entry.push(`  Generic form: ${generic.join(', ')}`);
    if (d.ip) entry.push('  LAN: power, brightness, color, white (Govee LAN API)');
    const limit = DREAMVIEW_MEMBER_LIMITS[d.sku.toUpperCase()];
    if (limit) entry.push(`  DreamView controller: up to ${limit} members (ha-govee-led-ble); membership isn't editable in Luma`);
    const key = entry.join('\n');
    if (seen.has(key)) continue; // identical models with identical features are listed once
    seen.add(key);
    lines.push(...entry, '');
  }
  if (seen.size === 0) lines.push('No lights.');
  return lines.join('\n');
}

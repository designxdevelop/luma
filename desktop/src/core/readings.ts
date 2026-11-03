// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Readable values from Govee's official device/state reply for capabilities that have
// no dedicated control: thermometer and hygrometer readings, appliance modes, filter
// life. Units come only from the advertised capability; nothing is converted or guessed.
// Event capabilities (e.g. lack of water) are pushed over MQTT and don't appear here.

import type { Capability, DeviceReading, JSONValue } from '../shared/types';
import { isObject, jsonEqual } from './model';

/** Shown by dedicated controls instead (or meaningless as a reading). */
const SKIP = new Set(['online', 'powerSwitch', 'brightness', 'colorRgb', 'colorTemperatureK', 'dreamViewToggle', 'lightScene', 'diyScene', 'snapshot']);
const LABELS: Record<string, string> = {
  sensorTemperature: 'Temperature', sensorHumidity: 'Humidity', airQuality: 'Air quality', filterLifeTime: 'Filter life',
  workMode: 'Mode', gearMode: 'Gear', fanSpeed: 'Fan speed', targetTemperature: 'Target temperature',
};
const UNITS: Record<string, string> = {
  'unit.percent': '%', 'unit.temperature.celsius': ' °C', 'unit.temperature.fahrenheit': ' °F', 'unit.kelvin': ' K',
};
const MAX_READINGS = 32;

export function readingLabel(instance: string): string {
  const words = instance.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase();
  return LABELS[instance] ?? words.charAt(0).toUpperCase() + words.slice(1);
}

function unitOf(parameters: JSONValue | undefined): string {
  const unit = isObject(parameters) && typeof parameters.unit === 'string' ? parameters.unit : undefined;
  if (!unit) return '';
  return UNITS[unit] ?? (/^unit\.[a-z.]{1,40}$/i.test(unit) ? ` ${unit.slice(5).replace(/\./g, ' ')}` : '');
}

function text(value: JSONValue, cap: Capability | undefined): string | undefined {
  const params = cap?.parameters;
  const options = isObject(params) && Array.isArray(params.options) ? params.options.filter(isObject) : [];
  const named = options.find((o) => jsonEqual(o.value, value));
  if (named && typeof named.name === 'string') return named.name.slice(0, 80);
  if (typeof value === 'number' && Number.isFinite(value)) return `${Math.round(value * 100) / 100}${unitOf(params)}`;
  if (typeof value === 'boolean') return value ? 'On' : 'Off';
  if (typeof value === 'string') return value.trim() === '' ? undefined : value.slice(0, 80);
  if (value === null) return undefined;
  const json = JSON.stringify(value);
  return json === '{}' || json === '[]' ? undefined : json.length > 120 ? `${json.slice(0, 119)}…` : json;
}

/** `reported` is payload.capabilities from device/state. Unknown or empty values are left out. */
export function parseReadings(reported: JSONValue[], capabilities: Capability[], now: number): DeviceReading[] {
  const out: DeviceReading[] = [];
  for (const row of reported) {
    if (!isObject(row) || typeof row.instance !== 'string' || row.instance.length > 64 || SKIP.has(row.instance)) continue;
    if (!isObject(row.state) || !('value' in row.state)) continue;
    const shown = text(row.state.value!, capabilities.find((c) => c.instance === row.instance));
    if (shown === undefined) continue;
    out.push({ instance: row.instance, label: readingLabel(row.instance), text: shown, readAt: now });
    if (out.length >= MAX_READINGS) break;
  }
  return out;
}

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Small pure helpers for the renderer: escaping, colors, icons, schema reading.

import type { Capability, CapabilityCommand, JSONValue, LightDevice, SceneSchedule } from '../shared/types';

export const esc = (value: unknown): string => String(value ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export const isObj = (v: unknown): v is { [k: string]: JSONValue } => typeof v === 'object' && v !== null && !Array.isArray(v);

export const hex = (n: number) => `#${(n & 0xffffff).toString(16).padStart(6, '0')}`;
export const fromHex = (h: string) => parseInt(h.replace('#', ''), 16);

/** Approximate color of white light at a Kelvin temperature (for orbs only). */
export function kelvinToHex(k: number): string {
  const t = k / 100;
  const r = t <= 66 ? 255 : 329.698727446 * Math.pow(t - 60, -0.1332047592);
  const g = t <= 66 ? 99.4708025861 * Math.log(t) - 161.1195681661 : 288.1221695283 * Math.pow(t - 60, -0.0755148492);
  const b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * Math.log(t - 10) - 305.0447927307;
  const c = (v: number) => Math.max(0, Math.min(255, Math.round(v)));
  return hex((c(r) << 16) | (c(g) << 8) | c(b));
}

/** The color shown in a light's orb. */
export function orbColor(d: LightDevice): string | undefined {
  if (d.power === false || d.online === false) return undefined;
  if (d.colorTemperature && d.colorTemperature > 0) return kelvinToHex(d.colorTemperature);
  if (d.rgb !== undefined) return hex(d.rgb);
  return '#ffd9a0';
}

export const BASIC_TYPES: Record<string, string> = {
  powerSwitch: 'devices.capabilities.on_off',
  brightness: 'devices.capabilities.range',
  colorRgb: 'devices.capabilities.color_setting',
  colorTemperatureK: 'devices.capabilities.color_setting',
};
export const BASIC = Object.keys(BASIC_TYPES);

export const capOf = (d: LightDevice, instance: string) => d.capabilities.find((c) => c.instance === instance);
export const supports = (d: LightDevice, instance: string) => (d.ip !== undefined && BASIC.includes(instance)) || d.capabilities.some((c) => c.instance === instance);

export function basicCommand(d: LightDevice | undefined, instance: string, value: number): CapabilityCommand {
  return { type: (d && capOf(d, instance)?.type) || BASIC_TYPES[instance]!, instance, value };
}

const intOr = (v: unknown, fallback: number) => (typeof v === 'number' && Number.isSafeInteger(v) ? v : fallback);

export function rangeOf(params: JSONValue | undefined, fallback: [number, number]): [number, number] {
  const r = isObj(params) && isObj(params.range) ? params.range : undefined;
  const lo = intOr(r?.min, fallback[0]), hi = intOr(r?.max, fallback[1]);
  return lo <= hi ? [lo, hi] : fallback;
}

/** Mirrors core whiteRange: advertised bounds clamped to 1000…10000; LAN-only lights 2000…9000. */
export function whiteRange(d: LightDevice | undefined): [number, number] {
  const [lo, hi] = rangeOf(d && capOf(d, 'colorTemperatureK')?.parameters, [2000, 9000]);
  const a = Math.max(1000, lo), b = Math.min(10000, hi);
  return a <= b ? [a, b] : [2000, 9000];
}

export function brightnessRange(d: LightDevice | undefined): [number, number] {
  const [lo, hi] = rangeOf(d && capOf(d, 'brightness')?.parameters, [1, 100]);
  const a = Math.max(1, lo), b = Math.min(100, hi);
  return a <= b ? [a, b] : [1, 100];
}

/** Non-basic, user-controllable capabilities shown on the Effects tab. */
export function effectCapabilities(d: LightDevice): Capability[] {
  return d.capabilities.filter((c) => !BASIC.includes(c.instance) && !c.type.endsWith('.online') && !c.type.endsWith('.event'));
}

export function friendly(instance: string): string {
  const known: Record<string, string> = {
    lightScene: 'Scenes', diyScene: 'DIY effects', musicMode: 'Music mode', segmentedColorRgb: 'Segment color', segmentedBrightness: 'Segment brightness',
    nightlightScene: 'Night light scene', presetScene: 'Preset scene', hdmiSource: 'HDMI source', gradientToggle: 'Gradient', dreamViewToggle: 'DreamView',
    nightlightToggle: 'Night light', snapshot: 'Snapshots', rgb: 'Color', segment: 'Segments', autoColor: 'Auto color', powerSwitch: 'Power', brightness: 'Brightness', colorRgb: 'Color', colorTemperatureK: 'White temperature',
  };
  return known[instance] ?? instance.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, (c) => c.toUpperCase());
}

export function describeCommand(c: CapabilityCommand): string {
  switch (c.instance) {
    case 'powerSwitch': return c.value === 1 ? 'Turn on' : 'Turn off';
    case 'brightness': return `Brightness ${c.value}%`;
    case 'colorRgb': return `Color ${typeof c.value === 'number' ? hex(c.value).toUpperCase() : ''}`;
    case 'colorTemperatureK': return `White ${c.value} K`;
    default: return `${friendly(c.instance)} (advanced)`;
  }
}

export const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** Next local occurrence strictly after now (mirrors core nextOccurrence). */
export function nextOccurrence(s: SceneSchedule, from = new Date()): Date | undefined {
  if (!s.enabled || s.weekdays.length === 0) return undefined;
  for (let offset = 0; offset <= 8; offset++) {
    const c = new Date(from.getFullYear(), from.getMonth(), from.getDate() + offset, s.hour, s.minute, 0, 0);
    if (c.getHours() !== s.hour || c.getMinutes() !== s.minute) continue;
    if (c > from && s.weekdays.includes(c.getDay() + 1)) return c;
  }
  return undefined;
}

export function relativeTime(ms: number): string {
  const s = Math.round((Date.now() - ms) / 1000);
  if (s < 10) return 'just now';
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(ms).toLocaleDateString();
}

export function uuid(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6]! & 0x0f) | 0x40; b[8] = (b[8]! & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// ---- icons (24px stroke icons, drawn for Luma) ----
const PATHS: Record<string, string> = {
  sparkles: 'M12 3l1.8 4.7L18.5 9.5l-4.7 1.8L12 16l-1.8-4.7L5.5 9.5l4.7-1.8zM19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z',
  moon: 'M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z',
  sun: 'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8zM12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4',
  sofa: 'M4 11V8a3 3 0 0 1 3-3h10a3 3 0 0 1 3 3v3M3 11a2 2 0 0 1 2 2v2h14v-2a2 2 0 1 1 2 2v3H3v-3a2 2 0 0 1 0-4zM6 18v2M18 18v2',
  bed: 'M3 18V6M3 14h18v4M21 18v-6a3 3 0 0 0-3-3h-7v5M7 11.5a1.5 1.5 0 1 0 0-.01',
  book: 'M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2zM4 19V5M19 19v2H6',
  film: 'M4 4h16v16H4zM8 4v16M16 4v16M4 8h4M4 12h4M4 16h4M16 8h4M16 12h4M16 16h4',
  party: 'M4 20l4-12 8 8zM14 4l1 2M19 5l-2 2M20 10l-2-.5M11 3c0 2 1 3 3 3',
  leaf: 'M5 19C5 10 10 5 20 4c-1 10-6 15-15 15zM5 19l7-7',
  coffee: 'M4 9h12v5a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5zM16 10h1.5a2.5 2.5 0 0 1 0 5H16M8 3v3M12 3v3',
  bolt: 'M13 2L4 14h7l-1 8 9-12h-7z',
  heart: 'M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z',
  bulb: 'M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z',
  scenes: 'M4 6h16M4 12h10M4 18h7M18 14l3 3-3 3',
  clock: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18zM12 7v5l3 2',
  gear: 'M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
  info: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18zM12 11v6M12 7.5v.01',
  refresh: 'M20 11a8 8 0 0 0-14.3-4.9L4 8M4 4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16M20 20v-4h-4',
  close: 'M6 6l12 12M18 6L6 18',
  up: 'M12 19V5M6 11l6-6 6 6',
  down: 'M12 5v14M6 13l6 6 6-6',
  trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
  play: 'M7 4l13 8-13 8z',
  stop: 'M6 6h12v12H6z',
  plus: 'M12 5v14M5 12h14',
  wifi: 'M2 9a15 15 0 0 1 20 0M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M12 19.5v.01',
  power: 'M12 3v8M6.3 6.3a8 8 0 1 0 11.4 0',
  screen: 'M3 4h18v12H3zM8 20h8M12 16v4',
  pause: 'M8 5v14M16 5v14',
};
export const SCENE_ICONS = ['sparkles', 'moon', 'sun', 'sofa', 'bed', 'book', 'film', 'party', 'leaf', 'coffee', 'bolt', 'heart'];

export function icon(name: string, label?: string): string {
  const d = PATHS[name] ?? PATHS.sparkles!;
  const a11y = label ? `role="img" aria-label="${esc(label)}"` : 'aria-hidden="true"';
  return `<svg class="icon" viewBox="0 0 24 24" ${a11y} fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="${d}"/></svg>`;
}

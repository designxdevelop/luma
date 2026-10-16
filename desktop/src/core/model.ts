// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Commands, schema validation and scene validation. Ported from the Mac LumaCore
// CommandValidation contracts. Everything here is pure and synchronous.

import { randomUUID } from 'node:crypto';
import type { Capability, CapabilityCommand, JSONValue, LightDevice, LightScene, SceneStep } from '../shared/types';

export class LumaError extends Error {
  constructor(message: string, readonly status = 400) { super(message); this.name = 'LumaError'; }
}

export function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export const LAN_INSTANCES = ['powerSwitch', 'brightness', 'colorRgb', 'colorTemperatureK'] as const;
export const BASIC_TYPES: Record<string, string> = {
  powerSwitch: 'devices.capabilities.on_off',
  brightness: 'devices.capabilities.range',
  colorRgb: 'devices.capabilities.color_setting',
  colorTemperatureK: 'devices.capabilities.color_setting',
};

export const power = (on: boolean): CapabilityCommand => ({ type: BASIC_TYPES.powerSwitch!, instance: 'powerSwitch', value: on ? 1 : 0 });
export const brightness = (value: number): CapabilityCommand => ({ type: BASIC_TYPES.brightness!, instance: 'brightness', value });
export const rgb = (value: number): CapabilityCommand => ({ type: BASIC_TYPES.colorRgb!, instance: 'colorRgb', value });
export const kelvin = (value: number): CapabilityCommand => ({ type: BASIC_TYPES.colorTemperatureK!, instance: 'colorTemperatureK', value });

export function isObject(value: unknown): value is { [key: string]: JSONValue } {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Returns an integer only when `value` is a finite number that is exactly an integer
 * within the safe range. Range checks happen on the number BEFORE any coercion, so
 * 1e100 or 0.5 are rejected rather than clamped or truncated.
 */
export function safeInt(value: unknown, min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value) || !Number.isInteger(value)) return undefined;
  if (value < min || value > max || !Number.isSafeInteger(value)) return undefined;
  return value;
}

export function jsonEqual(a: JSONValue | undefined, b: JSONValue | undefined): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || a === undefined || b === undefined) return false;
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((v, i) => jsonEqual(v, b[i]));
  if (isObject(a) && isObject(b)) {
    const ak = Object.keys(a), bk = Object.keys(b);
    return ak.length === bk.length && ak.every((k) => Object.hasOwn(b, k) && jsonEqual(a[k], b[k]));
  }
  return false;
}

export function capability(device: LightDevice, instance: string): Capability | undefined {
  return device.capabilities.find((c) => c.instance === instance);
}

export function supports(device: LightDevice, instance: string): boolean {
  return (device.ip !== undefined && (LAN_INSTANCES as readonly string[]).includes(instance)) || device.capabilities.some((c) => c.instance === instance);
}

function rangeOf(parameters: JSONValue | undefined): { min?: number; max?: number; precision?: number } {
  const range = isObject(parameters) && isObject(parameters.range) ? parameters.range : undefined;
  return {
    min: safeInt(range?.min),
    max: safeInt(range?.max),
    precision: typeof range?.precision === 'number' && range.precision > 0 && Number.isFinite(range.precision) ? range.precision : undefined,
  };
}

/** Model white bounds: the advertised range, clamped to 1000…10000; LAN-only lights use 2000…9000. */
export function whiteRange(device: LightDevice | undefined): [number, number] {
  const r = device ? rangeOf(capability(device, 'colorTemperatureK')?.parameters) : {};
  const lower = Math.max(1000, r.min ?? 2000), upper = Math.min(10000, r.max ?? 9000);
  return lower <= upper ? [lower, upper] : [2000, 9000];
}

/** Brightness bounds from the advertised schema, clamped to 1…100. */
export function brightnessRange(device: LightDevice | undefined): [number, number] {
  const r = device ? rangeOf(capability(device, 'brightness')?.parameters) : {};
  const lower = Math.max(1, r.min ?? 1), upper = Math.min(100, r.max ?? 100);
  return lower <= upper ? [lower, upper] : [1, 100];
}

const FIXED_RANGES: Record<string, [number, number]> = { powerSwitch: [0, 1], brightness: [1, 100], colorRgb: [0, 0xffffff], colorTemperatureK: [1000, 10000] };

export function validateCommand(command: CapabilityCommand, device: LightDevice): void {
  if (!isObject(command) || typeof command.type !== 'string' || typeof command.instance !== 'string' || !('value' in command)) {
    throw new LumaError('A command needs type, instance and value.');
  }
  if (command.type.length > 128 || command.instance.length > 128) throw new LumaError('Capability name is too long.');
  if (!supports(device, command.instance)) throw new LumaError(`${device.name} does not advertise ${command.instance}. Connect cloud to load all capabilities.`);
  const cap = capability(device, command.instance);
  if (cap) {
    if (cap.type !== command.type) throw new LumaError('Capability type does not match this device.');
    validateValue(command.value, cap.parameters);
  } else if (BASIC_TYPES[command.instance] !== command.type) {
    throw new LumaError('Invalid LAN capability type.');
  }
  const fixed = FIXED_RANGES[command.instance];
  if (fixed) {
    if (safeInt(command.value, fixed[0], fixed[1]) === undefined) throw new LumaError(`${command.instance} must be an integer in ${fixed[0]}…${fixed[1]}.`);
    if (command.instance === 'colorTemperatureK') {
      const [lo, hi] = whiteRange(device);
      if ((command.value as number) < lo || (command.value as number) > hi) throw new LumaError(`White temperature must be ${lo}…${hi} K for ${device.name}.`);
    }
  }
}

/** Validates a value against a Govee capability parameter schema (ENUM / INTEGER / STRUCT / ARRAY). */
export function validateValue(value: JSONValue, parameters: JSONValue | undefined, depth = 0): void {
  if (depth > 8) throw new LumaError('Capability value is nested too deeply.');
  if (!isObject(parameters)) return;
  const dataType = typeof parameters.dataType === 'string' ? parameters.dataType.toUpperCase() : undefined;
  switch (dataType) {
    case 'INTEGER': {
      const r = rangeOf(parameters);
      if (safeInt(value) === undefined) throw new LumaError('Expected an integer value.');
      const n = value as number;
      if (r.min !== undefined && n < r.min) throw new LumaError(`Value is below the device minimum (${r.min}).`);
      if (r.max !== undefined && n > r.max) throw new LumaError(`Value exceeds the device maximum (${r.max}).`);
      return;
    }
    case 'ENUM': {
      const options = Array.isArray(parameters.options) ? parameters.options : [];
      if (options.length > 0 && !options.some((o) => isObject(o) && jsonEqual(o.value, value))) throw new LumaError("Choose one of the device's advertised values.");
      return;
    }
    case 'STRUCT': {
      if (!isObject(value)) throw new LumaError('Expected a JSON object for this capability.');
      const fields = Array.isArray(parameters.fields) ? parameters.fields.filter(isObject) : [];
      const known = new Set(fields.map((f) => f.fieldName).filter((n): n is string => typeof n === 'string'));
      for (const key of Object.keys(value)) if (fields.length > 0 && !known.has(key)) throw new LumaError(`Unknown field: ${key}.`);
      for (const field of fields) {
        const name = field.fieldName;
        if (typeof name !== 'string') continue;
        if (Object.hasOwn(value, name)) validateValue(value[name]!, field, depth + 1);
        else if (field.required === true) throw new LumaError(`Missing required field: ${name}.`);
      }
      return;
    }
    case 'ARRAY': {
      if (!Array.isArray(value)) throw new LumaError('Expected an array.');
      const size = isObject(parameters.size) ? parameters.size : {};
      if (typeof size.min === 'number' && value.length < size.min) throw new LumaError('Array has fewer items than the device minimum.');
      if (typeof size.max === 'number' && value.length > size.max) throw new LumaError('Array has more items than the device maximum.');
      if (value.length > 1024) throw new LumaError('Array is too long.');
      // Govee's real Array schemas often advertise members as options with no elementType.
      const members = Array.isArray(parameters.options) ? parameters.options.filter(isObject) : [];
      if (members.length > 0) {
        for (const item of value) if (!members.some((o) => jsonEqual(o.value, item))) throw new LumaError("Choose items from the device's advertised options.");
      }
      if (typeof parameters.elementType === 'string') {
        const element: { [key: string]: JSONValue } = { dataType: parameters.elementType };
        if (parameters.elementRange !== undefined) element.range = parameters.elementRange;
        for (const item of value) validateValue(item, element, depth + 1);
      }
      if (parameters.fieldName === 'segment') {
        if (value.length === 0) throw new LumaError('Choose at least one segment.');
        const seen = new Set<number>();
        for (const item of value) {
          if (safeInt(item) === undefined) throw new LumaError('Segment indexes must be integers.');
          if (seen.has(item as number)) throw new LumaError('Segment indexes must be unique.');
          seen.add(item as number);
        }
      }
      return;
    }
    default:
      return;
  }
}

export const SCENE_LIMITS = { steps: 200, stepDelay: 60_000, totalDelay: 300_000, name: 80 } as const;

export function validateScene(scene: LightScene, devices: LightDevice[]): void {
  if (!isObject(scene)) throw new LumaError('A scene must be a JSON object.');
  if (typeof scene.name !== 'string' || scene.name.trim() === '') throw new LumaError('Give the scene a name.');
  if (scene.name.length > SCENE_LIMITS.name) throw new LumaError(`Scene names are limited to ${SCENE_LIMITS.name} characters.`);
  if (!Array.isArray(scene.steps) || scene.steps.length === 0 || scene.steps.length > SCENE_LIMITS.steps) throw new LumaError('Scenes need 1–200 steps.');
  const ids = new Set<string>();
  let total = 0;
  for (const step of scene.steps) {
    if (!isObject(step) || typeof step.id !== 'string' || step.id === '' || step.id.length > 64) throw new LumaError('Each scene step needs an ID.');
    if (ids.has(step.id)) throw new LumaError('Each scene step needs a unique ID.');
    ids.add(step.id);
    const delay = safeInt(step.delayMilliseconds, 0, SCENE_LIMITS.stepDelay);
    if (delay === undefined) throw new LumaError('Step delays must be whole milliseconds from 0 to 60000.');
    total += delay;
    if (total > SCENE_LIMITS.totalDelay) throw new LumaError('Total scene delay must be 5 minutes or less.');
    const device = devices.find((d) => d.id === step.deviceID);
    if (!device) throw new LumaError('Scene references a light that is no longer connected.');
    validateCommand(step.command, device);
  }
}

/**
 * Strictly decodes untrusted scene JSON (import, IPC, legacy files) and validates it
 * before anything is rendered or executed. Unknown keys are dropped.
 */
export function decodeScene(input: unknown, devices: LightDevice[], options: { newID?: boolean } = {}): LightScene {
  if (!isObject(input)) throw new LumaError("That JSON isn't a valid scene.");
  const steps = input.steps;
  if (!Array.isArray(steps)) throw new LumaError('A scene needs a steps array.');
  const scene: LightScene = {
    id: !options.newID && typeof input.id === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(input.id) ? input.id : randomUUID(),
    name: typeof input.name === 'string' ? input.name.trim() : '',
    icon: typeof input.icon === 'string' && /^[a-z-]{1,24}$/.test(input.icon) ? input.icon : 'sparkles',
    steps: steps.map((raw): SceneStep => {
      if (!isObject(raw) || !isObject(raw.command)) throw new LumaError('Each step needs a device and command.');
      return {
        id: typeof raw.id === 'string' ? raw.id : '',
        deviceID: typeof raw.deviceID === 'string' ? raw.deviceID : '',
        command: { type: raw.command.type as string, instance: raw.command.instance as string, value: raw.command.value as JSONValue },
        delayMilliseconds: raw.delayMilliseconds === undefined ? 0 : (raw.delayMilliseconds as number),
      };
    }),
  };
  validateScene(scene, devices);
  return scene;
}

/** Legacy repair: give duplicate or missing step IDs fresh UUIDs (used only when loading saved files). */
export function repairStepIDs(scene: LightScene): LightScene {
  const seen = new Set<string>();
  return {
    ...scene,
    steps: scene.steps.map((step) => {
      const ok = typeof step.id === 'string' && step.id !== '' && !seen.has(step.id);
      const id = ok ? step.id : randomUUID();
      seen.add(id);
      return ok ? step : { ...step, id };
    }),
  };
}

/** HTTP /v1/actions body: {target, power?, brightness?, color?, kelvin?}. */
export function parseAction(body: unknown, devices: LightDevice[]): { deviceIDs: string[]; commands: CapabilityCommand[] } {
  if (!isObject(body)) throw new LumaError('Action body must be a JSON object.');
  const allowed = new Set(['target', 'power', 'brightness', 'color', 'kelvin']);
  for (const key of Object.keys(body)) if (!allowed.has(key)) throw new LumaError(`Unknown action field: ${key}.`);
  const target = body.target;
  if (typeof target !== 'string' || target === '') throw new LumaError('target is required: all, a device ID, or room:Name.');
  const selected = target === 'all' ? devices : target.startsWith('room:') ? devices.filter((d) => d.room === target.slice(5)) : devices.filter((d) => d.id === target);
  if (selected.length === 0 || selected.length > 100) throw new LumaError('Target must match 1–100 lights.');
  const commands: CapabilityCommand[] = [];
  if (body.power !== undefined) {
    if (typeof body.power !== 'boolean') throw new LumaError('power must be true or false.');
    commands.push(power(body.power));
  }
  if (body.brightness !== undefined) {
    const n = safeInt(body.brightness, 1, 100);
    if (n === undefined) throw new LumaError('Brightness must be an integer 1–100.');
    commands.push(brightness(n));
  }
  if (body.color !== undefined && body.kelvin !== undefined) throw new LumaError('Choose color or kelvin in one action.');
  if (body.color !== undefined) {
    const hex = typeof body.color === 'string' ? body.color.replace(/^#/, '') : '';
    if (!/^[0-9a-fA-F]{6}$/.test(hex)) throw new LumaError('Color must be a six-digit RGB hex color.');
    commands.push(rgb(parseInt(hex, 16)));
  }
  if (body.kelvin !== undefined) {
    const n = safeInt(body.kelvin, 1000, 10000);
    if (n === undefined) throw new LumaError('Kelvin must be an integer 1000–10000.');
    commands.push(kelvin(n));
  }
  if (commands.length === 0) throw new LumaError('Supply power, brightness, color, or kelvin.');
  return { deviceIDs: selected.map((d) => d.id), commands };
}

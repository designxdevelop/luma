// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Synthetic demo home. These are invented sample lights; nothing here is a real
// device, inventory or capture, and demo mode never touches the network.

import type { Capability, LightDevice, LightScene } from '../shared/types';
import { brightness, kelvin, power, rgb } from '../core/model';

const basic = (white: [number, number] = [2000, 9000]): Capability[] => [
  { type: 'devices.capabilities.on_off', instance: 'powerSwitch', parameters: { dataType: 'ENUM', options: [{ name: 'on', value: 1 }, { name: 'off', value: 0 }] } },
  { type: 'devices.capabilities.range', instance: 'brightness', parameters: { dataType: 'INTEGER', range: { min: 1, max: 100, precision: 1 }, unit: 'unit.percent' } },
  { type: 'devices.capabilities.color_setting', instance: 'colorRgb', parameters: { dataType: 'INTEGER', range: { min: 0, max: 16777215, precision: 1 } } },
  { type: 'devices.capabilities.color_setting', instance: 'colorTemperatureK', parameters: { dataType: 'INTEGER', range: { min: white[0], max: white[1], precision: 1 } } },
];

const effects: Capability[] = [
  { type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', parameters: { dataType: 'ENUM', options: [
    { name: 'Sunrise', value: { paramId: 1, id: 101 } }, { name: 'Aurora', value: { paramId: 2, id: 102 } }, { name: 'Candlelight', value: { paramId: 3, id: 103 } },
  ] } },
  { type: 'devices.capabilities.segment_color_setting', instance: 'segmentedColorRgb', parameters: { dataType: 'STRUCT', fields: [
    { fieldName: 'segment', dataType: 'Array', elementType: 'INTEGER', elementRange: { min: 0, max: 14 }, size: { min: 1, max: 15 }, required: true },
    { fieldName: 'rgb', dataType: 'INTEGER', range: { min: 0, max: 16777215 }, required: true },
  ] } },
  { type: 'devices.capabilities.segment_color_setting', instance: 'segmentedBrightness', parameters: { dataType: 'STRUCT', fields: [
    { fieldName: 'segment', dataType: 'Array', elementType: 'INTEGER', elementRange: { min: 0, max: 14 }, size: { min: 1, max: 15 }, required: true },
    { fieldName: 'brightness', dataType: 'INTEGER', range: { min: 0, max: 100 }, required: true },
  ] } },
  { type: 'devices.capabilities.music_setting', instance: 'musicMode', parameters: { dataType: 'STRUCT', fields: [
    { fieldName: 'musicMode', dataType: 'ENUM', options: [{ name: 'Energic', value: 1 }, { name: 'Rhythm', value: 2 }, { name: 'Spectrum', value: 3 }, { name: 'Rolling', value: 4 }], required: true },
    { fieldName: 'sensitivity', dataType: 'INTEGER', range: { min: 0, max: 100, precision: 1 }, required: false },
    { fieldName: 'autoColor', dataType: 'ENUM', options: [{ name: 'on', value: 1 }, { name: 'off', value: 0 }], required: false },
  ] } },
  { type: 'devices.capabilities.toggle', instance: 'gradientToggle', parameters: { dataType: 'ENUM', options: [{ name: 'on', value: 1 }, { name: 'off', value: 0 }] } },
];

export function demoDevices(): LightDevice[] {
  const now = Date.now();
  return [
    { id: 'demo-floor', sku: 'Demo floor lamp', name: 'Corner glow', room: 'Living room', capabilities: basic(), power: true, brightness: 65, rgb: 0xffb66a, colorTemperature: 0, online: true, lastSeen: now, isDemo: true },
    { id: 'demo-strip', sku: 'Demo strip', name: 'Behind the sofa', room: 'Living room', capabilities: [...basic(), ...effects], power: true, brightness: 42, rgb: 0xca8bff, colorTemperature: 0, online: true, lastSeen: now, isDemo: true },
    { id: 'demo-desk', sku: 'Demo light bars', name: 'Desk lights', room: 'Office', capabilities: [...basic([2700, 6500]), effects[0]!, effects[4]!], power: true, brightness: 80, rgb: 0, colorTemperature: 4500, online: true, lastSeen: now, isDemo: true },
    { id: 'demo-bed', sku: 'Demo bulb', name: 'Bedside', room: 'Bedroom', capabilities: basic([2200, 6500]), power: false, brightness: 25, rgb: 0xffc58b, colorTemperature: 0, online: true, lastSeen: now, isDemo: true },
    { id: 'demo-porch', sku: 'Demo outdoor', name: 'Porch', room: 'Outside', capabilities: basic(), power: false, brightness: 50, rgb: 0xffffff, colorTemperature: 0, online: false, lastSeen: now - 3_600_000, isDemo: true },
  ];
}

export function demoScenes(): LightScene[] {
  return [
    { id: 'demo-scene-evening', name: 'Evening unwind', icon: 'moon', steps: [
      { id: 'e1', deviceID: 'demo-floor', command: power(true), delayMilliseconds: 0 },
      { id: 'e2', deviceID: 'demo-floor', command: brightness(35), delayMilliseconds: 0 },
      { id: 'e3', deviceID: 'demo-floor', command: rgb(0xffae64), delayMilliseconds: 0 },
      { id: 'e4', deviceID: 'demo-strip', command: power(true), delayMilliseconds: 500 },
      { id: 'e5', deviceID: 'demo-strip', command: rgb(0xff8a3d), delayMilliseconds: 0 },
    ] },
    { id: 'demo-scene-focus', name: 'Focus time', icon: 'sun', steps: [
      { id: 'f1', deviceID: 'demo-desk', command: power(true), delayMilliseconds: 0 },
      { id: 'f2', deviceID: 'demo-desk', command: kelvin(5000), delayMilliseconds: 0 },
      { id: 'f3', deviceID: 'demo-desk', command: brightness(90), delayMilliseconds: 0 },
    ] },
  ];
}

/** Extra synthetic options returned by "Load effects" in demo mode. */
export function demoEffects(diy: boolean): Capability[] {
  return diy
    ? [{ type: 'devices.capabilities.diy_color_setting', instance: 'diyScene', parameters: { dataType: 'ENUM', options: [{ name: 'Demo DIY: Ember', value: 9001 }, { name: 'Demo DIY: Tide', value: 9002 }] } }]
    : [{ type: 'devices.capabilities.dynamic_scene', instance: 'lightScene', parameters: { dataType: 'ENUM', options: [{ name: 'Forest', value: { paramId: 4, id: 104 } }] } }];
}

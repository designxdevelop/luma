import type { LightDevice, LightScene } from '../shared/types';

export function filterLights(devices: LightDevice[], query: string): LightDevice[] {
  const term = query.trim().toLocaleLowerCase();
  return devices.filter(d => `${d.name} ${d.room} ${d.sku}`.toLocaleLowerCase().includes(term));
}

export const DAY_PRESETS = {
  daily: [1, 2, 3, 4, 5, 6, 7], weekdays: [2, 3, 4, 5, 6], weekends: [1, 7],
} as const;

export function duplicateScene(scene: LightScene, id: () => string): LightScene {
  return { ...structuredClone(scene), id: id(), name: `${scene.name.slice(0, 75)} Copy`, steps: scene.steps.map(step => ({ ...structuredClone(step), id: id() })) };
}

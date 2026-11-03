// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Views ported from the Mac/iPhone app: floor plans, the searchable Govee scene list
// (one light, or a room by scene name), and DreamView group readback with the local
// partner draft. Main validates every change again.

import type { AppSnapshot, DreamViewDraft, FloorPlan, LightDevice, LumaBridge } from '../shared/types';
import { isLight } from '../shared/devices.js';
import {
  DREAMVIEW_APPLY_BLOCKER, SCENE_KINDS, SCENE_KIND_TITLE, advertisesScenes, dreamViewMemberLimit, matchesQuery, pinOrder, planSceneApply,
  sceneCommand, sceneRows, type SceneKind, type SceneRow,
} from '../shared/library.js';
import { basicCommand, esc, icon, orbColor, supports, uuid } from './ui.js';

interface Host {
  luma: LumaBridge;
  snap(): AppSnapshot | undefined;
  act(work: () => Promise<unknown>, success?: string): Promise<void>;
  render(): void;
  flash(text: string, error?: boolean): void;
  /** Opens a light's controls on the Lights page. */
  open(id: string): void;
}
let host: Host;

const ui = {
  floor: undefined as string | undefined,
  editing: false,
  list: false,
  images: new Map<string, { version: number; url?: string; loading?: boolean }>(),
  query: new Map<string, string>(),
  kind: new Map<string, SceneKind | ''>(),
  browserRoom: '',
  browserLight: '',
  applying: undefined as string | undefined,
  message: new Map<string, { text: string; error: boolean }>(),
  drag: undefined as { id: string; pin: HTMLElement; moved: boolean } | undefined,
};

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
const pinState = (d: LightDevice | undefined) => !d ? 'Not found. Its place is kept.' : d.online === false ? 'Offline' : d.power ? (d.brightness ? `On, ${d.brightness}%` : 'On') : 'Off';

// ---------------- floor plans ----------------

function currentPlan(s: AppSnapshot): (FloorPlan & { imageVersion: number }) | undefined {
  return s.floorPlans.find((p) => p.id === ui.floor) ?? s.floorPlans[0];
}

/** Image for a floor as a short blob: URL (CSP allows blob: images); fetched once per image version. */
function imageURL(plan: FloorPlan & { imageVersion: number }): string | undefined {
  const cached = ui.images.get(plan.id);
  if (cached && cached.version === plan.imageVersion) return cached.url;
  if (cached?.url) URL.revokeObjectURL(cached.url);
  ui.images.set(plan.id, { version: plan.imageVersion, loading: true });
  void host.luma.floorPlanImage(plan.id).then((data) => {
    let url: string | undefined;
    if (data) {
      const bytes = Uint8Array.from(atob(data.slice(data.indexOf(',') + 1)), (c) => c.charCodeAt(0));
      url = URL.createObjectURL(new Blob([bytes], { type: 'image/png' }));
    }
    ui.images.set(plan.id, { version: plan.imageVersion, url });
    host.render();
  }, () => { ui.images.set(plan.id, { version: plan.imageVersion }); host.render(); });
  return undefined;
}

export function floorView(s: AppSnapshot): string {
  const plan = currentPlan(s);
  const placed = new Set(s.floorPlans.flatMap((p) => p.pins.map((pin) => pin.deviceID)));
  const unplaced = s.devices.filter((d) => !placed.has(d.id));
  const writable = s.floorPlansWritable;
  if (!plan) ui.editing = false;
  const url = plan && imageURL(plan);
  const loading = plan && ui.images.get(plan.id)?.loading;
  return `<section class="pane floor" aria-labelledby="floor-title">
    <header class="toolbar">
      <div><h1 id="floor-title">Floor plan</h1><p class="sub">Place your lights on a picture of your home. Click a light to switch it.</p></div>
      <div class="actions">
        ${plan ? `<button data-action="fp-list">${ui.list ? 'Map' : 'List'}</button>
        <button class="${ui.editing ? 'primary' : ''}" data-action="fp-edit" ${ui.list || !writable ? 'disabled' : ''}>${ui.editing ? 'Done' : 'Edit'}</button>` : ''}
        <button data-action="fp-add" ${writable ? '' : 'disabled'}>${icon('plus')}Add floor</button>
      </div>
    </header>
    ${writable ? '' : '<p class="hint warn" role="alert">Existing floor plans could not be read and have been preserved. Nothing is saved over them.</p>'}
    ${s.floorPlans.length > 1 || plan ? `<div class="segmented floors" role="tablist" aria-label="Floors">${s.floorPlans.map((p) => `<button role="tab" aria-selected="${p.id === plan?.id}" data-action="fp-select" data-id="${esc(p.id)}">${esc(p.name)}</button>`).join('')}</div>` : ''}
    ${!plan ? `<div class="empty"><h2>Add a floor plan</h2><p>Use a photo or image of your floor plan (PNG or JPEG), then place your lights on it. The image stays on this PC; location data is removed.</p><button class="primary" data-action="fp-add" ${writable ? '' : 'disabled'}>Choose image…</button></div>`
    : ui.list || (!url && !loading) ? `${!ui.list ? '<p class="hint warn">The floor image can\'t be shown. Lights are listed instead.</p>' : ''}${pinList(s, plan)}`
    : `<div class="floor-canvas ${ui.editing ? 'editing' : ''}" data-action="fp-canvas" data-id="${esc(plan.id)}" aria-label="Floor plan ${esc(plan.name)}">
        ${url ? `<img src="${esc(url)}" alt="" draggable="false">` : '<p class="hint">Loading image…</p>'}
        ${url ? plan.pins.map((pin) => pinMark(s, pin)).join('') : ''}
      </div>
      ${ui.editing ? `<div class="floor-tray" data-action="fp-tray" data-id="${esc(plan.id)}">
        <p class="hint">${unplaced.length ? 'Not on any floor: click to place in the middle, or drag onto the plan. Select a pin and use the arrow keys to nudge it, Delete to remove it.' : 'Every light has a place. Drag a pin here, or select it and press Delete, to remove it.'}</p>
        <div class="actions wrap">${unplaced.map((d) => `<button class="chip" draggable="true" data-action="fp-place" data-device="${esc(d.id)}"><span class="orb tiny" data-color="${orbColor(d) ?? ''}"></span>${esc(d.name)}</button>`).join('')}</div>
      </div>` : `<p class="hint">Click a light to switch it on or off; double-click for its controls.</p>`}`}
    ${plan ? `<details class="advanced"><summary>Floor options</summary><div class="actions wrap">
      <input id="fp-name" maxlength="64" value="${esc(plan.name)}" aria-label="Floor name"><button data-action="fp-rename" data-id="${esc(plan.id)}" ${writable ? '' : 'disabled'}>Rename</button>
      <button data-action="fp-replace" data-id="${esc(plan.id)}" ${writable ? '' : 'disabled'}>Replace image…</button>
      <button class="danger" data-action="fp-delete" data-id="${esc(plan.id)}" ${writable ? '' : 'disabled'}>${icon('trash')}Delete floor</button>
    </div><p class="hint">Replacing the image keeps every pin where it is. Deleting removes the image and its pins; your lights are not changed.</p></details>` : ''}
  </section>`;
}

function pinMark(s: AppSnapshot, pin: { deviceID: string; x: number; y: number }): string {
  const d = s.devices.find((x) => x.id === pin.deviceID);
  const on = d?.power === true && d.online !== false;
  return `<button class="pin ${on ? 'on' : ''} ${!d ? 'missing' : d.online === false ? 'offline' : ''}" data-key="pin-${esc(pin.deviceID)}" data-action="fp-pin" data-device="${esc(pin.deviceID)}"
    data-x="${pin.x}" data-y="${pin.y}" ${on ? `data-color="${orbColor(d!) ?? ''}"` : ''} aria-label="${esc(d?.name ?? 'Light not found')}: ${esc(pinState(d))}${ui.editing ? '. Editing: drag or use the arrow keys to move.' : ''}"
    title="${esc(d ? `${d.name}: click to switch on or off, double-click for controls` : "This light wasn't found. Its place is kept.")}">
    <span class="dot">${d ? '' : '?'}</span><span class="pin-label">${esc(d?.name ?? 'Not found')}</span></button>`;
}

function pinList(s: AppSnapshot, plan: FloorPlan): string {
  if (!plan.pins.length) return '<p class="hint">No lights placed on this floor yet. Choose Map, then Edit to place them.</p>';
  return `<ul class="pin-list">${pinOrder(plan).map((pin) => {
    const d = s.devices.find((x) => x.id === pin.deviceID);
    return `<li><button class="ghost" data-action="fp-open" data-device="${esc(pin.deviceID)}" ${d ? '' : 'disabled'}><span class="orb tiny" data-color="${d ? orbColor(d) ?? '' : ''}"></span>${esc(d?.name ?? 'Light not found')}<span class="sub">${esc(pinState(d))}</span></button></li>`;
  }).join('')}</ul>`;
}

/** CSP forbids inline styles: pins are positioned through CSSOM after each render. */
export function paintFloor(root: ParentNode): void {
  root.querySelectorAll<HTMLElement>('.pin[data-x]').forEach((el) => {
    if (ui.drag?.pin === el) return;
    el.style.left = `${Number(el.dataset.x) * 100}%`;
    el.style.top = `${Number(el.dataset.y) * 100}%`;
  });
}

/** 0…1 position inside the image, clamped to its edges. */
function imagePoint(canvas: Element, clientX: number, clientY: number): { x: number; y: number } {
  const r = (canvas.querySelector('img') ?? canvas).getBoundingClientRect();
  const clamp = (v: number) => Math.min(1, Math.max(0, v));
  return { x: clamp((clientX - r.left) / Math.max(1, r.width)), y: clamp((clientY - r.top) / Math.max(1, r.height)) };
}

function togglePin(id: string): void {
  const d = host.snap()?.devices.find((x) => x.id === id);
  if (!d || d.online === false || !supports(d, 'powerSwitch')) return;
  void host.act(() => host.luma.control(d.id, basicCommand(d, 'powerSwitch', d.power ? 0 : 1)));
}

const planID = () => { const s = host.snap(); return s && currentPlan(s)?.id; };
const place = (deviceID: string, x: number, y: number) => { const id = planID(); if (id) void host.act(() => host.luma.floorPlanPlace(id, deviceID, x, y)); };

// ---------------- Govee scenes ----------------

/** Searchable scene list for one light, or for several lights by scene name. */
export function sceneList(s: AppSnapshot, lights: LightDevice[], target: string, key: string): string {
  const all = sceneRows(lights);
  const query = ui.query.get(key) ?? '', kind = ui.kind.get(key) ?? '';
  const shown = all.filter((r) => (!kind || r.kind === kind) && matchesQuery(r.name, query));
  const ready = s.cloudConnected || lights.every((d) => d.isDemo);
  const blocked = !ready ? 'Govee scenes are sent through the Govee cloud. Connect your account in Settings.'
    : lights.length && lights.every((d) => d.online === false) ? (lights.length === 1 ? `${target} is offline. Govee can't change its scene until it's back.` : 'These lights are offline.') : '';
  const counts = SCENE_KINDS.map((k) => [k, all.filter((r) => r.kind === k).length] as const).filter(([, n]) => n).map(([k, n]) => `${n} ${k === 'diyScene' ? 'DIY' : SCENE_KIND_TITLE[k].toLowerCase()}`).join(' · ');
  const message = ui.message.get(key);
  return `<section class="effect scene-list" aria-label="Govee scenes for ${esc(target)}">
    <div class="room-head"><h3>Govee scenes</h3><span class="sub">${esc(counts)}</span>
      <button data-action="gs-load" data-scope="${esc(key)}" data-ids="${esc(lights.map((d) => d.id).join(','))}" ${ready && !lights.every((d) => d.isDemo) ? '' : 'disabled'}>${all.length ? 'Reload' : 'Load'}</button></div>
    ${blocked ? `<p class="hint warn">${esc(blocked)}</p>` : ''}
    ${all.length === 0 ? `<p class="hint">${ready ? `No scenes loaded for ${esc(target)} yet. Load downloads the lists Govee's API has for ${lights.length === 1 ? 'this model' : 'these models'}.` : 'Connect your Govee account in Settings to load scenes.'}</p>` : `
      <div class="actions wrap">
        <input type="search" data-action="gs-query" data-scope="${esc(key)}" value="${esc(query)}" placeholder="Search ${all.length} scenes" aria-label="Search Govee scenes">
        <select data-action="gs-kind" data-scope="${esc(key)}" aria-label="Scene type"><option value="">All</option>${SCENE_KINDS.filter((k) => all.some((r) => r.kind === k)).map((k) => `<option value="${k}" ${kind === k ? 'selected' : ''}>${SCENE_KIND_TITLE[k]}</option>`).join('')}</select>
      </div>
      ${shown.length === 0 ? `<p class="hint">No scenes match “${esc(query)}”.</p>` : ''}
      <ul class="scene-rows">${shown.slice(0, 300).map((r) => sceneRow(r, lights, key, !!blocked)).join('')}</ul>
      ${shown.length > 300 ? `<p class="hint">Showing 300 of ${shown.length}. Search to narrow the list.</p>` : ''}`}
    ${message ? `<p class="${message.error ? 'error' : 'hint'}" role="status">${esc(message.text)}</p>` : ''}
    <p class="hint">These are the scenes Govee's public API lists for ${lights.length === 1 ? 'this model' : 'these models'}. Govee Home can show more, and some of its scenes are app-only.${lights.length > 1 ? ' A scene is applied to each light that lists it by the same name; the rest are skipped.' : ''}</p>
  </section>`;
}

function sceneRow(r: SceneRow, lights: LightDevice[], key: string, disabled: boolean): string {
  const data = `data-scope="${esc(key)}" data-kind="${r.kind}" data-name="${esc(r.name)}" data-option="${esc(r.option?.id ?? '')}"`;
  return `<li><button class="ghost scene-apply" data-action="gs-apply" ${data} ${disabled || ui.applying ? 'disabled' : ''} aria-label="Apply ${esc(r.name)}">${icon(r.kind === 'diyScene' ? 'sparkles' : 'play')}
      <span>${esc(r.name)}${lights.length > 1 || r.kind !== 'lightScene' ? `<span class="sub"> · ${SCENE_KIND_TITLE[r.kind]}${lights.length > 1 ? ` · ${r.count} of ${lights.length} lights` : ''}</span>` : ''}</span>${ui.applying === `${key}|${r.id}` ? '<span class="sub">Sending…</span>' : ''}</button>
    <button class="ghost" data-action="gs-save" ${data} aria-label="Save ${esc(r.name)} as a Luma scene">Save as scene</button></li>`;
}

/** Scenes page: pick a room (or one light in it), then search and apply. */
export function sceneBrowser(s: AppSnapshot): string {
  const rooms = [...new Set(s.devices.filter(isLight).map((d) => d.room))].sort();
  if (ui.browserRoom && !rooms.includes(ui.browserRoom)) ui.browserRoom = '';
  const members = s.devices.filter((d) => isLight(d) && advertisesScenes(d) && (!ui.browserRoom || d.room === ui.browserRoom));
  const targets = ui.browserLight ? members.filter((d) => d.id === ui.browserLight) : members;
  if (ui.browserLight && targets.length === 0) ui.browserLight = '';
  const target = ui.browserLight && targets[0] ? targets[0].name : ui.browserRoom || 'All lights';
  return `<details class="card-block govee-scenes"><summary><strong>Govee scenes</strong> <span class="sub">Built-in and DIY scenes from Govee, by room or light</span></summary>
    <div class="actions wrap">
      <label>Room <select data-action="gs-room"><option value="">All lights</option>${rooms.map((r) => `<option value="${esc(r)}" ${r === ui.browserRoom ? 'selected' : ''}>${esc(r)}</option>`).join('')}</select></label>
      <label>Light <select data-action="gs-light"><option value="">Every light with scenes (${members.length})</option>${members.map((d) => `<option value="${esc(d.id)}" ${d.id === ui.browserLight ? 'selected' : ''}>${esc(d.name)}</option>`).join('')}</select></label>
    </div>
    ${targets.length === 0 ? `<p class="hint">None of the lights in ${esc(target)} advertise Govee scenes.</p>` : sceneList(s, targets, target, `browser|${ui.browserRoom}|${ui.browserLight}`)}
  </details>`;
}

function lightsFor(key: string): { lights: LightDevice[]; target: string } {
  const s = host.snap()!;
  if (key.startsWith('light|')) { const d = s.devices.find((x) => x.id === key.slice(6)); return { lights: d ? [d] : [], target: d?.name ?? '' }; }
  const members = s.devices.filter((d) => isLight(d) && advertisesScenes(d) && (!ui.browserRoom || d.room === ui.browserRoom));
  const lights = ui.browserLight ? members.filter((d) => d.id === ui.browserLight) : members;
  return { lights, target: ui.browserLight && lights[0] ? lights[0].name : ui.browserRoom || 'All lights' };
}

async function applyScene(key: string, kind: SceneKind, name: string, optionID: string): Promise<void> {
  const { lights, target } = lightsFor(key);
  const option = optionID ? sceneRows(lights).find((r) => r.option?.id === optionID)?.option : undefined;
  const plan = option && lights[0] ? [{ device: lights[0], command: sceneCommand(option) }] : planSceneApply(kind, name, lights);
  const sent = plan.filter((p) => p.command);
  const results = await Promise.allSettled(sent.map((p) => host.luma.control(p.device.id, p.command!)));
  const failed = sent.filter((_, i) => results[i]!.status === 'rejected').map((p) => p.device.name);
  const skipped = plan.filter((p) => p.skipped).map((p) => `${p.device.name} (${p.skipped})`);
  const ok = sent.length - failed.length;
  const text = !skipped.length && !failed.length ? `Applied ${name}${lights.length > 1 ? ` to ${plural(ok, 'light')}` : ''}.`
    : `Applied ${name} to ${ok} of ${lights.length} in ${target}.${skipped.length ? ` Skipped: ${skipped.join(', ')}.` : ''}${failed.length ? ` Failed: ${failed.join(', ')}.` : ''}`;
  ui.message.set(key, { text, error: failed.length > 0 || ok === 0 });
}

function saveScene(key: string, kind: SceneKind, name: string, optionID: string): void {
  const { lights, target } = lightsFor(key);
  const steps = lights.flatMap((d) => {
    const option = optionID ? sceneRows([d]).find((r) => r.option?.id === optionID)?.option : undefined;
    const command = option ? sceneCommand(option) : planSceneApply(kind, name, [d])[0]!.command;
    return command ? [{ id: uuid(), deviceID: d.id, command, delayMilliseconds: 0 }] : [];
  });
  const sceneName = `${target} · ${name}`.slice(0, 80);
  void host.act(() => host.luma.saveScene({ id: uuid(), name: sceneName, icon: 'sparkles', steps }), `Saved “${sceneName}” to Scenes.`);
}

// ---------------- DreamView ----------------

/** Govee Home group readback (name, count; members aren't shared) and the local draft that is never sent. */
export function dreamViewPartners(s: AppSnapshot, d: LightDevice): string {
  const group = s.goveeHome.groups.find((g) => g.isDreamView && g.mainDevice?.toLowerCase() === d.id.toLowerCase());
  const draft = s.dreamViewDrafts[d.id] ?? { members: [] };
  const limit = dreamViewMemberLimit(d.sku);
  const candidates = s.devices.filter((x) => x.id !== d.id && !!x.isDemo === !!d.isDemo);
  const full = limit !== undefined && draft.members.length >= limit;
  return `<details class="dv-partners"><summary>Partner lights${draft.members.length ? ` · ${draft.members.length} in draft` : ''}</summary>
    <h4>On your lights</h4>
    ${group ? `<p><strong>${esc(group.name)}</strong></p><p class="hint">${group.reportedLightCount !== undefined ? `Govee Home reports ${plural(group.reportedLightCount, 'light')} in this group` : 'Light count not reported'}${group.enabled ? '' : ' · turned off in Govee Home'}. Luma can't read which lights are in it, or their screen areas, yet.</p>`
      : `<p class="hint">${s.goveeHome.groups.length ? 'No imported DreamView group lists this light as its main light.' : s.goveeHome.signedIn ? 'Read Govee Home in Settings to show the DreamView group set up for this light.' : 'Sign in to Govee Home in Settings to show the DreamView group set up for this light.'}</p>`}
    ${s.goveeHome.signedIn && !d.isDemo ? `<button data-action="gh-import" ${s.goveeHome.busy ? 'disabled' : ''}>${s.goveeHome.groups.length ? 'Check again' : 'Check Govee Home'}</button>` : ''}
    <div class="dv-draft">
      <h4>Luma draft <span class="pill">Not sent to lights</span> <span class="sub">${draft.members.length}/${limit ?? '?'} members</span></h4>
      ${candidates.length ? '' : '<p class="hint">No other lights in Luma yet.</p>'}
      ${candidates.map((light) => {
        const member = draft.members.find((m) => m.deviceID === light.id);
        return `<div class="dv-member"><label><input type="checkbox" data-action="dv-member" data-id="${esc(d.id)}" data-device="${esc(light.id)}" ${member ? 'checked' : ''} ${!member && full ? 'disabled' : ''}> ${esc(light.name)} <span class="sub">${esc(light.sku)}</span></label>
          ${member ? `<div class="dv-areas" role="group" aria-label="Screen areas for ${esc(light.name)}">${Array.from({ length: 10 }, (_, i) => i + 1).map((area) => `<button class="chip ${member.areas.includes(area) ? 'on' : ''}" data-action="dv-area" data-id="${esc(d.id)}" data-device="${esc(light.id)}" data-area="${area}" aria-pressed="${member.areas.includes(area)}" aria-label="Screen area ${area} for ${esc(light.name)}">${area}</button>`).join('')}</div>` : ''}</div>`;
      }).join('')}
      <button disabled title="${esc(DREAMVIEW_APPLY_BLOCKER)}">Apply to lights</button>
      <p class="hint">${esc(DREAMVIEW_APPLY_BLOCKER)} Screen areas 1–10 use ha-govee-led-ble's numbering; their positions on screen aren't verified.</p>
    </div>
  </details>`;
}

function editDraft(lightID: string, change: (draft: DreamViewDraft) => void): void {
  const s = host.snap(); if (!s) return;
  const draft: DreamViewDraft = structuredClone(s.dreamViewDrafts[lightID] ?? { members: [] });
  change(draft);
  void host.act(() => host.luma.saveDreamViewDraft(lightID, draft));
}

// ---------------- events ----------------

export function initParity(h: Host): void {
  host = h;
  document.addEventListener('click', (event) => {
    const target = (event.target as Element).closest<HTMLElement>('[data-action]');
    if (!target || target instanceof HTMLInputElement || target instanceof HTMLSelectElement) return;
    const id = target.dataset.id, key = target.dataset.scope ?? '';
    switch (target.dataset.action) {
      case 'fp-add': void host.act(async () => { const created = await host.luma.floorPlanAdd(); if (created) { ui.floor = created; ui.editing = true; ui.list = false; host.render(); } }); break;
      case 'fp-select': ui.floor = id; host.render(); break;
      case 'fp-list': ui.list = !ui.list; if (ui.list) ui.editing = false; host.render(); break;
      case 'fp-edit': ui.editing = !ui.editing; host.render(); break;
      case 'fp-rename': { const name = (document.getElementById('fp-name') as HTMLInputElement | null)?.value ?? ''; void host.act(() => host.luma.floorPlanRename(id!, name), 'Floor renamed.'); break; }
      case 'fp-replace': if (confirm('Replace the floor image? Pins keep their positions. You can move them afterwards.')) void host.act(() => host.luma.floorPlanReplace(id!)); break;
      case 'fp-delete': { const plan = host.snap()?.floorPlans.find((p) => p.id === id); if (plan && confirm(`Delete ${plan.name}? The image and its pins are removed. Your lights are not changed.`)) { ui.editing = false; void host.act(() => host.luma.floorPlanDelete(plan.id)); } break; }
      case 'fp-place': place(target.dataset.device!, 0.5, 0.5); break;
      case 'fp-open': host.open(target.dataset.device!); break;
      case 'fp-pin': if (!ui.editing && event.detail <= 1) togglePin(target.dataset.device!); break;
      case 'gs-load': {
        const ids = (target.dataset.ids ?? '').split(',').filter(Boolean);
        const devices = host.snap()?.devices.filter((d) => ids.includes(d.id) && !d.isDemo) ?? [];
        void host.act(async () => {
          for (const d of devices) {
            if (supports(d, 'lightScene')) await host.luma.loadEffects(d.id, false);
            if (supports(d, 'diyScene')) await host.luma.loadEffects(d.id, true);
          }
        });
        break;
      }
      case 'gs-apply': {
        const kind = target.dataset.kind as SceneKind, name = target.dataset.name!, option = target.dataset.option ?? '';
        ui.applying = `${key}|${sceneIDFor(key, kind, name, option)}`; ui.message.delete(key); host.render();
        void applyScene(key, kind, name, option).catch((e) => ui.message.set(key, { text: e instanceof Error ? e.message : String(e), error: true })).finally(() => { ui.applying = undefined; host.render(); });
        break;
      }
      case 'gs-save': saveScene(key, target.dataset.kind as SceneKind, target.dataset.name!, target.dataset.option ?? ''); break;
      case 'dv-area': editDraft(id!, (draft) => {
        const m = draft.members.find((x) => x.deviceID === target.dataset.device); const area = Number(target.dataset.area);
        if (!m) return;
        if (m.areas.includes(area)) { if (m.areas.length > 1) m.areas = m.areas.filter((a) => a !== area); } else m.areas = [...m.areas, area].sort((a, b) => a - b);
      }); break;
    }
  });
  document.addEventListener('dblclick', (event) => {
    const pin = (event.target as Element).closest<HTMLElement>('[data-action="fp-pin"]');
    if (pin && !ui.editing && host.snap()?.devices.some((d) => d.id === pin.dataset.device)) host.open(pin.dataset.device!);
  });
  document.addEventListener('change', (event) => {
    const el = event.target as HTMLInputElement & HTMLSelectElement;
    switch (el.dataset.action) {
      case 'gs-kind': ui.kind.set(el.dataset.scope!, el.value as SceneKind | ''); host.render(); break;
      case 'gs-room': ui.browserRoom = el.value; ui.browserLight = ''; host.render(); break;
      case 'gs-light': ui.browserLight = el.value; host.render(); break;
      case 'dv-member': editDraft(el.dataset.id!, (draft) => {
        if (el.checked) draft.members.push({ deviceID: el.dataset.device!, areas: [1] }); else draft.members = draft.members.filter((m) => m.deviceID !== el.dataset.device);
      }); break;
    }
  });
  document.addEventListener('input', (event) => {
    const el = event.target as HTMLInputElement;
    if (el.dataset.action === 'gs-query') { ui.query.set(el.dataset.scope!, el.value); host.render(); }
  });
  // Edit mode: drag pins with the pointer, nudge with the keyboard, drop tray lights onto the plan.
  document.addEventListener('pointerdown', (event) => {
    const pin = (event.target as Element).closest<HTMLElement>('[data-action="fp-pin"]');
    if (!pin || !ui.editing || event.button !== 0) return;
    ui.drag = { id: pin.dataset.device!, pin, moved: false };
    pin.setPointerCapture(event.pointerId);
  });
  document.addEventListener('pointermove', (event) => {
    if (!ui.drag) return;
    const canvas = ui.drag.pin.closest('.floor-canvas'); if (!canvas) return;
    const p = imagePoint(canvas, event.clientX, event.clientY);
    ui.drag.moved = true;
    ui.drag.pin.style.left = `${p.x * 100}%`; ui.drag.pin.style.top = `${p.y * 100}%`;
  });
  const endDrag = (event: PointerEvent) => {
    const drag = ui.drag; ui.drag = undefined;
    if (!drag?.moved) return;
    const canvas = drag.pin.closest('.floor-canvas'); if (!canvas) return;
    const tray = document.querySelector('.floor-tray')?.getBoundingClientRect();
    const id = planID();
    if (id && tray && event.clientY >= tray.top && event.clientY <= tray.bottom && event.clientX >= tray.left && event.clientX <= tray.right) { void host.act(() => host.luma.floorPlanRemovePin(id, drag.id)); return; }
    const p = imagePoint(canvas, event.clientX, event.clientY);
    place(drag.id, p.x, p.y);
  };
  document.addEventListener('pointerup', endDrag);
  document.addEventListener('pointercancel', () => { ui.drag = undefined; host.render(); });
  document.addEventListener('keydown', (event) => {
    const pin = (event.target as Element).closest?.<HTMLElement>('[data-action="fp-pin"]');
    if (!pin || !ui.editing) return;
    const step = event.shiftKey ? 0.05 : 0.01;
    const moves: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    const id = planID(); if (!id) return;
    if (event.key === 'Delete' || event.key === 'Backspace') { event.preventDefault(); void host.act(() => host.luma.floorPlanRemovePin(id, pin.dataset.device!)); return; }
    const move = moves[event.key]; if (!move) return;
    event.preventDefault();
    const clamp = (v: number) => Math.min(1, Math.max(0, Math.round(v * 1000) / 1000));
    place(pin.dataset.device!, clamp(Number(pin.dataset.x) + move[0]), clamp(Number(pin.dataset.y) + move[1]));
  });
  document.addEventListener('dragstart', (event) => {
    const chip = (event.target as Element).closest?.<HTMLElement>('[data-action="fp-place"]');
    if (chip) event.dataTransfer?.setData('text/x-luma-device', chip.dataset.device!);
  });
  document.addEventListener('dragover', (event) => { if ((event.target as Element).closest?.('.floor-canvas.editing')) event.preventDefault(); });
  document.addEventListener('drop', (event) => {
    const canvas = (event.target as Element).closest?.('.floor-canvas.editing');
    const deviceID = event.dataTransfer?.getData('text/x-luma-device');
    if (!canvas || !deviceID) return;
    event.preventDefault();
    const p = imagePoint(canvas, event.clientX, event.clientY);
    place(deviceID, p.x, p.y);
  });
}

const sceneIDFor = (key: string, kind: SceneKind, name: string, option: string) => sceneRows(lightsFor(key).lights).find((r) => r.kind === kind && r.name === name && (r.option?.id ?? '') === option)?.id ?? '';

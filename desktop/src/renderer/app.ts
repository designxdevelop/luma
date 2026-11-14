// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Renderer: renders the main-process snapshot. Requested values come back from main
// as the latest-intent overlay; sliders keep a local draft only while being dragged.

import type { AppSnapshot, Capability, CapabilityCommand, JSONValue, LightDevice, LightScene, LumaBridge, SceneSchedule, SceneStep, SyncRegion, SyncSettings, SyncSource } from '../shared/types';
import { DAY_PRESETS, duplicateScene, filterLights } from './preferences.js';
import { morph } from './morph.js';
import { FramePump } from './screen-sync.js';
import { audioBanner, audioSyncView, commitAudioSetting, followAudio, initAudioSync, modeSwitch, paintAudio, syncMode } from './audio-view.js';
import { ToggleIntents } from './toggles.js';
import { scheduleSyncBlock, scheduleSyncLine, scheduleSyncSubtitle } from './schedule-sync-view.js';
import { doorbellView, initDoorbell } from './doorbell-view.js';
import { dreamViewPartners, floorView, initParity, paintFloor, sceneBrowser, sceneList } from './parity-view.js';
import { advertisesScenes } from '../shared/library.js';
import { bluetoothView, initBluetooth, leaveBluetooth } from './bluetooth-view.js';
import { isLight, paintCommands, segmentSchema, SEGMENT_INSTANCES, type SegmentSchema } from '../shared/devices.js';
import {
  BASIC, SCENE_ICONS, WEEKDAYS, basicCommand, brightnessRange, capOf, describeCommand, effectCapabilities, esc, friendly, fromHex, hex, icon,
  isObj, kelvinToHex, lookStops, nextOccurrence, orbColor, sceneStops, rangeOf, relativeTime, supports, uuid, whiteRange,
} from './ui.js';

const luma = (window as unknown as { luma: LumaBridge }).luma;

type View = 'activity' | 'lights' | 'floor' | 'bluetooth' | 'scenes' | 'sync' | 'automations' | 'settings' | 'about';
type Tab = 'light' | 'effects' | 'details';
type SceneEditor = { kind: 'editor'; draft: LightScene; json: boolean; jsonText: string; error?: string; isNew: boolean };
type Capture = { kind: 'capture'; name: string; icon: string; ids: string[]; error?: string };
type Modal = SceneEditor | Capture;

const state = {
  snap: undefined as AppSnapshot | undefined,
  view: 'lights' as View,
  selected: undefined as string | undefined,
  tab: 'light' as Tab,
  colorMode: new Map<string, 'color' | 'white'>(),
  dragging: new Set<string>(),
  effectDrafts: new Map<string, JSONValue>(),
  toggles: new ToggleIntents(),
  advanced: new Map<string, { instance: string; text: string }>(),
  modal: undefined as Modal | undefined,
  apiKey: '',
  status: undefined as { text: string; error: boolean } | undefined,
  portDraft: undefined as string | undefined,
  syncSources: undefined as SyncSource[] | undefined,
  syncSource: undefined as string | undefined,
  syncLights: new Map<string, SyncRegion>(),
  syncRegions: new Map<string, SyncRegion>(),
  search: '',
  problemsOnly: false,
  /** Segment painter drafts keyed by `${deviceID}|${instance}`. Local until Apply. */
  paint: new Map<string, Painter>(),
  painterInstance: new Map<string, string>(),
  /** Govee Home room changes the person chose, keyed by the import time they belong to. */
  goveeRooms: undefined as { importedAt: number; ids: Set<string> } | undefined,
};
type Painter = { values: Map<number, number>; selected: Set<number>; color: number; level: number };
const pump = new FramePump(luma);

const RGB_PRESETS: Array<[string, number]> = [
  ['Ember', 0xff7a2f], ['Amber', 0xffb347], ['Peach', 0xffc8a0], ['Rose', 0xff6f91], ['Lilac', 0xc59bff],
  ['Ocean', 0x3fa7ff], ['Teal', 0x2ec4b6], ['Lime', 0xa7e05a], ['Pure white', 0xffffff],
];
const WHITE_PRESETS: Array<[string, number]> = [['Candle', 2200], ['Warm', 2700], ['Soft', 3000], ['Neutral', 4000], ['Daylight', 5500], ['Cool', 6500]];

// ---------------- rendering ----------------

const app = document.getElementById('app')!;
const modalHost = document.getElementById('modal') as HTMLDialogElement;
const live = document.getElementById('live')!;

const protect = (el: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement) => {
  if (el instanceof HTMLInputElement && el.type === 'range') return state.dragging.has(el.dataset.key ?? '');
  if (el instanceof HTMLInputElement && (el.type === 'checkbox' || el.type === 'radio' || el.type === 'color')) return el.type === 'color' && state.dragging.has(el.dataset.key ?? '');
  return document.activeElement === el; // never fight the caret
};

function render(): void {
  const s = state.snap;
  if (!s) { app.innerHTML = '<p class="loading">Loading…</p>'; return; }
  if (state.selected && !s.devices.some((d) => d.id === state.selected)) state.selected = undefined;
  morph(app, shell(s), { protect });
  renderModal();
  paintVars(document.body);
  paintAudio(document.body);
  paintFloor(document.body);
}

/** CSP forbids inline style attributes, so colors/fills are applied through CSSOM. */
function paintVars(root: ParentNode): void {
  root.querySelectorAll<HTMLElement>('[data-color]').forEach((el) => el.style.setProperty('--orb', el.dataset.color || 'transparent'));
  root.querySelectorAll<HTMLElement>('[data-look]').forEach((el) => { el.style.setProperty('--look', el.dataset.look!); if (el.dataset.level) el.style.setProperty('--level', el.dataset.level); });
  root.querySelectorAll<HTMLInputElement>('input[type=range]').forEach(fill);
}

function fill(el: HTMLInputElement): void {
  const min = Number(el.min), max = Number(el.max), v = Number(el.value);
  el.style.setProperty('--fill', `${max > min ? ((v - min) / (max - min)) * 100 : 0}%`);
}

function shell(s: AppSnapshot): string {
  const nav: Array<[View, string, string]> = [['lights', 'Lights', 'bulb'], ['floor', 'Floor plan', 'map'], ['scenes', 'Scenes', 'scenes'], ['sync', 'Sync', 'screen'], ['automations', 'Automations', 'clock'], ['activity', 'Activity', 'clock'], ['settings', 'Settings', 'gear'], ['about', 'About', 'info']];
  return `
  <nav class="sidebar" aria-label="Sections">
    <div class="brand"><img class="brand-icon" src="luma.png" alt="" width="28" height="28"><span>Luma</span>${s.demo ? '<span class="badge">Demo</span>' : ''}</div>
    <ul>${nav.map(([v, label, ic]) => `<li><button class="nav ${state.view === v ? 'active' : ''}" data-action="view" data-view="${v}" ${state.view === v ? 'aria-current="page"' : ''}>${icon(ic)}<span>${label}</span>${v === 'activity' && s.activity.some(a => a.isError) ? `<span class="badge">${s.activity.filter(a => a.isError).length}</span>` : ''}</button></li>`).join('')}</ul>
    <div class="sidebar-foot">${s.demo ? 'Sample lights only. Nothing real is controlled and changes are not saved.' : s.cloudConnected ? 'Govee cloud connected' : 'Cloud not connected'}</div>
  </nav>
  <main class="content" id="main">
    ${s.notice ? `<div class="notice" role="alert"><span>${esc(s.notice)}</span><button class="ghost" data-action="dismiss-notice" aria-label="Dismiss message">${icon('close')}</button></div>` : ''}
    ${syncBanner(s)}
    ${state.status ? `<div class="status ${state.status.error ? 'error' : ''}">${esc(state.status.text)}</div>` : ''}
    ${state.view === 'lights' ? lightsView(s) : state.view === 'floor' ? floorView(s) : state.view === 'bluetooth' ? bluetoothView(s) : state.view === 'scenes' ? scenesView(s) : state.view === 'sync' ? (syncMode(s) === 'audio' ? audioSyncView(s) : syncView(s)) : state.view === 'automations' ? automationsView(s) : state.view === 'settings' ? settingsView(s) : state.view === 'activity' ? activityView(s) : aboutView(s)}
  </main>`;
}

function pendingLabel(s: AppSnapshot, id: string): string {
  const p = s.pending[id];
  if (!p?.length) return '';
  return p.some((x) => x.phase !== 'confirming') ? 'Updating…' : 'Waiting for light…';
}

function lightsView(s: AppSnapshot): string {
  const filtered = filterLights(s.devices, state.search);
  const rooms = [...new Set(filtered.map((d) => d.room))].sort((a, b) => (a === 'Unassigned' ? 1 : b === 'Unassigned' ? -1 : a.localeCompare(b)));
  const lights = s.devices.filter(isLight);
  const on = lights.filter((d) => d.power === true).length;
  const selected = s.devices.find((d) => d.id === state.selected);
  // The lights that are on wash the top of the page in their colors.
  const glow = lights.map(orbColor).filter((c): c is string => !!c).slice(0, 8);
  return `
  ${glow.length ? `<div class="ambient" data-look="${esc(glow.length > 1 ? glow.join(', ') : `${glow[0]}, ${glow[0]}`)}" aria-hidden="true"></div>` : ''}
  <div class="lights-layout ${selected ? 'has-inspector' : ''}">
    <section class="pane" aria-labelledby="lights-title">
      <header class="toolbar">
        <div><h1 id="lights-title">Lights</h1><p class="sub">${s.devices.length ? `${on} of ${lights.length} light${lights.length === 1 ? '' : 's'} on${lights.length < s.devices.length ? ` · ${s.devices.length - lights.length} other device${s.devices.length - lights.length === 1 ? '' : 's'}` : ''}` : 'No lights yet'}</p></div>
        <div class="actions">
          <button data-action="all" data-on="1" ${s.devices.length ? '' : 'disabled'}>All on</button>
          <button data-action="all" data-on="0" ${s.devices.length ? '' : 'disabled'}>All off</button>
          <button data-action="discover" ${s.demo || s.scanning ? 'disabled' : ''} title="${s.demo ? 'Disabled in demo' : 'Find lights with LAN Control enabled'}">${icon('wifi')}${s.scanning ? 'Scanning…' : 'Discover'}</button>
        </div>
      </header>
      ${s.devices.length ? `<label class="block" for="light-search">Search lights</label><input id="light-search" type="search" data-action="search" value="${esc(state.search)}" placeholder="Search lights">${filtered.length === 0 ? '<p class="hint">No matching lights.</p>' : ''}` : ''}
      ${s.devices.length === 0 ? `<div class="empty"><span class="orb large" data-color="#ffb347"></span><h2>Bring your lights in</h2><p>Enable <strong>LAN Control</strong> for each light in the Govee Home app and choose Discover. No API key needed for lights on this Wi-Fi.</p><p>A free Govee API key adds cloud actions and controls your lights when you’re not on the same network.</p><button class="primary" data-action="view" data-view="settings">Connect API key</button> <button data-action="link" data-link="apikey">Get a free API key</button> <button data-action="explore-demo">Explore Demo</button></div>` : ''}
      ${rooms.map((room) => {
        const devices = filtered.filter((d) => d.room === room);
        // Room actions never switch appliances (native roomHeader).
        const roomLights = s.devices.filter((d) => isLight(d) && d.room === room), switchable = roomLights.filter((d) => supports(d, 'powerSwitch'));
        const roomOn = roomLights.filter((d) => d.power === true).length;
        return `<section class="room" aria-label="${esc(room)}">
          <div class="room-head"><h2>${esc(room)} <span class="sub">${roomOn} of ${roomLights.length} on</span></h2><div class="room-actions"><label class="room-toggle ${roomOn ? 'on' : ''}"><input type="checkbox" role="switch" class="switch" data-action="room-power" data-room="${esc(room)}" ${roomOn ? 'checked' : ''} ${switchable.length ? '' : 'disabled'} aria-label="All lights in ${esc(room)}">${roomOn ? 'On' : 'Off'}</label></div></div>
          ${roomAdjust(s, room)}
          <div class="cards">${devices.map((d) => card(s, d)).join('')}</div>
        </section>`;
      }).join('')}
    </section>
    ${selected ? inspector(s, selected) : ''}
  </div>`;
}

/** Room brightness and white, clamped per light in main. Lights only; hidden when no light in the room supports either. */
function roomAdjust(s: AppSnapshot, room: string): string {
  const lights = s.devices.filter((d) => isLight(d) && d.room === room);
  const dimmable = lights.filter((d) => supports(d, 'brightness')), white = lights.filter((d) => supports(d, 'colorTemperatureK'));
  if (dimmable.length + white.length === 0) return '';
  const known = dimmable.map((d) => d.brightness).filter((b): b is number => typeof b === 'number' && b > 0);
  const level = known.length ? Math.round(known.reduce((a, b) => a + b, 0) / known.length) : 50;
  return `<details class="room-adjust"><summary>Adjust ${esc(room)}</summary>
    ${dimmable.length ? `${slider(`room|${room}|brightness`, 'Room brightness', level, [1, 100], '%')}
      <div class="presets" aria-label="${esc(room)} brightness">${[10, 25, 50, 75, 100].map((v) => `<button class="chip" data-action="room-brightness" data-room="${esc(room)}" data-value="${v}">${v}%</button>`).join('')}</div>` : ''}
    ${white.length ? `<div class="presets" aria-label="${esc(room)} white">${WHITE_PRESETS.map(([name, k]) => `<button class="chip" data-action="room-white" data-room="${esc(room)}" data-value="${k}"><span class="orb tiny" data-color="${kelvinToHex(k)}"></span>${name}</button>`).join('')}</div>` : ''}
    <p class="hint">Each light is clamped to its own range. Appliances and sensors are never included.</p>
  </details>`;
}

function goveeHomeSection(s: AppSnapshot): string {
  const g = s.goveeHome;
  const head = `<section class="card-block" aria-labelledby="gh-title"><h2 id="gh-title">Govee Home account <span class="optional">(optional, read-only)</span></h2>
    <p class="sub">Reads your Govee Home rooms, DreamView groups and automations. Luma never changes anything in your Govee account.</p>`;
  if (!g.available) return `${head}<p class="hint">${s.demo ? 'Disabled in demo mode.' : 'Needs secure storage (Windows DPAPI or a Linux keyring) to keep the session.'}</p></section>`;
  if (!g.signedIn) {
    return `${head}<form class="stack" data-form="govee-signin">
        <div class="row"><label for="gh-email">Email</label><input id="gh-email" name="email" type="email" autocomplete="username" maxlength="254" ${g.busy ? 'disabled' : ''}></div>
        <div class="row"><label for="gh-password">Password</label><input id="gh-password" name="password" type="password" autocomplete="current-password" maxlength="256" ${g.busy ? 'disabled' : ''}></div>
        ${g.awaitingCode ? `<div class="row"><label for="gh-code">Code from Govee’s email</label><input id="gh-code" name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="10" ${g.busy ? 'disabled' : ''}></div>` : ''}
        <button class="primary" type="submit" ${g.busy ? 'disabled' : ''}>${g.busy ? 'Signing in…' : g.awaitingCode ? 'Finish sign-in' : 'Sign in'}</button>
      </form>
      <p class="hint">Your password goes only to app2.govee.com and is never saved; the session is stored encrypted. Govee may email a code the first time.</p></section>`;
  }
  const plan = g.plan;
  if (plan && g.importedAt && state.goveeRooms?.importedAt !== g.importedAt) {
    state.goveeRooms = { importedAt: g.importedAt, ids: new Set(plan.changes.filter((c) => c.currentRoom === 'Unassigned').map((c) => c.deviceID)) };
  }
  const nameOf = (id?: string) => s.devices.find((d) => d.id.toLowerCase() === id?.toLowerCase())?.name;
  const time = (t: { hour: number; minute: number }) => `${String(t.hour).padStart(2, '0')}:${String(t.minute).padStart(2, '0')}`;
  return `${head}
    <div class="actions"><button data-action="gh-import" ${g.busy ? 'disabled' : ''}>${g.busy ? 'Reading…' : g.importedAt ? 'Read again' : 'Read Govee Home'}</button><button class="ghost danger" data-action="gh-signout">Sign out</button></div>
    ${g.importedAt ? `<p class="hint">Read ${relativeTime(g.importedAt)}.${g.unavailable.length ? ` Couldn’t read ${esc(g.unavailable.join(' or '))}.` : ''}</p>` : ''}
    ${plan ? `<h3>Rooms</h3>${plan.changes.length ? `<ul class="plain">${plan.changes.map((c) => `<li><label><input type="checkbox" data-action="gh-room" data-id="${esc(c.deviceID)}" ${state.goveeRooms?.ids.has(c.deviceID) ? 'checked' : ''}> ${esc(c.name)}: ${esc(c.currentRoom)} → <strong>${esc(c.goveeRoom)}</strong></label></li>`).join('')}</ul>
      <button data-action="gh-apply" ${state.goveeRooms?.ids.size ? '' : 'disabled'}>Apply selected rooms</button>` : '<p class="sub">Rooms already match Govee Home.</p>'}
      <p class="hint">${plan.unchanged} unchanged · ${plan.withoutRoom} without a room · ${plan.notInLuma} not connected to Luma. Lights you moved in Luma aren’t preselected.</p>` : ''}
    ${g.groups.length ? `<h3>Groups</h3><ul class="plain">${g.groups.map((gr) => `<li><strong>${esc(gr.name)}</strong>${gr.isDreamView ? ' <span class="badge">DreamView</span>' : ''} · ${gr.enabled ? 'enabled' : 'disabled'}${gr.reportedLightCount !== undefined ? ` · Govee reports ${gr.reportedLightCount} light${gr.reportedLightCount === 1 ? '' : 's'}` : ''}${gr.mainDevice ? ` · main light ${esc(nameOf(gr.mainDevice) ?? gr.mainSKU ?? 'not in Luma')}` : ''}</li>`).join('')}</ul>
      <p class="hint">Member lights and screen areas aren’t in any readable Govee API yet, so they can’t be shown or edited here.</p>` : ''}
    ${g.automations.length ? `<h3>Automations</h3><ul class="plain">${g.automations.map((a) => `<li><strong>${esc(a.name)}</strong> · ${a.enabled ? 'enabled' : 'disabled'}${a.times.length ? ` · ${a.times.map(time).join(', ')}${a.repeatDays.length === 7 ? ' every day' : ''}` : ''}${a.targets.length ? ` · ${esc(a.targets.map((t) => t.name).join(', '))}` : ''}</li>`).join('')}</ul>
      <p class="hint">Read-only. ${g.conflicts.length ? `${g.conflicts.length} possible conflict${g.conflicts.length === 1 ? '' : 's'} with your Luma schedules (shown under Automations).` : 'No conflicts with your Luma schedules.'}</p>` : ''}
  </section>`;
}

function readingsList(s: AppSnapshot, d: LightDevice): string {
  const list = s.readings[d.id] ?? [];
  if (!list.length) return '';
  return `<dl class="facts readings" aria-label="Readings">${list.map((r) => `<dt>${esc(r.label)}</dt><dd>${esc(r.text)}</dd>`).join('')}</dl><p class="hint">Read ${relativeTime(list[0]!.readAt)} from Govee cloud. Use Refresh state to read again.</p>`;
}

function dreamViewBlock(s: AppSnapshot, d: LightDevice): string {
  const cap = capOf(d, 'dreamViewToggle');
  if (!cap) return '';
  const status = d.dreamView === undefined ? 'State unknown (refresh to read it)' : d.dreamView ? 'Running' : 'Off';
  const ready = s.cloudConnected || d.isDemo;
  return `<section class="effect" aria-label="DreamView"><h3>DreamView</h3>
    <p class="sub">TV sync with the group you set up in Govee Home · ${esc(status)}</p>
    <div class="actions"><button class="primary" data-action="dreamview" data-id="${esc(d.id)}" data-on="1" ${ready ? '' : 'disabled'}>Start</button><button data-action="dreamview" data-id="${esc(d.id)}" data-on="0" ${ready ? '' : 'disabled'}>Stop</button></div>
    <button data-action="dv-movie" data-id="${esc(d.id)}" ${ready ? '' : 'disabled'} title="Save a scene that turns this light on, then starts DreamView sync">Save Movie scene</button>
    <p class="hint">${ready ? 'Movie or Game, All or Part, and saturation are set in Govee Home; the cloud API only starts and stops sync. Govee accepting a command doesn\'t confirm the lights are syncing.' : 'Connect Govee cloud to start or stop DreamView.'}${supports(d, 'movieMode') ? ' Movie mode under Effects is this light\'s own video effect, not DreamView, and choosing it may stop a running group.' : ''}</p>
    ${dreamViewPartners(s, d)}
  </section>`;
}

function dreamViewValue(d: LightDevice, on: boolean): JSONValue {
  const named = enumOptions(capOf(d, 'dreamViewToggle')?.parameters).find((o) => o.name.toLowerCase() === (on ? 'on' : 'off'));
  return named?.value ?? (on ? 1 : 0);
}

function painters(d: LightDevice): SegmentSchema[] {
  return SEGMENT_INSTANCES.map((i) => segmentSchema(capOf(d, i))).filter((x): x is SegmentSchema => !!x);
}

function painter(d: LightDevice, schema: SegmentSchema): Painter {
  const key = `${d.id}|${schema.instance}`;
  let p = state.paint.get(key);
  if (!p) { p = { values: new Map(), selected: new Set(), color: 0xffb347, level: Math.min(schema.valueRange[1], Math.max(schema.valueRange[0], 60)) }; state.paint.set(key, p); }
  return p;
}

function painterView(d: LightDevice): string {
  const schemas = painters(d);
  if (!schemas.length) return '';
  const schema = schemas.find((x) => x.instance === state.painterInstance.get(d.id)) ?? schemas[0]!;
  const p = painter(d, schema), isColor = schema.valueField === 'rgb';
  let commands = 0, problem = '';
  try { commands = paintCommands(schema, p.values).length; } catch (error) { problem = error instanceof Error ? error.message : String(error); }
  const shade = (v: number) => (isColor ? hex(v) : hex(((Math.round(0xff * v / Math.max(1, schema.valueRange[1])) & 0xff) * 0x010100) | 0x30));
  return `<section class="effect painter" aria-label="Segment painter"><h3>Segment painter</h3>
    ${schemas.length > 1 ? `<div class="segmented" role="radiogroup" aria-label="Paint">${schemas.map((x) => `<button role="radio" aria-checked="${x.instance === schema.instance}" data-action="paint-mode" data-id="${esc(d.id)}" data-instance="${esc(x.instance)}">${x.valueField === 'rgb' ? 'Color' : 'Brightness'}</button>`).join('')}</div>` : ''}
    <div class="segment-grid painter-grid">${schema.indexes.map((i) => { const v = p.values.get(i); return `<button class="seg paint ${v === undefined ? '' : 'painted'}" aria-pressed="${p.selected.has(i)}" data-action="paint-seg" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" data-index="${i}" ${v === undefined ? '' : `data-color="${shade(v)}"`} aria-label="Segment ${i + 1}${v === undefined ? '' : isColor ? `, ${hex(v)}` : `, ${v}%`}">${i + 1}</button>`; }).join('')}</div>
    <div class="actions wrap">
      <button class="ghost" data-action="paint-select" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" data-which="all">Select all</button>
      <button class="ghost" data-action="paint-select" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" data-which="none">Select none</button>
      <button class="ghost" data-action="paint-select" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" data-which="alternate">Every other</button>
    </div>
    <div class="row">${isColor
      ? `<label for="paint-color-${esc(d.id)}">Paint color</label><input id="paint-color-${esc(d.id)}" type="color" data-action="paint-color" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" value="${hex(p.color)}">`
      : `<label for="paint-level-${esc(d.id)}">Segment brightness</label><input id="paint-level-${esc(d.id)}" type="number" min="${schema.valueRange[0]}" max="${schema.valueRange[1]}" step="1" data-action="paint-level" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" value="${p.level}">`}
      <button data-action="paint-fill" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" ${p.selected.size ? '' : 'disabled'}>Paint selected</button>
      ${isColor ? `<button class="ghost" data-action="paint-gradient" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" ${p.selected.size > 1 ? '' : 'disabled'}>Rainbow</button>` : ''}
    </div>
    <p class="sub">${p.values.size} of ${schema.indexes.length} segments painted · ${problem ? esc(problem) : `${commands} command${commands === 1 ? '' : 's'}`}</p>
    <div class="actions wrap">
      <button class="primary" data-action="paint-apply" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" ${p.values.size && !problem ? '' : 'disabled'}>Apply to light</button>
      <button data-action="paint-scene" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" ${p.values.size && !problem ? '' : 'disabled'}>Save as scene…</button>
      <button class="ghost" data-action="paint-clear" data-id="${esc(d.id)}" data-instance="${esc(schema.instance)}" ${p.values.size ? '' : 'disabled'}>Clear</button>
    </div>
    <p class="hint">Segments sharing a value are sent as one command, in segment order. Unpainted segments are left as they are.</p>
  </section>`;
}

function card(s: AppSnapshot, d: LightDevice): string {
  const pending = pendingLabel(s, d.id);
  const readings = s.readings[d.id] ?? [];
  const meta = d.online === false ? 'Offline' : !isLight(d) && readings.length ? readings.slice(0, 2).map((r) => r.text).join(' · ') : d.power === undefined ? (isLight(d) ? 'State unknown' : 'No readings yet') : d.power ? (supports(d, 'brightness') ? `${d.brightness ?? '–'}%` : 'On') : 'Off';
  const route = d.isDemo ? 'Demo' : d.ip ? 'LAN' : 'Cloud';
  const look = lookStops(d);
  return `<article class="card ${look ? 'lit' : ''} ${state.selected === d.id ? 'selected' : ''} ${d.online === false ? 'offline' : ''}" data-key="${esc(d.id)}" ${look ? `data-color="${orbColor(d)}" data-look="${esc(look)}" data-level="${d.brightness ?? 100}"` : ''}>
    <button class="card-main" data-action="select" data-id="${esc(d.id)}" aria-pressed="${state.selected === d.id}" aria-label="${esc(d.name)}, ${esc(meta)}${pending ? `, ${pending}` : ''}">
      ${orb(d)}
      <span class="card-text"><span class="name">${esc(d.name)}</span><span class="meta">${esc(meta)} · ${route}${pending ? ` · <em>${pending}</em>` : ''}</span></span>
    </button>
    ${supports(d, 'powerSwitch') ? `<input type="checkbox" role="switch" class="switch" data-action="power" data-id="${esc(d.id)}" aria-label="${esc(d.name)} power" ${d.power ? 'checked' : ''}>` : ''}
  </article>`;
}

/** A light's orb; one with a palette shows all its colors and turns slowly. */
function orb(d: LightDevice, size = ''): string {
  const multi = orbColor(d) && d.palette && d.palette.length > 1;
  return `<span class="orb ${size} ${multi ? 'multi' : ''}" data-color="${orbColor(d) ?? ''}" ${multi ? `data-look="${esc(lookStops(d)!)}"` : ''}></span>`;
}

function slider(key: string, label: string, value: number, [min, max]: [number, number], unit: string, extra = ''): string {
  const v = Math.min(max, Math.max(min, value));
  return `<div class="slider-row">
    <label for="sl-${esc(key)}">${label}</label><output data-readout="${esc(key)}">${Math.round(v)}${unit}</output>
    <input id="sl-${esc(key)}" type="range" class="slider ${extra}" data-key="${esc(key)}" data-unit="${unit}" min="${min}" max="${max}" step="any" value="${v}" aria-valuetext="${Math.round(v)}${unit}">
  </div>`;
}

function inspector(s: AppSnapshot, d: LightDevice): string {
  const tabs: Array<[Tab, string]> = [['light', 'Light'], ['effects', 'Effects'], ['details', 'Details']];
  const look = lookStops(d);
  return `<aside class="inspector ${look ? 'lit' : ''}" aria-label="${esc(d.name)} inspector" ${look ? `data-color="${orbColor(d)}" data-look="${esc(look)}"` : ''}>
    <header class="inspector-head">
      ${orb(d, 'large')}
      <div><h2>${esc(d.name)}</h2><p class="sub">${esc(d.room)} · ${esc(d.sku)}${pendingLabel(s, d.id) ? ` · <em>${pendingLabel(s, d.id)}</em>` : ''}</p></div>
      <button class="ghost close" data-action="deselect" aria-label="Close inspector">${icon('close')}</button>
    </header>
    <div class="tabs" role="tablist">${tabs.map(([t, label]) => `<button role="tab" id="tab-${t}" aria-controls="panel-${t}" aria-selected="${state.tab === t}" tabindex="${state.tab === t ? 0 : -1}" data-action="tab" data-tab="${t}">${label}</button>`).join('')}</div>
    <div class="panel" role="tabpanel" id="panel-${state.tab}" aria-labelledby="tab-${state.tab}">
      ${state.tab === 'light' ? lightTab(d) : state.tab === 'effects' ? effectsTab(s, d) : detailsTab(s, d)}
    </div>
  </aside>`;
}

function lightTab(d: LightDevice): string {
  const hasColor = supports(d, 'colorRgb'), hasWhite = supports(d, 'colorTemperatureK');
  const mode = state.colorMode.get(d.id) ?? (d.colorTemperature && d.colorTemperature > 0 ? 'white' : hasColor ? 'color' : 'white');
  const [wlo, whi] = whiteRange(d);
  const offline = d.online === false ? '<p class="hint warn">This light reports offline. Values shown are its last known state.</p>' : '';
  return `${offline}
    ${readingsList(state.snap!, d)}
    ${dreamViewBlock(state.snap!, d)}
    ${supports(d, 'powerSwitch') ? `<div class="row"><label for="pw-${esc(d.id)}">Power</label><input id="pw-${esc(d.id)}" type="checkbox" role="switch" class="switch" data-action="power" data-id="${esc(d.id)}" ${d.power ? 'checked' : ''}></div>` : ''}
    ${supports(d, 'brightness') ? slider(`${d.id}|brightness`, 'Brightness', d.brightness ?? 50, brightnessRange(d), '%', 'look') : ''}
    ${hasColor || hasWhite ? `<div class="segmented" role="radiogroup" aria-label="Color mode">
        ${hasColor ? `<button role="radio" aria-checked="${mode === 'color'}" data-action="mode" data-id="${esc(d.id)}" data-mode="color">Color</button>` : ''}
        ${hasWhite ? `<button role="radio" aria-checked="${mode === 'white'}" data-action="mode" data-id="${esc(d.id)}" data-mode="white">White</button>` : ''}
      </div>` : ''}
    ${mode === 'color' && hasColor ? `
      <div class="row"><label for="color-${esc(d.id)}">Color</label><input id="color-${esc(d.id)}" type="color" data-key="${esc(d.id)}|colorRgb" value="${hex(d.rgb ?? 0xffffff)}"></div>
      <div class="presets" aria-label="Color presets">${RGB_PRESETS.map(([name, v]) => `<button class="swatch ${d.colorTemperature === 0 && d.rgb === v ? 'on' : ''}" data-action="preset" data-id="${esc(d.id)}" data-instance="colorRgb" data-value="${v}" aria-label="${name}" title="${name}"><span class="orb tiny" data-color="${hex(v)}"></span></button>`).join('')}</div>` : ''}
    ${mode === 'white' && hasWhite ? `
      ${slider(`${d.id}|colorTemperatureK`, 'White temperature', d.colorTemperature && d.colorTemperature > 0 ? d.colorTemperature : Math.round((wlo + whi) / 2), [wlo, whi], ' K', 'kelvin')}
      <div class="presets" aria-label="White presets">${WHITE_PRESETS.filter(([, k]) => k >= wlo && k <= whi).map(([name, k]) => `<button class="chip ${d.colorTemperature === k ? 'on' : ''}" data-action="preset" data-id="${esc(d.id)}" data-instance="colorTemperatureK" data-value="${k}"><span class="orb tiny" data-color="${kelvinToHex(k)}"></span>${name}</button>`).join('')}</div>` : ''}
    <button data-action="save-look" data-id="${esc(d.id)}">Save this look as a scene</button>
    <p class="hint">Changes show immediately and are confirmed from the light's reported state.</p>`;
}

function enumOptions(params: JSONValue | undefined): Array<{ name: string; value: JSONValue }> {
  const options = isObj(params) && Array.isArray(params.options) ? params.options : [];
  return options.filter(isObj).map((o, i) => ({ name: typeof o.name === 'string' ? o.name : `Option ${i + 1}`, value: o.value ?? null }));
}

function dataType(params: JSONValue | undefined): string {
  return isObj(params) && typeof params.dataType === 'string' ? params.dataType.toUpperCase() : '';
}

function effectsTab(s: AppSnapshot, d: LightDevice): string {
  const caps = effectCapabilities(d);
  const loaders = `<div class="actions wrap"><button data-action="load-effects" data-id="${esc(d.id)}" data-diy="0" ${s.cloudConnected || d.isDemo ? '' : 'disabled'}>Load effects</button><button data-action="load-effects" data-id="${esc(d.id)}" data-diy="1" ${s.cloudConnected || d.isDemo ? '' : 'disabled'}>Load DIY effects</button></div>`;
  const forms = caps.map((c) => `<section class="effect" aria-label="${esc(friendly(c.instance))}"><h3>${esc(friendly(c.instance))}</h3>${effectForm(d, c)}</section>`).join('');
  const all = d.capabilities.filter((c) => !c.type.endsWith('.online') && !c.type.endsWith('.event'));
  const adv = state.advanced.get(d.id) ?? { instance: all[0]?.instance ?? '', text: '' };
  return `${caps.length === 0 ? `<p class="hint">${d.ip && !s.cloudConnected ? 'LAN lights support power, brightness, color and white. Connect Govee cloud to load model effects.' : 'This light advertises no extra effects. Try Load effects.'}</p>` : ''}
    ${advertisesScenes(d) ? sceneList(s, [d], d.name, `light|${d.id}`) : ''}${loaders}${painterView(d)}${forms}
    <details class="advanced"><summary>Advanced</summary>
      <p class="hint">Send a raw JSON value for any capability this light advertises. Values are validated against its schema before sending.</p>
      <div class="row"><label for="adv-inst">Capability</label><select id="adv-inst" data-action="adv-instance" data-id="${esc(d.id)}">${all.map((c) => `<option value="${esc(c.instance)}" ${c.instance === adv.instance ? 'selected' : ''}>${esc(friendly(c.instance))} (${esc(c.instance)})</option>`).join('')}</select></div>
      <label for="adv-json" class="block">Value (JSON)</label>
      <textarea id="adv-json" class="code" rows="5" spellcheck="false" data-action="adv-text" data-id="${esc(d.id)}">${esc(adv.text || exampleValue(capOf(d, adv.instance)))}</textarea>
      <button data-action="adv-send" data-id="${esc(d.id)}">Send</button>
    </details>`;
}

function exampleValue(c: Capability | undefined): string {
  if (!c) return '';
  const p = c.parameters;
  switch (dataType(p)) {
    case 'ENUM': return JSON.stringify(enumOptions(p)[0]?.value ?? 1);
    case 'INTEGER': return String(rangeOf(p, [0, 100])[0]);
    case 'STRUCT': return JSON.stringify(Object.fromEntries((isObj(p) && Array.isArray(p.fields) ? p.fields : []).filter(isObj).map((f) => [String(f.fieldName), dataType(f) === 'ARRAY' ? [0] : dataType(f) === 'ENUM' ? enumOptions(f)[0]?.value ?? 0 : 0])), null, 2);
    default: return '1';
  }
}

const draftKey = (d: LightDevice, c: Capability) => `${d.id}|${c.instance}`;

function effectForm(d: LightDevice, c: Capability): string {
  const p = c.parameters, key = draftKey(d, c);
  const type = dataType(p);
  const options = enumOptions(p);
  const isToggle = c.type.endsWith('.toggle') || (type === 'ENUM' && options.length === 2 && options.every((o) => o.value === 0 || o.value === 1));
  if (isToggle) {
    return `<div class="row"><label for="tg-${esc(key)}">${esc(friendly(c.instance))}</label><input id="tg-${esc(key)}" type="checkbox" role="switch" class="switch" data-action="effect-toggle" data-id="${esc(d.id)}" data-instance="${esc(c.instance)}" ${state.toggles.value(key) ? 'checked' : ''}></div>`;
  }
  if (type === 'ENUM') {
    if (options.length === 0) return '<p class="hint">No options yet. Use Load effects.</p>';
    const current = state.effectDrafts.get(key);
    const index = Math.max(0, options.findIndex((o) => JSON.stringify(o.value) === JSON.stringify(current)));
    return `<div class="row"><select aria-label="${esc(friendly(c.instance))}" data-action="effect-enum" data-key="${esc(key)}">${options.map((o, i) => `<option value="${i}" ${i === index ? 'selected' : ''}>${esc(o.name)}</option>`).join('')}</select>
      <button data-action="effect-apply" data-id="${esc(d.id)}" data-instance="${esc(c.instance)}">Apply</button></div>`;
  }
  if (type === 'INTEGER') {
    const range = rangeOf(p, [0, 100]);
    const v = typeof state.effectDrafts.get(key) === 'number' ? state.effectDrafts.get(key) as number : range[0];
    return slider(`${d.id}|${c.instance}`, esc(friendly(c.instance)), v, range, '', 'effect');
  }
  if (type === 'STRUCT') {
    const fields = (isObj(p) && Array.isArray(p.fields) ? p.fields : []).filter(isObj);
    const draft = isObj(state.effectDrafts.get(key)) ? state.effectDrafts.get(key) as { [k: string]: JSONValue } : {};
    return `<div class="struct">${fields.map((f) => structField(d, c, f, draft)).join('')}
      <button data-action="effect-apply" data-id="${esc(d.id)}" data-instance="${esc(c.instance)}">Apply</button></div>`;
  }
  return '<p class="hint">Use Advanced to send a value for this capability.</p>';
}

function segmentIndexes(f: { [k: string]: JSONValue }): JSONValue[] {
  const opts = enumOptions(f);
  if (opts.length) return opts.map((o) => o.value);
  const [lo, hi] = rangeOf({ range: f.elementRange ?? null }, [0, 14]);
  return Array.from({ length: Math.min(64, hi - lo + 1) }, (_, i) => lo + i);
}

function structField(d: LightDevice, c: Capability, f: { [k: string]: JSONValue }, draft: { [k: string]: JSONValue }): string {
  const name = String(f.fieldName ?? '');
  const key = `${draftKey(d, c)}|${name}`;
  const label = esc(friendly(name)) + (f.required === true ? '' : ' <span class="optional">(optional)</span>');
  const value = draft[name];
  const type = dataType(f);
  if (type === 'ARRAY') {
    const chosen = Array.isArray(value) ? value : [];
    const items = segmentIndexes(f);
    return `<fieldset class="segments"><legend>${label}</legend><div class="segment-grid">${items.map((item) => `<button class="seg" aria-pressed="${chosen.some((x) => JSON.stringify(x) === JSON.stringify(item))}" data-action="seg" data-key="${esc(key)}" data-value="${esc(JSON.stringify(item))}">${esc(typeof item === 'number' ? item + 1 : JSON.stringify(item))}</button>`).join('')}</div>
      <div class="actions"><button class="ghost" data-action="seg-all" data-key="${esc(key)}" data-values="${esc(JSON.stringify(items))}">All</button><button class="ghost" data-action="seg-none" data-key="${esc(key)}">None</button></div></fieldset>`;
  }
  if (type === 'ENUM') {
    const opts = enumOptions(f);
    const index = opts.findIndex((o) => JSON.stringify(o.value) === JSON.stringify(value));
    return `<div class="row"><label for="f-${esc(key)}">${label}</label><select id="f-${esc(key)}" data-action="field-enum" data-key="${esc(key)}"><option value="" ${index < 0 ? 'selected' : ''}>Choose…</option>${opts.map((o, i) => `<option value="${i}" ${i === index ? 'selected' : ''}>${esc(o.name)}</option>`).join('')}</select></div>`;
  }
  if (type === 'INTEGER') {
    const [lo, hi] = rangeOf(f, [0, 100]);
    if (isColorField(f)) {
      return `<div class="row"><label for="f-${esc(key)}">${label}</label><input id="f-${esc(key)}" type="color" data-action="field-color" data-key="${esc(key)}" value="${hex(typeof value === 'number' ? value : 0xffffff)}"></div>`;
    }
    return `<div class="row"><label for="f-${esc(key)}">${label}</label><input id="f-${esc(key)}" type="number" inputmode="numeric" min="${lo}" max="${hi}" step="1" data-action="field-int" data-key="${esc(key)}" value="${typeof value === 'number' ? value : ''}" placeholder="${lo}–${hi}"></div>`;
  }
  return `<div class="row"><label for="f-${esc(key)}">${label}</label><input id="f-${esc(key)}" type="text" class="code" data-action="field-json" data-key="${esc(key)}" value="${esc(value === undefined ? '' : JSON.stringify(value))}" placeholder="JSON"></div>`;
}

function detailsTab(s: AppSnapshot, d: LightDevice): string {
  const rooms = [...new Set(s.devices.map((x) => x.room))];
  return `<form class="details" data-form="details" data-id="${esc(d.id)}">
      <div class="row"><label for="dn">Name</label><input id="dn" name="name" maxlength="64" value="${esc(d.name)}"></div>
      <div class="row"><label for="dr">Room</label><input id="dr" name="room" maxlength="40" list="room-list" value="${esc(d.room)}"><datalist id="room-list">${rooms.map((r) => `<option value="${esc(r)}"></option>`).join('')}</datalist></div>
      <button type="submit">Save</button>
    </form>
    <dl class="facts">
      <dt>Model</dt><dd>${esc(d.sku)}</dd>
      ${isLight(d) ? '' : `<dt>Type</dt><dd>${esc(friendly((d.deviceType ?? '').replace('devices.types.', '')))} · excluded from All on/off, rooms, webhooks and Screen Sync</dd>`}
      ${s.goveeHome.firmware[d.id] ? `<dt>Firmware</dt><dd>${esc(s.goveeHome.firmware[d.id])} (from Govee Home; updates happen in Govee Home)</dd>` : ''}
      ${d.customName ? `<dt>Govee name</dt><dd>Renamed in Luma; the name survives cloud refreshes</dd>` : ''}
      <dt>Device ID</dt><dd class="code">${esc(d.id)} <button data-action="copy-device-id" data-id="${esc(d.id)}">Copy</button></dd>
      ${d.ip ? `<dt>Network address</dt><dd>${esc(d.ip)}</dd>` : ''}
      ${d.lastSeen ? `<dt>Last seen</dt><dd>${esc(new Date(d.lastSeen).toLocaleString())}</dd>` : ''}
      <dt>Control</dt><dd>${d.isDemo ? 'Demo (simulated)' : d.ip ? `LAN at ${esc(d.ip)} for basic controls; cloud for effects` : 'Govee cloud'}</dd>
      <dt>Status</dt><dd>${d.online === false ? 'Offline' : d.online ? 'Online' : 'Unknown'}${d.lastSeen ? ` · seen ${relativeTime(d.lastSeen)}` : ''}</dd>
      <dt>Capabilities</dt><dd>${d.capabilities.length ? d.capabilities.map((c) => esc(friendly(c.instance))).join(', ') : 'Basic LAN controls'}</dd>
    </dl>
    ${readingsList(s, d)}
    <button data-action="refresh" data-id="${esc(d.id)}">${icon('refresh')}Refresh state</button>`;
}

function scenesView(s: AppSnapshot): string {
  return `<section class="pane" aria-labelledby="scenes-title">
    <header class="toolbar">
      <div><h1 id="scenes-title">Scenes</h1><p class="sub">Ordered steps across your lights. One scene runs at a time.</p></div>
      <div class="actions">
        ${s.runningSceneID ? `<button data-action="stop-scene">${icon('stop')}Stop</button>` : ''}
        ${s.restorePoint ? `<button data-action="restore-before" ${s.runningSceneID ? 'disabled' : ''} title="${esc(s.restorePoint)}">Restore lights</button>` : ''}
        <button data-action="import-scene">Import…</button>
        <button data-action="new-scene" ${s.devices.length ? '' : 'disabled'}>${icon('plus')}New scene</button>
        <button class="primary" data-action="capture" ${s.devices.length ? '' : 'disabled'}>Capture current lights</button>
      </div>
    </header>
    ${s.scenes.length === 0 ? '<div class="empty"><h2>No scenes yet</h2><p>Set your lights the way you like, then choose Capture current lights.</p></div>' : ''}
    <div class="scene-grid">${s.scenes.map((scene) => `<article class="scene-card ${s.runningSceneID === scene.id ? 'running' : ''}" data-key="${esc(scene.id)}">
      <span class="scene-icon ${sceneStops(scene.steps) ? 'lit' : ''}" ${sceneStops(scene.steps) ? `data-look="${esc(sceneStops(scene.steps)!)}"` : ''}>${icon(scene.icon)}</span>
      <div class="scene-text"><h2>${esc(scene.name)}</h2><p class="sub">${scene.steps.length} step${scene.steps.length === 1 ? '' : 's'}${s.runningSceneID === scene.id ? ' · Running…' : ''}</p></div>
      <div class="actions">
        <button class="primary" data-action="run-scene" data-id="${esc(scene.id)}" ${s.runningSceneID ? 'disabled' : ''} aria-label="Run ${esc(scene.name)}">${icon('play')}Run</button>
        <button data-action="edit-scene" data-id="${esc(scene.id)}" aria-label="Edit ${esc(scene.name)}">Edit</button>
        <button data-action="duplicate-scene" data-id="${esc(scene.id)}">Duplicate</button>
        <button class="ghost" data-action="export-scene" data-id="${esc(scene.id)}" aria-label="Export ${esc(scene.name)}">Export</button>
        <button class="ghost danger" data-action="delete-scene" data-id="${esc(scene.id)}" aria-label="Delete ${esc(scene.name)}">${icon('trash')}</button>
      </div>
    </article>`).join('')}</div>
    ${sceneBrowser(s)}
    <p class="hint">Stopping a scene does not undo commands it already sent. Restore lights puts power, brightness, color and white back to how they were before the last scene you ran here or from the tray (schedules and webhooks don't count; effects and segments aren't undone).</p>
  </section>`;
}

function automationsView(s: AppSnapshot): string {
  const w = s.webhook;
  const disabled = !w.available;
  return `<section class="pane" aria-labelledby="auto-title">
    <header class="toolbar"><div><h1 id="auto-title">Automations</h1><p class="sub">${esc(scheduleSyncSubtitle(s.scheduleSync))}</p></div>
      <div class="actions"><button class="primary" data-action="add-schedule" ${s.scenes.length ? '' : 'disabled'}>${icon('plus')}Add schedule</button></div></header>
    ${s.schedules.length === 0 ? `<p class="hint">${s.scenes.length ? 'No schedules yet.' : 'Save a scene first, then schedule it.'}</p>` : ''}
    <ul class="schedules">${s.schedules.map((sch) => scheduleRow(s, sch)).join('')}</ul>
    ${scheduleSyncBlock(s.scheduleSync)}

    ${doorbellView(s)}

    <section class="card-block" aria-labelledby="hook-title">
      <h2 id="hook-title">Webhook server</h2>
      <p class="sub">${esc(w.status)}</p>
      ${disabled ? `<p class="hint">${s.demo ? 'The webhook server is disabled in demo mode.' : 'Secure storage is unavailable, so the server token cannot be stored.'}</p>` : ''}
      <div class="row"><label for="hook-port">Port</label><input id="hook-port" type="number" min="1024" max="65535" step="1" value="${esc(state.portDraft ?? String(w.port))}" data-action="port" ${disabled || w.running ? 'disabled' : ''}></div>
      <div class="row"><label for="hook-lan">Allow other devices on my network</label><input id="hook-lan" type="checkbox" role="switch" class="switch" data-action="lan" ${w.allowLAN ? 'checked' : ''} ${disabled || w.running ? 'disabled' : ''}></div>
      ${w.allowLAN ? '<p class="hint warn">LAN mode listens on all interfaces over HTTPS. Use only on a trusted network; never port-forward it. Your firewall may ask for permission.</p>' : '<p class="hint">Off by default: only apps on this PC (127.0.0.1) can call it.</p>'}
      <div class="actions">
        ${w.running ? `<button data-action="hook-stop">${icon('stop')}Stop server</button>` : `<button class="primary" data-action="hook-start" ${disabled ? 'disabled' : ''}>${icon('play')}Start server</button>`}
      </div>
      <p><code>https://127.0.0.1:${w.port}</code></p>
      ${w.fingerprint ? `<div class="row"><code>SHA-256 ${esc(w.fingerprint)}</code><button data-action="copy-fingerprint">Copy fingerprint</button><button data-action="export-certificate">Export Certificate…</button></div>` : ''}
      ${w.spkiPin ? `<div class="row"><code>${esc(w.spkiPin)}</code><button data-action="copy-spki-pin">Copy SPKI pin</button></div>` : ''}
      <p class="hint">Trust the exported certificate with <code>curl --cacert luma.pem</code>. LAN certificates cover current addresses and hostname.local; export the certificate and update pins again if they change. Never disable certificate checks.</p>
      <div class="row token"><span>Token</span><code aria-label="Token (masked)">${esc(w.maskedToken ?? 'Created when the server first starts')}</code>
        <button data-action="copy-token" ${disabled || !w.maskedToken ? 'disabled' : ''}>Copy</button><button data-action="rotate-token" ${disabled ? 'disabled' : ''}>Rotate</button></div>
      <details><summary>How to call it</summary>
        <p class="hint">Every request needs <code>Authorization: Bearer &lt;token&gt;</code>. POST bodies are JSON (max 64 KiB). Accepted actions return 202 with a run ID.</p>
        <pre class="code">curl --cacert luma.pem -X POST https://127.0.0.1:${w.port}/v1/actions ^
  -H "Authorization: Bearer %LUMA_TOKEN%" ^
  -H "Content-Type: application/json" ^
  -d "{\\"target\\":\\"all\\",\\"power\\":true,\\"brightness\\":40}"</pre>
        ${w.spkiPin ? `<pre class="code">curl --cacert luma.pem --pinnedpubkey '${esc(w.spkiPin)}' https://127.0.0.1:${w.port}/health -H "Authorization: Bearer %LUMA_TOKEN%"</pre>` : ''}
        <p class="hint">Targets: <code>all</code>, an exact device ID, or <code>room:Living room</code>. Also: GET /health, /v1/devices, /v1/scenes, /v1/runs, /v1/runs/&lt;id&gt;; POST /v1/scenes/&lt;id&gt;/run and /v1/devices/&lt;id&gt;/commands.</p>
      </details>
    </section>

    <section class="card-block" aria-labelledby="runs-title"><h2 id="runs-title">Recent runs</h2>
      ${s.runs.length === 0 ? '<p class="hint">Nothing has run yet.</p>' : `<ul class="runs">${s.runs.slice(0, 20).map((r) => `<li><span class="pill ${r.status}">${r.status}</span><span>${esc(r.name)}</span><time>${new Date(r.startedAt).toLocaleTimeString()}</time>${r.error ? `<span class="err">${esc(r.error)}</span>` : ''}</li>`).join('')}</ul>`}
      <p class="hint">Completed means every command was submitted; lights confirm separately.</p>
    </section>
  </section>`;
}

function scheduleRow(s: AppSnapshot, sch: SceneSchedule): string {
  const next = nextOccurrence(sch);
  const time = `${String(sch.hour).padStart(2, '0')}:${String(sch.minute).padStart(2, '0')}`;
  return `<li class="schedule" data-key="${esc(sch.id)}">
    <select aria-label="Scene" data-action="sch-scene" data-id="${esc(sch.id)}">${s.scenes.map((sc) => `<option value="${esc(sc.id)}" ${sc.id === sch.sceneID ? 'selected' : ''}>${esc(sc.name)}</option>`).join('')}</select>
    <input type="time" aria-label="Time" value="${time}" data-action="sch-time" data-id="${esc(sch.id)}">
    <div class="actions"><button data-action="sch-preset" data-id="${esc(sch.id)}" data-preset="daily">Every Day</button><button data-action="sch-preset" data-id="${esc(sch.id)}" data-preset="weekdays">Weekdays</button><button data-action="sch-preset" data-id="${esc(sch.id)}" data-preset="weekends">Weekends</button></div>
    <div class="weekdays" role="group" aria-label="Days">${WEEKDAYS.map((day, i) => `<button class="day" aria-pressed="${sch.weekdays.includes(i + 1)}" data-action="sch-day" data-id="${esc(sch.id)}" data-day="${i + 1}">${day}</button>`).join('')}</div>
    <input type="checkbox" role="switch" class="switch" aria-label="Enabled" data-action="sch-enabled" data-id="${esc(sch.id)}" ${sch.enabled ? 'checked' : ''}>
    <span class="next">${next ? `Next: ${next.toLocaleString(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' })}` : 'Not scheduled'}</span>
    ${s.goveeHome.conflicts.filter((c) => c.scheduleID === sch.id).map((c) => `<span class="hint warn">Possible conflict: Govee Home automation “${esc(c.automation)}” also changes ${esc(c.light)} at this time.</span>`).join('')}
    ${scheduleSyncLine(s.scheduleSync, sch)}
    <button class="ghost danger" data-action="sch-delete" data-id="${esc(sch.id)}" aria-label="Delete schedule">${icon('trash')}</button>
  </li>`;
}

function settingsView(s: AppSnapshot): string {
  return `<section class="pane" aria-labelledby="settings-title">
    <header class="toolbar"><div><h1 id="settings-title">Settings</h1></div></header>
    <section class="card-block"><h2>Appearance</h2><label for="appearance">Theme</label> <select id="appearance" data-action="appearance">${(['system', 'light', 'dark'] as const).map(v => `<option value="${v}" ${s.appearance === v ? 'selected' : ''}>${v[0]!.toUpperCase() + v.slice(1)}</option>`).join('')}</select></section>
    <section class="card-block" aria-labelledby="acct-title"><h2 id="acct-title">Govee account</h2>
      ${s.demo ? '<p class="hint">Demo mode: account connection is disabled. Start Luma without --demo on Windows or Linux to connect.</p>' : ''}
      ${!s.demo && !s.platformSecretsAvailable ? '<p class="hint warn">Secure storage (Windows DPAPI, or GNOME Keyring/KWallet on Linux) is unavailable, so Luma will not store an API key.</p>' : ''}
      <p class="sub">${s.cloudConnected ? 'Connected.' : s.hasSavedKey ? 'A saved key is stored encrypted for your OS account.' : 'LAN Control works without a key for lights on the same Wi-Fi. You need a free Govee API key for cloud actions and to control lights when you’re not on their network.'}</p>
      <form class="row" data-form="connect">
        <label for="api-key">API key</label>
        <input id="api-key" type="password" autocomplete="off" spellcheck="false" maxlength="256" placeholder="Govee API key" value="" ${s.demo || s.busy ? 'disabled' : ''}>
        <button class="primary" type="submit" ${s.demo || s.busy ? 'disabled' : ''}>${s.busy ? 'Connecting…' : 'Connect'}</button>
      </form>
      <div class="actions">
        ${s.hasSavedKey && !s.cloudConnected ? `<button data-action="reconnect" ${s.busy ? 'disabled' : ''}>Reconnect with saved key</button>` : ''}
        ${s.hasSavedKey || s.cloudConnected ? '<button class="danger" data-action="disconnect">Disconnect and remove key</button>' : ''}
        <button class="ghost" data-action="link" data-link="apikey">How to get an API key</button>
      </div>
      ${s.cloudConnected || s.hasSavedKey ? '' : '<p class="hint">No key yet? In the Govee Home app, open Profile › Settings › Apply for API Key. Govee emails it to you, usually within minutes.</p>'}
      <p class="hint">Your key is sent only to openapi.api.govee.com and stored with Windows DPAPI or your Linux keyring, never in plain text. Use your existing key: generating a new one disables older keys used by other apps.</p>
    </section>
    ${goveeHomeSection(s)}
    <section class="card-block" aria-labelledby="ble-title"><h2 id="ble-title">Bluetooth lights</h2>
      <p class="sub">Control supported Govee lights near this PC without Wi-Fi or the cloud, and read DreamView members from a Govee Home capture.</p>
      <button data-action="view" data-view="bluetooth">Bluetooth…</button>
    </section>
    <section class="card-block" aria-labelledby="backup-title"><h2 id="backup-title">Backup and restore</h2>
      <p class="sub">Scenes, schedules, light names and rooms in one file. It opens in Luma on Mac, iPhone and iPad too.</p>
      <div class="actions"><button data-action="backup-export" ${s.demo ? 'disabled' : ''}>Export backup…</button><button data-action="backup-import" ${s.demo || !s.canSave ? 'disabled' : ''}>Restore from backup…</button></div>
      <p class="hint">Never includes API keys, tokens, network addresses or webhook settings. Restoring replaces your scenes and schedules; names and rooms apply only to lights already connected here. Your current home is saved as home-before-restore.json first.</p>
    </section>
    <section class="card-block" aria-labelledby="compat-title"><h2 id="compat-title">Compatibility report</h2>
      <p class="sub">Copies what Luma can do with each of your models, for an issue report.</p>
      <button data-action="compat-copy">Copy compatibility report</button>
      <p class="hint">Lists models, feature names and connection paths only: no light names, rooms, device IDs or addresses.</p>
    </section>
    <section class="card-block" aria-labelledby="lan-title"><h2 id="lan-title">Local network (LAN)</h2>
      <p class="sub">Compatible lights with LAN Control enabled can be controlled directly for power, brightness, color and white (2000–9000 K).</p>
      <div class="actions"><button data-action="discover" ${s.demo || s.scanning ? 'disabled' : ''}>${icon('wifi')}${s.scanning ? 'Scanning…' : 'Discover lights'}</button><button class="ghost" data-action="link" data-link="lan-guide">How to enable LAN Control</button></div>
      <p class="hint">Luma listens on UDP port 4002. Your firewall may ask for permission; another Govee tool running on this PC can receive the replies instead.</p>
    </section>
  </section>`;
}

function activityView(s: AppSnapshot): string {
  const entries = s.activity.filter(a => !state.problemsOnly || a.isError);
  return `<section class="pane"><header class="toolbar"><h1>Activity</h1><button data-action="clear-activity" ${s.activity.length ? '' : 'disabled'}>Clear</button></header>
    <div class="segmented" role="group" aria-label="Activity filter"><button data-action="activity-filter" data-problems="0" aria-pressed="${!state.problemsOnly}">All</button><button data-action="activity-filter" data-problems="1" aria-pressed="${state.problemsOnly}">Problems</button></div>
    <ul class="activity">${entries.map(a => `<li class="${a.isError ? 'err' : ''}"><time>${esc(new Date(a.time).toLocaleString())}</time><span>${esc(a.message)}</span></li>`).join('') || '<li>No activity.</li>'}</ul></section>`;
}

function aboutView(s: AppSnapshot): string {
  return `<section class="pane about" aria-labelledby="about-title">
    <span class="orb large" data-color="#ffb347"></span>
    <h1 id="about-title">Luma</h1>
    <p class="sub">Version ${esc(s.version)}</p>
    <p>Luma is an open-source project built by Design X Develop LLC.</p>
    <p>Provided as is, without warranty.</p>
    <div class="actions center">
      <button data-action="link" data-link="repo">github.com/designxdevelop/luma</button>
      <button data-action="link" data-link="issues">Report an issue</button>
    </div>
    <p class="hint">MIT License · Copyright (c) 2026 Design X Develop LLC</p>
    <p class="hint">Luma uses Govee's public developer API and documented LAN protocol. It is not affiliated with Govee.</p>
  </section>`;
}

// ---------------- Screen Sync ----------------

const REGION_GROUPS: Array<[string, Array<[SyncRegion, string]>]> = [
  ['Whole picture and thirds', [['full', 'Whole picture'], ['left', 'Left third'], ['right', 'Right third'], ['top', 'Top third'], ['bottom', 'Bottom third']]],
  ['Edges', [['edgeLeft', 'Left edge'], ['edgeRight', 'Right edge'], ['edgeTop', 'Top edge'], ['edgeBottom', 'Bottom edge']]],
  ['Corners', [['cornerTopLeft', 'Top-left corner'], ['cornerTopRight', 'Top-right corner'], ['cornerBottomLeft', 'Bottom-left corner'], ['cornerBottomRight', 'Bottom-right corner']]],
  ['Half edges', [
    ['edgeLeftUpper', 'Left edge, upper half'], ['edgeLeftLower', 'Left edge, lower half'], ['edgeRightUpper', 'Right edge, upper half'], ['edgeRightLower', 'Right edge, lower half'],
    ['edgeTopLeft', 'Top edge, left half'], ['edgeTopRight', 'Top edge, right half'], ['edgeBottomLeft', 'Bottom edge, left half'], ['edgeBottomRight', 'Bottom edge, right half'],
  ]],
];
const REGION_LABELS = REGION_GROUPS.flatMap(([, regions]) => regions);
const SYNC_SLIDERS: Array<{ key: keyof SyncSettings; label: string; unit: string; range: [number, number]; scale: number; decimals?: boolean }> = [
  { key: 'smoothing', label: 'Smoothing', unit: '%', range: [0, 95], scale: 100 },
  { key: 'threshold', label: 'Change threshold', unit: '%', range: [0.5, 20], scale: 100, decimals: true },
  { key: 'brightnessCap', label: 'Brightness cap', unit: '%', range: [1, 100], scale: 1 },
  { key: 'updateHz', label: 'Update speed', unit: ' per second', range: [0.5, 10], scale: 1, decimals: true },
  { key: 'edgeDepth', label: 'Edge depth', unit: '%', range: [5, 33], scale: 100 },
];

/** Persistent capture indicator, shown on every view while a session exists. */
function syncBanner(s: AppSnapshot): string {
  const y = s.sync;
  if (y.phase === 'idle') return '';
  if (y.kind === 'audio') return audioBanner(s, state.view === 'sync');
  const live = y.phase === 'running' || y.phase === 'starting';
  const what = y.synthetic ? 'synthetic demo frames' : `“${esc(y.sourceName ?? 'your screen')}”`;
  const text = y.phase === 'stopping' ? 'Screen Sync is stopping…' : y.phase === 'paused' ? `Screen Sync is paused · ${what}` : y.phase === 'starting' ? `Screen Sync is starting · ${what}` : `Screen Sync is live · sampling ${what} on this PC`;
  return `<div class="sync-live ${live ? 'on' : ''}" role="status">
    <span class="dot" aria-hidden="true"></span><span class="sync-live-text">${text}</span>
    <span class="actions">
      ${state.view !== 'sync' ? '<button class="ghost" data-action="view" data-view="sync">Open</button>' : ''}
      ${y.phase === 'paused' ? `<button data-action="sync-resume">${icon('play')}Resume</button>` : live ? `<button data-action="sync-pause">${icon('pause')}Pause</button>` : ''}
      <button class="danger-solid" data-action="sync-stop" ${y.phase === 'stopping' ? 'disabled' : ''}>${icon('stop')}Stop</button>
    </span>
  </div>`;
}

function syncSlider(s: AppSnapshot, d: (typeof SYNC_SLIDERS)[number]): string {
  const key = `sync|${d.key}`, v = Math.min(d.range[1], Math.max(d.range[0], (s.sync.settings[d.key] as number) * d.scale));
  const text = `${d.decimals ? v.toFixed(1) : Math.round(v)}${d.unit}`;
  return `<div class="slider-row">
    <label for="sl-${key}">${d.label}</label><output data-readout="${key}">${text}</output>
    <input id="sl-${key}" type="range" class="slider" data-key="${key}" data-unit="${d.unit}" ${d.decimals ? 'data-decimals="1"' : ''} min="${d.range[0]}" max="${d.range[1]}" step="any" value="${v}" aria-valuetext="${text}">
  </div>`;
}

function syncView(s: AppSnapshot): string {
  const y = s.sync, idle = y.phase === 'idle';
  const eligible = y.eligibility.filter((e) => e.eligible), blocked = y.eligibility.filter((e) => !e.eligible);
  const canStart = idle && !!state.syncSource && eligible.some(e => state.syncLights.has(e.id));

  const platform = y.synthetic
    ? '<p class="hint">Demo: Screen Sync uses generated synthetic frames. Nothing on this computer is captured.</p>'
    : y.captureSupported ? '' : '<p class="hint warn">Screen capture is available on Windows and Linux.</p>';
  return `<section class="pane sync" aria-labelledby="sync-title">
    <header class="toolbar">
      <div><h1 id="sync-title">Screen Sync</h1><p class="sub">Match LAN lights to a screen or window you choose.</p></div>
      <div class="actions">
        ${modeSwitch(s)}
        ${idle ? `<button class="primary" data-action="sync-start" ${canStart ? '' : 'disabled'}>${icon('play')}Start</button>` : ''}
      </div>
    </header>
    ${platform}
    <section class="card-block" aria-labelledby="sync-source-title">
      <h2 id="sync-source-title">Source</h2>
      ${idle ? `<div class="actions"><button data-action="sync-sources" ${y.captureSupported || y.synthetic ? '' : 'disabled'}>${icon('screen')}${state.syncSources ? 'Refresh list' : 'Choose screen or window…'}</button></div>
        ${state.syncSources ? (state.syncSources.length ? `<div class="source-list" role="radiogroup" aria-label="Screens and windows">${state.syncSources.map((src) => `<label class="choice"><input type="radio" name="sync-source" data-action="sync-source" value="${esc(src.key)}" ${state.syncSource === src.key ? 'checked' : ''}><span>${icon(src.kind === 'screen' ? 'screen' : 'scenes')}${esc(src.name)}</span></label>`).join('')}</div>` : '<p class="hint">No screens or windows were found.</p>') : ''}`
        : `<p>${y.synthetic ? 'Synthetic demo frames' : esc(y.sourceName ?? '')}</p><p class="hint">Stop Screen Sync to change the source or lights.</p>`}
      <p class="hint">Frames are analyzed on this PC, at low resolution, and are never saved, uploaded or logged. Colors are an SDR approximation; HDR content can look different on your lights.</p>
    </section>
    <section class="card-block" aria-labelledby="sync-lights-title">
      <h2 id="sync-lights-title">Lights</h2>
      ${idle ? `${eligible.length ? `<ul class="sync-lights">${eligible.map((e) => `<li>
          <label class="choice"><input type="checkbox" data-action="sync-light" data-id="${esc(e.id)}" ${state.syncLights.has(e.id) ? 'checked' : ''}><span>${esc(e.name)}</span></label>
          <select data-action="sync-region" data-id="${esc(e.id)}" aria-label="${esc(e.name)} screen area">${REGION_GROUPS.map(([group, regions]) => `<optgroup label="${group}">${regions.map(([r, label]) => `<option value="${r}" ${(state.syncRegions.get(e.id) ?? 'full') === r ? 'selected' : ''}>${label}</option>`).join('')}</optgroup>`).join('')}</select>
        </li>`).join('')}</ul>` : '<p class="hint">No light can stream right now.</p>'}
        ${blocked.length ? `<details class="advanced"><summary>Unavailable lights (${blocked.length})</summary><ul class="sync-blocked">${blocked.map((e) => `<li><span>${esc(e.name)}</span><span class="sub">${esc(e.reason ?? '')}</span></li>`).join('')}</ul></details>` : ''}
        <p class="hint">Only lights that are on and reachable with Govee LAN Control can stream; Screen Sync never uses the cloud. It does not turn lights on.</p>`
      : `<ul class="sync-lights">${y.lights.map((l) => `<li>
          <span class="orb small" data-color="${l.requestedRGB !== undefined ? hex(l.requestedRGB) : ''}"></span>
          <span class="sync-light-text"><span>${esc(l.name)}</span><span class="sub">${esc(REGION_LABELS.find(([r]) => r === l.region)?.[1] ?? '')} · ${l.status === 'excluded' ? 'Manual control: left Screen Sync' : l.requestedBrightness !== undefined ? `Requested ${l.requestedBrightness}% · preview, unconfirmed` : 'Waiting for frames'}</span></span>
        </li>`).join('')}</ul>
        <p class="hint">Swatches preview what Screen Sync is requesting over LAN, not confirmed light state. Changing a light by hand removes it from the stream.</p>`}
    </section>
    <section class="card-block" aria-labelledby="sync-tune-title">
      <h2 id="sync-tune-title">Response</h2>
      ${SYNC_SLIDERS.map((d) => syncSlider(s, d)).join('')}
      <p class="hint">Each light gets at most ${y.settings.updateHz.toFixed(1)} updates per second over LAN. Edge depth sets how far edges, corners and half edges reach into the picture.</p>
      <div class="row"><span>Colors</span>
        <div class="segmented" role="radiogroup" aria-label="Colors">
          <button role="radio" aria-checked="${!y.settings.vivid}" data-action="sync-vivid" data-value="0">Average</button>
          <button role="radio" aria-checked="${y.settings.vivid}" data-action="sync-vivid" data-value="1">Vivid</button>
        </div>
      </div>
      <p class="hint">Vivid favors colorful parts of the picture over gray, white and text, so lights stay colorful.</p>
      <div class="row"><span>When I stop</span>
        <div class="segmented" role="radiogroup" aria-label="When I stop">
          <button role="radio" aria-checked="${!y.settings.restore}" data-action="sync-restore" data-value="0">Leave lights as they are</button>
          <button role="radio" aria-checked="${y.settings.restore}" data-action="sync-restore" data-value="1">Restore previous state</button>
        </div>
      </div>
      <p class="hint">Restore sends each light's last confirmed brightness and color from before Screen Sync, over LAN only. Lights you changed by hand are not restored. Automatic stops (window hidden, lock, sleep, display change, errors) leave lights as they are.</p>
    </section>
    ${!idle || y.stats.frames ? `<section class="card-block" aria-labelledby="sync-stats-title"><h2 id="sync-stats-title">Session</h2>
      <dl class="stats"><div><dt>Frames analyzed</dt><dd>${y.stats.frames}</dd></div><div><dt>Frames skipped</dt><dd>${y.stats.dropped}</dd></div><div><dt>Updates sent</dt><dd>${y.stats.sent}</dd></div><div><dt>Replaced before sending</dt><dd>${y.stats.superseded}</dd></div><div><dt>Send errors</dt><dd>${y.stats.errors}</dd></div></dl>
    </section>` : ''}
    ${idle && y.lastStop ? `<p class="hint">Last session: ${esc(y.lastStop)}</p>` : ''}
  </section>`;
}

function commitSyncSetting(key: string, value: number): void {
  const d = SYNC_SLIDERS.find((x) => x.key === key);
  if (!d || !Number.isFinite(value)) return;
  const v = Math.min(d.range[1], Math.max(d.range[0], value)) / d.scale;
  void act(() => luma.syncSettings({ [d.key]: d.decimals ? Math.round(v * 1000) / 1000 : Math.round(v * 100) / 100 }));
}

/** Keeps the local frame pump in step with main's session state. */
function followSync(snap: AppSnapshot): void {
  const y = snap.sync;
  if (!pump.live) return;
  if (y.generation > pump.generation! || y.phase === 'idle' || y.phase === 'stopping') pump.stop();
  else if (y.phase === 'paused') pump.pause();
}

document.addEventListener('click', (event) => {
  const target = (event.target as Element).closest<HTMLElement>('[data-action^="sync-"]');
  if (!target || target instanceof HTMLInputElement || target instanceof HTMLSelectElement) return;
  switch (target.dataset.action) {
    case 'sync-sources':
      void act(async () => { state.syncSources = await luma.syncSources(); state.syncSource = undefined; render(); });
      break;
    case 'sync-start': {
      const key = state.syncSource, lights = [...state.syncLights].filter(([id]) => state.snap?.sync.eligibility.some(e => e.id === id && e.eligible)).map(([id, region]) => ({ id, region }));
      if (!key || lights.length === 0) break;
      luma.syncStart(key, lights).then((grant) => {
        void pump.start(grant, state.snap?.demo === true); // first, while the click's activation is fresh
        state.syncSources = undefined;
        state.syncSource = undefined;
        render();
      }, (error: unknown) => { state.syncSources = undefined; state.syncSource = undefined; flash(errorText(error), true); });
      break;
    }
    case 'sync-pause': pump.pause(); void act(() => luma.syncPause()); break;
    case 'sync-resume': {
      const token = pump.token;
      if (!token) break;
      void act(async () => { await luma.syncResume(token); pump.resume(token); });
      break;
    }
    case 'sync-stop': pump.stop(); void act(() => luma.syncStop()); break;
    case 'sync-restore': void act(() => luma.syncSettings({ restore: target.dataset.value === '1' })); break;
    case 'sync-vivid': void act(() => luma.syncSettings({ vivid: target.dataset.value === '1' })); break;
  }
});

document.addEventListener('change', (event) => {
  const el = event.target as HTMLInputElement & HTMLSelectElement;
  switch (el.dataset.action) {
    case 'sync-source': state.syncSource = el.value; render(); break;
    case 'sync-light': {
      const region = document.querySelector<HTMLSelectElement>(`select[data-action="sync-region"][data-id="${CSS.escape(el.dataset.id!)}"]`)?.value as SyncRegion | undefined;
      state.syncRegions.set(el.dataset.id!, region ?? 'full');
      if (el.checked) state.syncLights.set(el.dataset.id!, region ?? 'full'); else state.syncLights.delete(el.dataset.id!);
      saveAssignments(); render();
      break;
    }
    case 'sync-region': {
      const id = el.dataset.id!;
      if (REGION_LABELS.some(([r]) => r === el.value)) { state.syncRegions.set(id, el.value as SyncRegion); if (state.syncLights.has(id)) state.syncLights.set(id, el.value as SyncRegion); saveAssignments(); }
      render();
      break;
    }
  }
});

function saveAssignments(): void { void act(() => luma.setSyncAssignments([...state.syncRegions].map(([id, region]) => ({ id, region, included: state.syncLights.has(id) })))); }

function errorText(error: unknown): string {
  return error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : String(error);
}

// ---------------- modal (scene editor, capture) ----------------

function renderModal(): void {
  const m = state.modal;
  if (!m) { if (modalHost.open) modalHost.close(); morph(modalHost, '', { protect }); return; }
  morph(modalHost, m.kind === 'editor' ? editorView(m) : captureView(m), { protect });
  if (!modalHost.open) {
    modalHost.showModal();
    modalHost.querySelector<HTMLElement>('[autofocus]')?.focus();
  }
  paintVars(modalHost);
}

function captureView(m: Capture): string {
  const devices = state.snap?.devices ?? [];
  return `<form class="sheet" data-form="capture" novalidate>
    <h2>Capture current lights</h2>
    <p class="sub">Saves each light's last confirmed power, brightness and color as scene steps.</p>
    <div class="row"><label for="cap-name">Name</label><input id="cap-name" autofocus maxlength="80" data-action="cap-name" value="${esc(m.name)}"></div>
    ${iconPicker(m.icon, 'cap-icon')}
    <fieldset class="checklist"><legend>Lights</legend>${devices.map((d) => `<label><input type="checkbox" data-action="cap-device" data-id="${esc(d.id)}" ${m.ids.includes(d.id) ? 'checked' : ''}><span class="orb tiny" data-color="${orbColor(d) ?? ''}"></span>${esc(d.name)} <span class="sub">${esc(d.room)}</span></label>`).join('')}</fieldset>
    ${m.error ? `<p class="error" role="alert">${esc(m.error)}</p>` : ''}
    <div class="actions end"><button type="button" data-action="modal-close">Cancel</button><button class="primary" type="submit">Save scene</button></div>
  </form>`;
}

function iconPicker(selected: string, action: string): string {
  return `<fieldset class="icons"><legend>Icon</legend>${SCENE_ICONS.map((name) => `<label class="icon-choice"><input type="radio" name="${action}" data-action="${action}" value="${name}" ${name === selected ? 'checked' : ''}>${icon(name, name)}</label>`).join('')}</fieldset>`;
}

function editorView(m: SceneEditor): string {
  const devices = state.snap?.devices ?? [];
  return `<form class="sheet wide" data-form="editor" novalidate>
    <header class="sheet-head"><h2>${m.isNew ? 'New scene' : 'Edit scene'}</h2>
      <div class="segmented" role="radiogroup" aria-label="Editor mode"><button type="button" role="radio" aria-checked="${!m.json}" data-action="ed-mode" data-mode="steps">Steps</button><button type="button" role="radio" aria-checked="${m.json}" data-action="ed-mode" data-mode="json">JSON</button></div>
    </header>
    ${m.json ? `<label class="block" for="ed-json">Scene JSON</label><textarea id="ed-json" class="code" rows="18" spellcheck="false" data-action="ed-json">${esc(m.jsonText)}</textarea>
      <p class="hint">The JSON is fully validated before you can return to steps or save.</p>` : `
    <div class="row"><label for="ed-name">Name</label><input id="ed-name" autofocus maxlength="80" data-action="ed-name" value="${esc(m.draft.name)}"></div>
    ${iconPicker(m.draft.icon, 'ed-icon')}
    <ol class="steps">${m.draft.steps.map((st, i) => stepRow(st, i, m.draft.steps.length, devices)).join('')}</ol>
    <button type="button" data-action="ed-add" ${devices.length ? '' : 'disabled'}>${icon('plus')}Add step</button>`}
    ${m.error ? `<p class="error" role="alert">${esc(m.error)}</p>` : ''}
    <div class="actions end"><button type="button" data-action="modal-close">Cancel</button><button class="primary" type="submit">Save scene</button></div>
  </form>`;
}

type StepKind = 'on' | 'off' | 'brightness' | 'color' | 'white' | 'advanced';
function stepKind(c: CapabilityCommand): StepKind {
  if (c.instance === 'powerSwitch') return c.value === 1 ? 'on' : 'off';
  if (c.instance === 'brightness') return 'brightness';
  if (c.instance === 'colorRgb') return 'color';
  if (c.instance === 'colorTemperatureK') return 'white';
  return 'advanced';
}

function stepRow(st: SceneStep, i: number, count: number, devices: LightDevice[]): string {
  const d = devices.find((x) => x.id === st.deviceID);
  const kind = stepKind(st.command);
  const kinds: Array<[StepKind, string, string]> = [['on', 'Turn on', 'powerSwitch'], ['off', 'Turn off', 'powerSwitch'], ['brightness', 'Brightness', 'brightness'], ['color', 'Color', 'colorRgb'], ['white', 'White', 'colorTemperatureK']];
  let valueControl = '';
  if (kind === 'brightness') {
    const [lo, hi] = brightnessRange(d);
    valueControl = `<input type="number" aria-label="Brightness percent" min="${lo}" max="${hi}" step="1" value="${esc(st.command.value)}" data-action="st-value" data-index="${i}">`;
  } else if (kind === 'color') {
    valueControl = `<input type="color" aria-label="Color" value="${hex(typeof st.command.value === 'number' ? st.command.value : 0xffffff)}" data-action="st-color" data-index="${i}">`;
  } else if (kind === 'white') {
    const [lo, hi] = whiteRange(d);
    valueControl = `<input type="number" aria-label="White temperature in Kelvin, ${lo} to ${hi}" min="${lo}" max="${hi}" step="1" value="${esc(st.command.value)}" data-action="st-value" data-index="${i}"><span class="unit">K</span>`;
  } else if (kind === 'advanced') {
    valueControl = `<span class="sub">${esc(describeCommand(st.command))} · edit in JSON</span>`;
  }
  return `<li class="step" data-key="${esc(st.id)}">
    <span class="step-n">${i + 1}</span>
    <select aria-label="Light for step ${i + 1}" data-action="st-device" data-index="${i}">${devices.map((x) => `<option value="${esc(x.id)}" ${x.id === st.deviceID ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}${d ? '' : `<option value="${esc(st.deviceID)}" selected>Missing light</option>`}</select>
    <select aria-label="Action for step ${i + 1}" data-action="st-kind" data-index="${i}" ${kind === 'advanced' ? 'disabled' : ''}>${kinds.filter(([, , inst]) => !d || supports(d, inst)).map(([k, label]) => `<option value="${k}" ${k === kind ? 'selected' : ''}>${label}</option>`).join('')}${kind === 'advanced' ? '<option selected>Advanced</option>' : ''}</select>
    <span class="step-value">${valueControl}</span>
    <label class="delay">Wait<input type="number" min="0" max="60000" step="1" value="${st.delayMilliseconds}" data-action="st-delay" data-index="${i}" aria-label="Delay before step ${i + 1} in milliseconds">ms</label>
    <span class="step-tools">
      <button type="button" class="ghost" data-action="st-up" data-index="${i}" ${i === 0 ? 'disabled' : ''} aria-label="Move step ${i + 1} up">${icon('up')}</button>
      <button type="button" class="ghost" data-action="st-down" data-index="${i}" ${i === count - 1 ? 'disabled' : ''} aria-label="Move step ${i + 1} down">${icon('down')}</button>
      <button type="button" class="ghost danger" data-action="st-remove" data-index="${i}" aria-label="Remove step ${i + 1}">${icon('trash')}</button>
    </span>
  </li>`;
}

// ---------------- actions ----------------

let statusTimer: number | undefined;
function flash(text: string, error = false): void {
  state.status = { text, error };
  live.textContent = text;
  clearTimeout(statusTimer);
  statusTimer = window.setTimeout(() => { state.status = undefined; render(); }, error ? 8000 : 3000);
  render();
}

async function act(work: () => Promise<unknown>, success?: string): Promise<void> {
  try { await work(); if (success) flash(success); }
  catch (error) { flash(error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : String(error), true); }
}

/** Controls: failures are reported by main (rollback + notice), so the renderer stays quiet. */
function control(id: string, command: CapabilityCommand): void {
  void luma.control(id, command).catch(() => {});
}

const device = (id: string | undefined) => state.snap?.devices.find((d) => d.id === id);

function commitSlider(el: HTMLInputElement): void {
  const [id, instance] = (el.dataset.key ?? '').split('|');
  if (id === 'sync' && instance) { commitSyncSetting(instance, Number(el.value)); return; }
  if (id === 'audio' && instance) { commitAudioSetting(instance, Number(el.value)); return; }
  if (id === 'room') { const parts = el.dataset.key!.split('|'); parts.pop(); const room = parts.slice(1).join('|'); void act(() => luma.roomAction(room, { brightness: Math.round(Number(el.value)) })); return; }
  const d = device(id);
  if (!d || !instance) return;
  const value = Math.round(Number(el.value));
  if (!Number.isFinite(value)) return;
  if (BASIC.includes(instance)) control(d.id, basicCommand(d, instance, value));
  else {
    const cap = capOf(d, instance);
    state.effectDrafts.set(`${d.id}|${instance}`, value);
    if (cap) control(d.id, { type: cap.type, instance, value });
  }
}

function readout(el: HTMLInputElement): void {
  const out = document.querySelector<HTMLOutputElement>(`output[data-readout="${CSS.escape(el.dataset.key ?? '')}"]`);
  const text = `${el.dataset.decimals ? Number(el.value).toFixed(1) : Math.round(Number(el.value))}${el.dataset.unit ?? ''}`;
  if (out) out.textContent = text;
  el.setAttribute('aria-valuetext', text);
  fill(el);
}

function sliderStep(el: HTMLInputElement, key: string): number | undefined {
  const min = Number(el.min), max = Number(el.max), span = max - min;
  const small = el.classList.contains('kelvin') ? 50 : el.dataset.decimals ? 0.1 : Math.max(1, Math.round(span / 100));
  const big = el.classList.contains('kelvin') ? 500 : el.dataset.decimals ? 0.5 : Math.max(small, Math.round(span / 10));
  const v = Number(el.value);
  switch (key) {
    case 'ArrowRight': case 'ArrowUp': return v + small;
    case 'ArrowLeft': case 'ArrowDown': return v - small;
    case 'PageUp': return v + big;
    case 'PageDown': return v - big;
    case 'Home': return min;
    case 'End': return max;
    default: return undefined;
  }
}

function setSlider(el: HTMLInputElement, v: number): void {
  el.value = String(Math.min(Number(el.max), Math.max(Number(el.min), el.dataset.decimals ? Math.round(v * 10) / 10 : Math.round(v))));
  readout(el);
  commitSlider(el);
}

function selectDevice(id: string | undefined, tab?: Tab): void {
  state.selected = id;
  if (tab) state.tab = tab;
  state.view = 'lights';
  render();
  if (id) document.querySelector<HTMLElement>('.inspector [role=tab][aria-selected=true]')?.focus();
}

function updateDraft(key: string, mutate: (draft: { [k: string]: JSONValue }) => void): void {
  const [id, instance] = key.split('|');
  const k = `${id}|${instance}`;
  const draft = isObj(state.effectDrafts.get(k)) ? { ...(state.effectDrafts.get(k) as { [k: string]: JSONValue }) } : {};
  mutate(draft);
  state.effectDrafts.set(k, draft);
}

/** Required color fields show white by default; send what is displayed. Optional fields stay omitted. */
function withDisplayedDefaults(cap: Capability, draft: JSONValue | undefined): JSONValue {
  const value = isObj(draft) ? { ...draft } : {};
  const fields = (isObj(cap.parameters) && Array.isArray(cap.parameters.fields) ? cap.parameters.fields : []).filter(isObj);
  for (const f of fields) {
    const name = String(f.fieldName ?? '');
    if (f.required !== true || value[name] !== undefined || !isColorField(f)) continue;
    const [lo, hi] = rangeOf(f, [0, 0xffffff]);
    value[name] = Math.min(hi, Math.max(lo, 0xffffff));
  }
  return value;
}

function isColorField(f: { [k: string]: JSONValue }): boolean {
  return dataType(f) === 'INTEGER' && /rgb|color/i.test(String(f.fieldName ?? '')) && rangeOf(f, [0, 100])[1] >= 0xffffff;
}

function fieldName(key: string): string { return key.split('|')[2] ?? ''; }

function editor(): SceneEditor | undefined { return state.modal?.kind === 'editor' ? state.modal : undefined; }

function defaultCommand(d: LightDevice | undefined, kind: StepKind): CapabilityCommand {
  switch (kind) {
    case 'on': return basicCommand(d, 'powerSwitch', 1);
    case 'off': return basicCommand(d, 'powerSwitch', 0);
    case 'brightness': return basicCommand(d, 'brightness', Math.min(brightnessRange(d)[1], 60));
    case 'color': return basicCommand(d, 'colorRgb', 0xffb347);
    default: { const [lo, hi] = whiteRange(d); return basicCommand(d, 'colorTemperatureK', Math.min(hi, Math.max(lo, 3000))); }
  }
}

async function openEditor(scene?: LightScene): Promise<void> {
  const draft: LightScene = scene ? structuredClone(scene) : { id: uuid(), name: '', icon: 'sparkles', steps: [] };
  state.modal = { kind: 'editor', draft, json: false, jsonText: '', isNew: !scene };
  render();
}

async function saveEditor(m: SceneEditor): Promise<void> {
  try {
    // JSON mode is validated in full before it replaces the structured draft.
    if (m.json) m.draft = await luma.validateSceneJSON(m.jsonText);
    await luma.saveScene({ ...m.draft, name: m.draft.name.trim() });
    state.modal = undefined;
    flash(`Saved ${m.draft.name.trim()}.`);
  } catch (error) {
    m.error = error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : String(error);
    render();
  }
}

document.addEventListener('click', (event) => {
  const target = (event.target as Element).closest<HTMLElement>('[data-action]');
  if (!target || target instanceof HTMLInputElement || target instanceof HTMLSelectElement || target instanceof HTMLTextAreaElement) return;
  const a = target.dataset.action!, id = target.dataset.id;
  const m = editor();
  switch (a) {
    case 'explore-demo': void act(() => luma.exploreDemo()); break;
    case 'ss': {
      const op = target.dataset.op!;
      const sch = state.snap?.schedules.find((x) => x.id === id);
      if (op === 'pause' && sch) {
        const until = new Date(); until.setDate(until.getDate() + Number(target.dataset.days)); if (target.dataset.days === '1') until.setHours(12, 0, 0, 0);
        void act(() => luma.saveSchedule({ ...sch, pausedUntil: until.getTime() }));
      } else if (op === 'resume' && sch) { const { pausedUntil: _, ...rest } = sch; void act(() => luma.saveSchedule(rest)); }
      else if (op === 'pair') void act(() => luma.scheduleSync('pair', (document.getElementById('ss-code') as HTMLInputElement | null)?.value ?? ''), 'Paired.');
      else if (op === 'copyCode') void act(() => luma.scheduleSync('copyCode', target.dataset.code), 'Pairing code copied.');
      else if (op === 'off') { if (confirm(state.snap?.scheduleSync.role === 'runner' && state.snap.scheduleSync.mayExecute ? 'Stop sharing? Paired devices will no longer see or change these schedules.' : 'Stop sharing? Schedules here are turned off so they don\'t also run on the other computer.')) void act(() => luma.scheduleSync('off')); }
      else if (op === 'takeOver') void act(async () => {
        try { await luma.scheduleSync('takeOver'); } catch (error) {
          if (!confirm(`${error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : String(error)}\n\nRun schedules here anyway? This computer keeps asking the old one to stop and runs nothing until it agrees, so no schedule runs twice.`)) return;
          await luma.scheduleSync('forceTakeOver');
        }
      });
      else void act(() => luma.scheduleSync(op as Parameters<LumaBridge['scheduleSync']>[0]));
      break;
    }
    case 'copy-device-id': void act(() => luma.copyDeviceID(id!), 'Device ID copied.'); break;
    case 'clear-activity': void act(() => luma.clearActivity()); break;
    case 'activity-filter': state.problemsOnly = target.dataset.problems === '1'; render(); break;
    case 'sch-preset': { const sch = state.snap?.schedules.find(x => x.id === id); if (sch) void act(() => luma.saveSchedule({ ...sch, weekdays: [...DAY_PRESETS[target.dataset.preset as keyof typeof DAY_PRESETS]] })); break; }
    case 'duplicate-scene': { const sc = state.snap?.scenes.find(x => x.id === id); if (sc) void act(() => luma.saveScene(duplicateScene(sc, uuid))); break; }
    case 'view': if (state.view === 'bluetooth' && target.dataset.view !== 'bluetooth') leaveBluetooth(); state.view = target.dataset.view as View; render(); document.getElementById('main')?.focus(); break;
    case 'dismiss-notice': void luma.dismissNotice(); break;
    case 'select': selectDevice(state.selected === id ? undefined : id); break;
    case 'deselect': selectDevice(undefined); break;
    case 'tab': state.tab = target.dataset.tab as Tab; render(); document.querySelector<HTMLElement>(`#tab-${state.tab}`)?.focus(); break;
    case 'all': for (const d of state.snap?.devices ?? []) if (isLight(d) && supports(d, 'powerSwitch')) control(d.id, basicCommand(d, 'powerSwitch', target.dataset.on === '1' ? 1 : 0)); break;
    case 'room-brightness': void act(() => luma.roomAction(target.dataset.room!, { brightness: Number(target.dataset.value) })); break;
    case 'dv-movie': { const d = device(id), cap = d && capOf(d, 'dreamViewToggle'); if (!d || !cap) break;
      const steps: SceneStep[] = [...(supports(d, 'powerSwitch') ? [{ id: uuid(), deviceID: d.id, command: basicCommand(d, 'powerSwitch', 1), delayMilliseconds: 0 }] : []),
        { id: uuid(), deviceID: d.id, command: { type: cap.type, instance: cap.instance, value: dreamViewValue(d, true) }, delayMilliseconds: 0 }];
      void act(() => luma.saveScene({ id: uuid(), name: `Movie · ${d.name}`.slice(0, 80), icon: 'film', steps }), 'Saved to Scenes.'); break; }
    case 'save-look': { const d = device(id); if (d) { state.modal = { kind: 'capture', name: `${d.name} look`.slice(0, 80), icon: 'sparkles', ids: [d.id] }; render(); } break; }
    case 'room-white': void act(() => luma.roomAction(target.dataset.room!, { kelvin: Number(target.dataset.value) })); break;
    case 'dreamview': { const d = device(id), cap = d && capOf(d, 'dreamViewToggle'); if (d && cap) void act(() => luma.control(d.id, { type: cap.type, instance: cap.instance, value: dreamViewValue(d, target.dataset.on === '1') }), target.dataset.on === '1' ? 'DreamView start sent.' : 'DreamView stop sent.'); break; }
    case 'restore-before': void act(() => luma.restoreBeforeScene(), 'Restoring lights.'); break;
    case 'backup-export': void act(() => luma.exportBackup()); break;
    case 'backup-import': if (confirm('Restore from a backup? Your scenes and schedules are replaced; your current home is saved as home-before-restore.json first.')) void act(async () => {
      const r = await luma.importBackup();
      if (r) flash(`Restored ${r.scenes} scene${r.scenes === 1 ? '' : 's'}, ${r.schedules} schedule${r.schedules === 1 ? '' : 's'} and ${r.lightsUpdated} light name${r.lightsUpdated === 1 ? '' : 's'}${r.lightsNotFound ? `; ${r.lightsNotFound} light${r.lightsNotFound === 1 ? ' isn’t' : 's aren’t'} connected here` : ''}${r.scenesWithMissingLights ? `; ${r.scenesWithMissingLights} scene${r.scenesWithMissingLights === 1 ? ' uses' : 's use'} missing lights` : ''}.`);
    }); break;
    case 'gh-import': void act(() => luma.goveeImport()); break;
    case 'gh-signout': if (confirm('Sign out of Govee Home and remove the saved session from this PC?')) void act(() => luma.goveeSignOut()); break;
    case 'gh-apply': if (state.goveeRooms) { const ids = [...state.goveeRooms.ids]; void act(() => luma.goveeApplyRooms(ids), 'Rooms imported.'); } break;
    case 'compat-copy': void act(() => luma.copyCompatibilityReport(), 'Compatibility report copied.'); break;
    case 'paint-mode': state.painterInstance.set(id!, target.dataset.instance!); render(); break;
    case 'paint-seg': case 'paint-select': case 'paint-fill': case 'paint-gradient': case 'paint-clear': case 'paint-apply': case 'paint-scene': {
      const d = device(id), schema = d && segmentSchema(capOf(d, target.dataset.instance!));
      if (!d || !schema) break;
      const p = painter(d, schema);
      if (a === 'paint-seg') { const i = Number(target.dataset.index); if (p.selected.has(i)) p.selected.delete(i); else p.selected.add(i); }
      if (a === 'paint-select') p.selected = new Set(target.dataset.which === 'all' ? schema.indexes : target.dataset.which === 'alternate' ? schema.indexes.filter((_, n) => n % 2 === 0) : []);
      if (a === 'paint-fill') for (const i of p.selected) p.values.set(i, schema.valueField === 'rgb' ? p.color : p.level);
      if (a === 'paint-gradient' && schema.valueField === 'rgb') { const picked = schema.indexes.filter((i) => p.selected.has(i)); picked.forEach((i, n) => p.values.set(i, hueToRGB(n / picked.length))); }
      if (a === 'paint-clear') { p.values.clear(); p.selected.clear(); }
      if (a === 'paint-apply' || a === 'paint-scene') {
        let commands: CapabilityCommand[];
        try { commands = paintCommands(schema, p.values); } catch (error) { flash(error instanceof Error ? error.message : String(error), true); break; }
        if (a === 'paint-apply') { void act(() => luma.controlBatch(d.id, commands), `Sent ${commands.length} segment command${commands.length === 1 ? '' : 's'}.`); break; }
        const steps: SceneStep[] = [...(supports(d, 'powerSwitch') ? [{ id: uuid(), deviceID: d.id, command: basicCommand(d, 'powerSwitch', 1), delayMilliseconds: 0 }] : []),
          ...commands.map((command) => ({ id: uuid(), deviceID: d.id, command, delayMilliseconds: 0 }))];
        state.modal = { kind: 'editor', draft: { id: uuid(), name: `${d.name} segments`.slice(0, 80), icon: 'sparkles', steps }, json: false, jsonText: '', isNew: true };
      }
      render();
      break;
    }
    case 'room': for (const d of state.snap?.devices ?? []) if (isLight(d) && d.room === target.dataset.room && supports(d, 'powerSwitch')) control(d.id, basicCommand(d, 'powerSwitch', target.dataset.on === '1' ? 1 : 0)); break;
    case 'discover': void act(() => luma.discover()); break;
    case 'mode': state.colorMode.set(id!, target.dataset.mode as 'color' | 'white'); render(); break;
    case 'preset': { const d = device(id); if (d) control(d.id, basicCommand(d, target.dataset.instance!, Number(target.dataset.value))); break; }
    case 'refresh': void act(() => luma.refresh(id!), 'Refresh requested.'); break;
    case 'load-effects': void act(() => luma.loadEffects(id!, target.dataset.diy === '1')); break;
    case 'effect-apply': {
      const d = device(id), cap = d && capOf(d, target.dataset.instance!);
      if (!d || !cap) break;
      const k = `${d.id}|${cap.instance}`;
      let value = state.effectDrafts.get(k);
      if (value === undefined && dataType(cap.parameters) === 'ENUM') value = enumOptions(cap.parameters)[0]?.value;
      if (dataType(cap.parameters) === 'STRUCT') value = withDisplayedDefaults(cap, value);
      if (value === undefined) { flash('Choose a value first.', true); break; }
      void act(() => luma.control(d.id, { type: cap.type, instance: cap.instance, value }), `${friendly(cap.instance)} sent.`);
      break;
    }
    case 'seg': updateDraft(target.dataset.key!, (draft) => {
      const name = fieldName(target.dataset.key!), item = JSON.parse(target.dataset.value!) as JSONValue;
      const list = Array.isArray(draft[name]) ? [...(draft[name] as JSONValue[])] : [];
      const at = list.findIndex((x) => JSON.stringify(x) === JSON.stringify(item));
      if (at >= 0) list.splice(at, 1); else list.push(item);
      draft[name] = list;
    }); render(); break;
    case 'seg-all': updateDraft(target.dataset.key!, (draft) => { draft[fieldName(target.dataset.key!)] = JSON.parse(target.dataset.values!) as JSONValue; }); render(); break;
    case 'seg-none': updateDraft(target.dataset.key!, (draft) => { draft[fieldName(target.dataset.key!)] = []; }); render(); break;
    case 'adv-send': {
      const d = device(id); if (!d) break;
      const adv = state.advanced.get(d.id) ?? { instance: d.capabilities[0]?.instance ?? '', text: '' };
      const cap = capOf(d, adv.instance);
      const text = adv.text || exampleValue(cap);
      let value: JSONValue;
      try { value = JSON.parse(text) as JSONValue; } catch { flash('The value is not valid JSON.', true); break; }
      if (!cap) { flash('Choose a capability.', true); break; }
      void act(() => luma.control(d.id, { type: cap.type, instance: cap.instance, value }), `${friendly(cap.instance)} sent.`);
      break;
    }
    case 'reconnect': void act(() => luma.reconnect()); break;
    case 'disconnect': if (confirm('Disconnect Govee cloud and remove the saved API key from this PC?')) void act(() => luma.disconnect()); break;
    case 'link': void luma.openExternal(target.dataset.link as 'repo'); break;
    case 'run-scene': void act(() => luma.runScene(id!)); break;
    case 'stop-scene': void act(() => luma.stopScene(), 'Stopping. Commands already sent stay applied.'); break;
    case 'edit-scene': { const sc = state.snap?.scenes.find((x) => x.id === id); if (sc) void openEditor(sc); break; }
    case 'new-scene': void openEditor(); break;
    case 'export-scene': void act(() => luma.exportScene(id!)); break;
    case 'import-scene': void act(async () => { const sc = await luma.importScene(); if (sc) flash(`Imported ${sc.name}.`); }); break;
    case 'delete-scene': { const sc = state.snap?.scenes.find((x) => x.id === id); if (sc && confirm(`Delete the scene “${sc.name}” and its schedules?`)) void act(() => luma.deleteScene(sc.id)); break; }
    case 'capture': state.modal = { kind: 'capture', name: '', icon: 'sparkles', ids: (state.snap?.devices ?? []).filter((d) => isLight(d) && d.online !== false).map((d) => d.id) }; render(); break;
    case 'modal-close': state.modal = undefined; render(); break;
    case 'add-schedule': { const sc = state.snap?.scenes[0]; if (sc) void act(() => luma.saveSchedule({ id: uuid(), sceneID: sc.id, hour: 19, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7], enabled: true })); break; }
    case 'sch-day': {
      const sch = state.snap?.schedules.find((x) => x.id === id); if (!sch) break;
      const day = Number(target.dataset.day);
      const weekdays = sch.weekdays.includes(day) ? sch.weekdays.filter((x) => x !== day) : [...sch.weekdays, day];
      void act(() => luma.saveSchedule({ ...sch, weekdays }));
      break;
    }
    case 'sch-delete': { const sch = state.snap?.schedules.find((x) => x.id === id); const sc = sch && state.snap?.scenes.find((x) => x.id === sch.sceneID); if (sch && confirm(`Delete this schedule${sc ? ` for “${sc.name}”` : ''}?`)) void act(() => luma.deleteSchedule(sch.id)); break; }
    case 'hook-start': void act(() => luma.startWebhook()); break;
    case 'hook-stop': void act(() => luma.stopWebhook()); break;
    case 'copy-spki-pin': void act(() => luma.copySpkiPin(), 'SPKI pin copied.'); break;
    case 'copy-fingerprint': void act(() => luma.copyFingerprint(), 'Fingerprint copied.'); break;
    case 'export-certificate': void act(() => luma.exportCertificate()); break;
    case 'copy-token': void act(() => luma.copyToken(), 'Token copied. Paste it into your caller; it will not be shown here.'); break;
    case 'rotate-token': if (confirm('Rotate the token? Existing callers stop working until updated.')) void act(() => luma.rotateToken()); break;
    case 'ed-mode': if (m) void switchEditorMode(m, target.dataset.mode === 'json'); break;
    case 'ed-add': if (m) {
      const last = m.draft.steps.at(-1);
      const d = device(last?.deviceID) ?? state.snap?.devices[0];
      m.draft.steps.push({ id: uuid(), deviceID: d!.id, command: defaultCommand(d, 'on'), delayMilliseconds: 0 });
      m.error = undefined; render();
    } break;
    case 'st-up': case 'st-down': if (m) {
      const i = Number(target.dataset.index), j = a === 'st-up' ? i - 1 : i + 1;
      const steps = m.draft.steps;
      if (j >= 0 && j < steps.length) { [steps[i], steps[j]] = [steps[j]!, steps[i]!]; render(); modalHost.querySelector<HTMLElement>(`[data-action="${a}"][data-index="${j}"]:not([disabled])`)?.focus(); }
    } break;
    case 'st-remove': if (m) { m.draft.steps.splice(Number(target.dataset.index), 1); render(); } break;
  }
});

async function switchEditorMode(m: SceneEditor, toJSON: boolean): Promise<void> {
  if (toJSON === m.json) return;
  if (toJSON) { m.jsonText = JSON.stringify(m.draft, null, 2); m.json = true; m.error = undefined; render(); return; }
  try {
    m.draft = await luma.validateSceneJSON(m.jsonText); // guard BEFORE structured render
    m.json = false; m.error = undefined;
  } catch (error) {
    m.error = error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : String(error);
  }
  render();
}

// A local draft exists only during an active interaction. Range drafts end at pointer
// release (after the native change commit has fired); color drafts end on commit or blur
// (a cancelled picker fires no change event).
document.addEventListener('pointerdown', (event) => {
  const el = event.target as HTMLElement;
  if (el instanceof HTMLInputElement && el.type === 'range' && el.dataset.key) state.dragging.add(el.dataset.key);
});
const releaseDraft = (event: Event) => {
  // The pointer may be released outside the slider, so pointer events release every range draft.
  const keys = event.type === 'focusout'
    ? [(event.target as HTMLElement).dataset?.key].filter((k): k is string => !!k && state.dragging.has(k))
    : [...state.dragging].filter((k) => document.querySelector<HTMLInputElement>(`input[data-key="${CSS.escape(k)}"]`)?.type !== 'color');
  if (keys.length === 0) return;
  setTimeout(() => { let changed = false; for (const k of keys) changed = state.dragging.delete(k) || changed; if (changed) render(); }, 0);
};
document.addEventListener('pointerup', releaseDraft);
document.addEventListener('pointercancel', releaseDraft);
document.addEventListener('focusout', releaseDraft);

document.addEventListener('input', (event) => {
  const el = event.target as HTMLInputElement & HTMLTextAreaElement;
  const a = el.dataset.action;
  const m = editor();
  if (el.type === 'range' && el.dataset.key) { state.dragging.add(el.dataset.key); readout(el); return; }
  if (el.type === 'color' && el.dataset.key && !a) { state.dragging.add(el.dataset.key); return; }
  switch (a) {
    case 'search': state.search = el.value; render(); break;
    case 'adv-text': { const cur = state.advanced.get(el.dataset.id!) ?? { instance: device(el.dataset.id)?.capabilities[0]?.instance ?? '', text: '' }; state.advanced.set(el.dataset.id!, { ...cur, text: el.value }); break; }
    case 'cap-name': if (state.modal?.kind === 'capture') state.modal.name = el.value; break;
    case 'ed-name': if (m) m.draft.name = el.value; break;
    case 'ed-json': if (m) m.jsonText = el.value; break;
    case 'port': state.portDraft = el.value; break;
    case 'field-int': updateDraft(el.dataset.key!, (draft) => { const n = Number(el.value); if (el.value === '') delete draft[fieldName(el.dataset.key!)]; else draft[fieldName(el.dataset.key!)] = Number.isSafeInteger(n) ? n : el.value; }); break;
    case 'paint-level': { const d = device(el.dataset.id), schema = d && segmentSchema(capOf(d, el.dataset.instance!)); const n = Number(el.value); if (d && schema && Number.isSafeInteger(n)) painter(d, schema).level = Math.min(schema.valueRange[1], Math.max(schema.valueRange[0], n)); break; }
    case 'field-json': updateDraft(el.dataset.key!, (draft) => { try { draft[fieldName(el.dataset.key!)] = JSON.parse(el.value) as JSONValue; } catch { delete draft[fieldName(el.dataset.key!)]; } }); break;
  }
});

document.addEventListener('change', (event) => {
  const el = event.target as HTMLInputElement;
  const a = el.dataset.action, id = el.dataset.id;
  const m = editor();
  if (el.type === 'range' && el.dataset.key) { commitSlider(el); state.dragging.delete(el.dataset.key); return; }
  if (el.type === 'color' && el.dataset.key && !a) {
    const [devID] = el.dataset.key.split('|');
    const d = device(devID);
    state.dragging.delete(el.dataset.key);
    if (d) control(d.id, basicCommand(d, 'colorRgb', fromHex(el.value)));
    return;
  }
  switch (a) {
    case 'appearance': void act(() => luma.setAppearance(el.value as 'system' | 'light' | 'dark')); break;
    case 'power': { const d = device(id); if (d) control(d.id, basicCommand(d, 'powerSwitch', el.checked ? 1 : 0)); break; }
    case 'room-power': for (const d of state.snap?.devices ?? []) if (isLight(d) && d.room === el.dataset.room && supports(d, 'powerSwitch')) control(d.id, basicCommand(d, 'powerSwitch', el.checked ? 1 : 0)); break;
    case 'effect-toggle': {
      const d = device(id), cap = d && capOf(d, el.dataset.instance!);
      if (!d || !cap) break;
      const key = draftKey(d, cap), on = el.checked, seq = state.toggles.request(key, on);
      // Failures are reported by main (rollback + notice); the switch follows the latest intent.
      luma.control(d.id, { type: cap.type, instance: cap.instance, value: on ? 1 : 0 }).then(
        () => state.toggles.settle(key, seq, on, true),
        () => { state.toggles.settle(key, seq, on, false); render(); });
      break;
    }
    case 'effect-enum': { const [devID, inst] = el.dataset.key!.split('|'); const cap = capOf(device(devID)!, inst!); state.effectDrafts.set(el.dataset.key!, enumOptions(cap?.parameters)[Number(el.value)]?.value ?? null); break; }
    case 'field-enum': {
      const [devID, inst, name] = el.dataset.key!.split('|');
      const cap = capOf(device(devID)!, inst!);
      const field = (isObj(cap?.parameters) && Array.isArray(cap!.parameters.fields) ? cap!.parameters.fields : []).filter(isObj).find((f) => f.fieldName === name);
      updateDraft(el.dataset.key!, (draft) => { if (el.value === '') delete draft[name!]; else draft[name!] = enumOptions(field)[Number(el.value)]?.value ?? null; });
      break;
    }
    case 'field-color': updateDraft(el.dataset.key!, (draft) => { draft[fieldName(el.dataset.key!)] = fromHex(el.value); }); break;
    case 'paint-color': { const d = device(id), schema = d && segmentSchema(capOf(d, el.dataset.instance!)); if (d && schema) painter(d, schema).color = fromHex(el.value); break; }
    case 'adv-instance': state.advanced.set(id!, { instance: el.value, text: '' }); render(); break;
    case 'ss-awake': void act(() => luma.scheduleSync('keepAwake', el.checked)); break;
    case 'lan': void act(() => luma.setWebhookConfig(Number(state.portDraft ?? state.snap!.webhook.port), el.checked)); break;
    case 'port': void act(async () => { await luma.setWebhookConfig(Number(el.value), state.snap!.webhook.allowLAN); state.portDraft = undefined; }); break;
    case 'sch-scene': case 'sch-time': case 'sch-enabled': {
      const sch = state.snap?.schedules.find((x) => x.id === id); if (!sch) break;
      const next = { ...sch };
      if (a === 'sch-scene') next.sceneID = el.value;
      if (a === 'sch-enabled') next.enabled = el.checked;
      if (a === 'sch-time') { const [h, mi] = el.value.split(':').map(Number); if (!Number.isInteger(h) || !Number.isInteger(mi)) break; next.hour = h!; next.minute = mi!; }
      void act(() => luma.saveSchedule(next));
      break;
    }
    case 'gh-room': if (state.goveeRooms) { if (el.checked) state.goveeRooms.ids.add(id!); else state.goveeRooms.ids.delete(id!); render(); } break;
    case 'cap-icon': if (state.modal?.kind === 'capture') state.modal.icon = el.value; break;
    case 'cap-device': if (state.modal?.kind === 'capture') { const ids = new Set(state.modal.ids); if (el.checked) ids.add(id!); else ids.delete(id!); state.modal.ids = [...ids]; } break;
    case 'ed-icon': if (m) m.draft.icon = el.value; break;
    case 'st-device': if (m) {
      const st = m.draft.steps[Number(el.dataset.index)]!;
      const d = device(el.value);
      st.deviceID = el.value;
      if (stepKind(st.command) !== 'advanced') st.command = defaultCommand(d, stepKind(st.command));
      render();
    } break;
    case 'st-kind': if (m) { const st = m.draft.steps[Number(el.dataset.index)]!; st.command = defaultCommand(device(st.deviceID), el.value as StepKind); render(); } break;
    case 'st-value': if (m) {
      const st = m.draft.steps[Number(el.dataset.index)]!;
      // Keep the raw number; strict validation (finite, integer, model range) happens before saving.
      st.command = { ...st.command, value: el.value === '' ? NaN : Number(el.value) };
    } break;
    case 'st-color': if (m) { const st = m.draft.steps[Number(el.dataset.index)]!; st.command = { ...st.command, value: fromHex(el.value) }; } break;
    case 'st-delay': if (m) { const st = m.draft.steps[Number(el.dataset.index)]!; st.delayMilliseconds = el.value === '' ? 0 : Number(el.value); } break;
  }
});

document.addEventListener('keydown', (event) => {
  const el = event.target as HTMLElement;
  const modifier = navigator.platform.toLowerCase().includes('mac') ? event.metaKey : event.ctrlKey;
  if (modifier && !event.shiftKey) {
    const pages: View[] = ['lights', 'scenes', 'automations', 'activity', 'settings', 'sync'];
    if (!event.altKey && /^[1-6]$/.test(event.key)) { state.view = pages[Number(event.key) - 1]!; render(); event.preventDefault(); return; }
    if (!event.altKey && event.key === ',') { state.view = 'settings'; render(); event.preventDefault(); return; }
    if (!event.altKey && event.key.toLowerCase() === 'f') { state.view = 'lights'; render(); document.getElementById('light-search')?.focus(); event.preventDefault(); return; }
    if (!event.altKey && event.key === '.') { void act(() => luma.stopScene()); event.preventDefault(); return; }
    if (event.altKey && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) { for (const d of state.snap?.devices ?? []) if (isLight(d) && supports(d, 'powerSwitch')) control(d.id, basicCommand(d, 'powerSwitch', event.key === 'ArrowUp' ? 1 : 0)); event.preventDefault(); return; }
  }
  if (el instanceof HTMLInputElement && el.type === 'range') {
    const v = sliderStep(el, event.key);
    if (v !== undefined) { event.preventDefault(); setSlider(el, v); }
    return;
  }
  if (el.getAttribute('role') === 'tab' && (event.key === 'ArrowRight' || event.key === 'ArrowLeft')) {
    const tabs: Tab[] = ['light', 'effects', 'details'];
    const i = tabs.indexOf(state.tab) + (event.key === 'ArrowRight' ? 1 : -1);
    state.tab = tabs[(i + tabs.length) % tabs.length]!;
    render();
    document.querySelector<HTMLElement>(`#tab-${state.tab}`)?.focus();
    event.preventDefault();
  }
  if (event.key === 'Escape' && !state.modal && state.selected) selectDevice(undefined);
});

// Wheel adjusts a focused slider only, so page scrolling is never hijacked.
document.addEventListener('wheel', (event) => {
  const el = event.target as HTMLElement;
  if (!(el instanceof HTMLInputElement) || el.type !== 'range' || document.activeElement !== el) return;
  event.preventDefault();
  const v = sliderStep(el, event.deltaY < 0 ? 'ArrowUp' : 'ArrowDown');
  if (v !== undefined) setSlider(el, v);
}, { passive: false });

document.addEventListener('submit', (event) => {
  event.preventDefault();
  const form = event.target as HTMLFormElement;
  switch (form.dataset.form) {
    case 'connect': {
      const input = form.querySelector<HTMLInputElement>('#api-key')!;
      const key = input.value;
      input.value = ''; // the key never stays in the DOM
      if (!key.trim()) { flash('Enter your Govee API key.', true); break; }
      void act(() => luma.connect(key), 'Connected.');
      break;
    }
    case 'govee-signin': {
      const email = (form.elements.namedItem('email') as HTMLInputElement).value;
      const pass = form.elements.namedItem('password') as HTMLInputElement;
      const codeInput = form.elements.namedItem('code') as HTMLInputElement | null;
      const password = pass.value, code = codeInput?.value.trim() || undefined;
      // The password stays in the field only until the code step finishes; main never stores it.
      void act(async () => {
        let result: 'needsCode' | 'signedIn';
        try { result = await luma.goveeSignIn(email, password, code); } catch (error) { pass.value = ''; throw error; }
        if (result === 'signedIn') { pass.value = ''; flash('Signed in to Govee Home.'); }
        else flash('Govee emailed you a code. Enter it, then choose Finish sign-in.');
      });
      break;
    }
    case 'details': {
      const id = form.dataset.id!;
      const name = (form.elements.namedItem('name') as HTMLInputElement).value;
      const room = (form.elements.namedItem('room') as HTMLInputElement).value;
      void act(async () => { await luma.renameDevice(id, name); await luma.assignRoom(id, room); }, 'Saved.');
      break;
    }
    case 'capture': {
      const m = state.modal;
      if (m?.kind !== 'capture') break;
      void luma.captureScene(m.name.trim(), m.icon, m.ids).then((scene) => { state.modal = undefined; flash(`Saved ${scene.name}.`); })
        .catch((error: unknown) => { m.error = error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : String(error); render(); });
      break;
    }
    case 'editor': { const m = editor(); if (m) void saveEditor(m); break; }
  }
});

modalHost.addEventListener('cancel', (event) => { event.preventDefault(); state.modal = undefined; render(); });

initAudioSync({ luma, snap: () => state.snap, render, act, flash, errorText, slider: syncSlider });
initDoorbell({ luma, snap: () => state.snap, act });
initBluetooth({ luma, snap: () => state.snap, act, render });
initParity({ luma, snap: () => state.snap, act, render, flash, open: (id) => { state.view = 'lights'; selectDevice(id, 'light'); } });
luma.onSnapshot((snap) => { state.snap = snap; followSync(snap); followAudio(snap); render(); });
luma.onNavigate((target) => { if (target.deviceID) selectDevice(target.deviceID, 'light'); else if (target.tab) { state.view = target.tab as View; render(); } });
void luma.snapshot().then((snap) => { state.snap = snap; for (const a of snap.syncAssignments) { state.syncRegions.set(a.id, a.region); if (a.included) state.syncLights.set(a.id, a.region); } render(); });
setInterval(() => { if (state.view === 'automations') render(); }, 30_000); // keep "Next:" times fresh

/** Fully saturated color at hue 0…1 (segment painter rainbow). */
function hueToRGB(h: number): number {
  const f = (n: number) => { const k = (n + h * 6) % 6; return Math.round(255 * (1 - Math.max(0, Math.min(k, 4 - k, 1)))); };
  return (f(5) << 16) | (f(3) << 8) | f(1);
}

// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Audio Sync page, banner and actions. app.ts owns rendering; this module owns the audio
// choices (source, lights in order, style, sensitivity), the analysis pump, and a live meter
// drawn from the levels the pump computes locally. Choices persist in this profile only.

import type { AppSnapshot, AudioOptions, AudioSource, LumaBridge, SyncSettings } from '../shared/types';
import { AUDIO_BANDS, AUDIO_LIMITS, DEFAULT_AUDIO_OPTIONS, brightnessRange, type AudioLevels } from '../shared/audio-math.js';
import { AudioPump } from './audio-sync.js';
import { esc, hex, icon } from './ui.js';

interface Host {
  luma: LumaBridge;
  snap(): AppSnapshot | undefined;
  render(): void;
  act(work: () => Promise<unknown>, success?: string): Promise<void>;
  flash(text: string, error?: boolean): void;
  errorText(error: unknown): string;
  slider(s: AppSnapshot, d: { key: keyof SyncSettings; label: string; unit: string; range: [number, number]; scale: number; decimals?: boolean }): string;
}

const STORE = 'luma.audioSync.v1';
const BAND_LABELS = ['40 Hz', '85', '180', '380', '800', '1.7k', '3.6k', '7.6k'];
const SLIDERS = [
  { key: 'brightnessCap' as const, label: 'Brightness cap', unit: '%', range: [1, 100] as [number, number], scale: 1 },
  { key: 'smoothing' as const, label: 'Release (fade after a beat)', unit: '%', range: [0, 95] as [number, number], scale: 100 },
  { key: 'updateHz' as const, label: 'Update speed', unit: ' per second', range: [0.5, 10] as [number, number], scale: 1, decimals: true },
  { key: 'threshold' as const, label: 'Change threshold', unit: '%', range: [0.5, 20] as [number, number], scale: 100, decimals: true },
];

let host: Host;
let pump: AudioPump;
let levels: AudioLevels | undefined;
const local = {
  mode: 'screen' as 'screen' | 'audio',
  source: undefined as AudioSource | undefined,
  /** Selection order is spectrum order (bass → treble). */
  lights: [] as string[],
  options: { ...DEFAULT_AUDIO_OPTIONS } as AudioOptions,
};

function load(): void {
  try {
    const v = JSON.parse(localStorage.getItem(STORE) ?? '{}') as Partial<typeof local>;
    if (v.mode === 'audio' || v.mode === 'screen') local.mode = v.mode;
    if (v.source === 'system' || v.source === 'input') local.source = v.source;
    if (Array.isArray(v.lights)) local.lights = v.lights.filter((x): x is string => typeof x === 'string').slice(0, 32);
    if (v.options?.style === 'pulse' || v.options?.style === 'spectrum') local.options.style = v.options.style;
    const k = v.options?.sensitivity;
    if (typeof k === 'number' && k >= AUDIO_LIMITS.sensitivity[0] && k <= AUDIO_LIMITS.sensitivity[1]) local.options.sensitivity = k;
  } catch { /* first run or unreadable: defaults */ }
}
function save(): void { try { localStorage.setItem(STORE, JSON.stringify(local)); } catch { /* best effort */ } }

export function initAudioSync(h: Host): void {
  host = h;
  load();
  pump = new AudioPump(h.luma, (next) => { levels = next; paintAudio(document); });
}

/** The Sync page shows the live session's kind; otherwise the person's last choice. */
export function syncMode(s: AppSnapshot): 'screen' | 'audio' { return s.sync.phase !== 'idle' ? s.sync.kind : local.mode; }

export function modeSwitch(s: AppSnapshot): string {
  const mode = syncMode(s), idle = s.sync.phase === 'idle';
  return `<div class="segmented" role="radiogroup" aria-label="Sync with">
    <button role="radio" aria-checked="${mode === 'screen'}" data-action="audio-mode" data-value="screen" ${idle ? '' : 'disabled'}>${icon('screen')}Screen</button>
    <button role="radio" aria-checked="${mode === 'audio'}" data-action="audio-mode" data-value="audio" ${idle ? '' : 'disabled'}>${icon('party')}Audio</button>
  </div>`;
}

/** Persistent capture indicator for an audio session, shown on every view. */
export function audioBanner(s: AppSnapshot, onSyncView: boolean): string {
  const y = s.sync;
  const live = y.phase === 'running' || y.phase === 'starting';
  const what = `“${esc(y.sourceName ?? 'computer audio')}”`;
  const text = y.phase === 'stopping' ? 'Audio Sync is stopping…' : y.phase === 'paused' ? `Audio Sync is paused · ${what}` : y.phase === 'starting' ? `Audio Sync is starting · ${what}` : `Audio Sync is live · listening to ${what} on this computer`;
  return `<div class="sync-live ${live ? 'on' : ''}" role="status">
    <span class="dot" aria-hidden="true"></span><span class="sync-live-text">${text}</span>
    <span class="actions">
      ${onSyncView ? '' : '<button class="ghost" data-action="view" data-view="sync">Open</button>'}
      ${y.phase === 'paused' ? `<button data-action="audio-resume">${icon('play')}Resume</button>` : live ? `<button data-action="audio-pause">${icon('pause')}Pause</button>` : ''}
      <button class="danger-solid" data-action="audio-stop" ${y.phase === 'stopping' ? 'disabled' : ''}>${icon('stop')}Stop</button>
    </span>
  </div>`;
}

function meter(): string {
  return `<div class="audio-meter" aria-hidden="true">
    <div class="audio-meter-level"><span data-audio-level></span></div>
    <div class="audio-bands">${Array.from({ length: AUDIO_BANDS }, (_, i) => `<div class="audio-band"><span data-audio-band="${i}"></span><small>${BAND_LABELS[i]}</small></div>`).join('')}</div>
  </div>`;
}

/** CSP forbids inline styles: the meter is painted through CSSOM after every render and every analysis frame. */
export function paintAudio(root: ParentNode): void {
  const level = root.querySelector<HTMLElement>('[data-audio-level]');
  if (!level) return;
  level.style.setProperty('--level', `${Math.round((levels?.level ?? 0) * 100)}%`);
  root.querySelectorAll<HTMLElement>('[data-audio-band]').forEach((el) => el.style.setProperty('--level', `${Math.round((levels?.bands[Number(el.dataset.audioBand)] ?? 0) * 100)}%`));
  const status = root.querySelector<HTMLElement>('[data-audio-signal]');
  if (status) status.textContent = !levels ? 'No signal yet' : levels.level > 0.08 ? 'Hearing audio' : 'Silent: lights rest at the floor';
}

export function audioSyncView(s: AppSnapshot): string {
  const y = s.sync, idle = y.phase === 'idle', sup = y.audioSupport;
  const eligible = y.eligibility.filter((e) => e.eligible), blocked = y.eligibility.filter((e) => !e.eligible);
  const chosen = local.lights.filter((id) => eligible.some((e) => e.id === id));
  const source = local.source && sup[local.source] ? local.source : sup.system ? 'system' : sup.input ? 'input' : undefined;
  const canStart = idle && !!source && chosen.length > 0;
  const [floor, cap] = brightnessRange(y.settings.brightnessCap);
  const order = (id: string) => local.options.style === 'spectrum' && chosen.length > 1 ? ` · ${['bass', 'low-mid', 'mid', 'upper-mid', 'treble'][Math.round((chosen.indexOf(id) / (chosen.length - 1)) * 4)]}` : '';
  return `<section class="pane sync" aria-labelledby="sync-title">
    <header class="toolbar">
      <div><h1 id="sync-title">Audio Sync</h1><p class="sub">Lights follow the music and sound playing on this computer.</p></div>
      <div class="actions">
        ${modeSwitch(s)}
        ${idle ? `<button class="primary" data-action="audio-start" ${canStart ? '' : 'disabled'}>${icon('play')}Start</button>` : ''}
      </div>
    </header>
    ${s.demo ? '<p class="hint">Demo: the lights are samples, but Audio Sync listens to real audio on this computer. There is no simulated signal.</p>' : ''}
    <section class="card-block" aria-labelledby="audio-source-title">
      <h2 id="audio-source-title">Source</h2>
      ${idle ? `<div class="source-list" role="radiogroup" aria-label="Audio source">
          <label class="choice"><input type="radio" name="audio-source" data-action="audio-source" value="system" ${source === 'system' ? 'checked' : ''} ${sup.system ? '' : 'disabled'}><span>${icon('party')}Computer audio${sup.systemExperimental ? ' (experimental on Linux)' : ''}${sup.system ? '' : ' (Windows and Linux)'}</span></label>
          <label class="choice"><input type="radio" name="audio-source" data-action="audio-source" value="input" ${source === 'input' ? 'checked' : ''} ${sup.input ? '' : 'disabled'}><span>${icon('bolt')}Default input (microphone, line-in or loopback device)</span></label>
        </div>
        <p class="hint">${sup.systemExperimental
          ? 'On Linux, computer audio uses PulseAudio/PipeWire loopback where Chromium supports it. If the meter stays flat, choose Default input and route your output’s monitor to Luma (pavucontrol → Recording, or pw-loopback).'
          : sup.system ? 'Computer audio captures what this PC plays (Windows loopback). No microphone is used.' : 'Computer audio capture is available in Luma for Windows and Linux. On this system, use an input device: a microphone near the speakers, or a loopback device that carries your output.'}</p>`
        : `<p>${esc(y.sourceName ?? '')}</p><p class="hint">Stop Audio Sync to change the source or lights.</p>`}
      ${meter()}
      <p class="hint"><span data-audio-signal>${idle ? 'Start to see the live level' : 'No signal yet'}</span>. Audio is analyzed on this computer into 9 levels 20 times a second. It is never played back, recorded, saved, uploaded or logged.</p>
    </section>
    <section class="card-block" aria-labelledby="audio-lights-title">
      <h2 id="audio-lights-title">Lights</h2>
      ${idle ? `${eligible.length ? `<ul class="sync-lights">${eligible.map((e) => `<li>
          <label class="choice"><input type="checkbox" data-action="audio-light" data-id="${esc(e.id)}" ${chosen.includes(e.id) ? 'checked' : ''}><span>${esc(e.name)}${chosen.includes(e.id) ? `<span class="sub">${order(e.id)}</span>` : ''}</span></label>
        </li>`).join('')}</ul>` : '<p class="hint">No light can stream right now.</p>'}
        ${blocked.length ? `<details class="advanced"><summary>Unavailable lights (${blocked.length})</summary><ul class="sync-blocked">${blocked.map((e) => `<li><span>${esc(e.name)}</span><span class="sub">${esc(e.reason ?? '')}</span></li>`).join('')}</ul></details>` : ''}
        <p class="hint">Only lights that are on and reachable with Govee LAN Control can follow audio; it never uses the cloud and never turns lights on. In Spectrum, the order you tick lights runs from bass to treble.</p>`
      : `<ul class="sync-lights">${y.lights.map((l) => `<li>
          <span class="orb small" data-color="${l.requestedRGB !== undefined ? hex(l.requestedRGB) : ''}"></span>
          <span class="sync-light-text"><span>${esc(l.name)}</span><span class="sub">${l.status === 'excluded' ? 'Manual control: left Audio Sync' : l.requestedBrightness !== undefined ? `Requested ${l.requestedBrightness}% · preview, unconfirmed` : 'Waiting for audio'}</span></span>
        </li>`).join('')}</ul>
        <p class="hint">Swatches preview what Audio Sync is requesting over LAN, not confirmed light state. Changing a light by hand removes it from the stream.</p>`}
    </section>
    <section class="card-block" aria-labelledby="audio-tune-title">
      <h2 id="audio-tune-title">Response</h2>
      <div class="row"><span>Style</span>
        <div class="segmented" role="radiogroup" aria-label="Style">
          <button role="radio" aria-checked="${local.options.style === 'pulse'}" data-action="audio-style" data-value="pulse">Pulse</button>
          <button role="radio" aria-checked="${local.options.style === 'spectrum'}" data-action="audio-style" data-value="spectrum">Spectrum</button>
        </div>
      </div>
      <p class="hint">Pulse: every light shares one color from the sound’s balance (bass red → treble violet) and one brightness from loudness. Spectrum: each light follows its own frequency band.</p>
      <div class="slider-row">
        <label for="sl-audio-sensitivity">Sensitivity</label><output data-readout="audio|sensitivity">${Math.round(local.options.sensitivity * 100)}%</output>
        <input id="sl-audio-sensitivity" type="range" class="slider" data-key="audio|sensitivity" data-unit="%" min="${AUDIO_LIMITS.sensitivity[0] * 100}" max="${AUDIO_LIMITS.sensitivity[1] * 100}" step="any" value="${local.options.sensitivity * 100}" aria-valuetext="${Math.round(local.options.sensitivity * 100)}%">
      </div>
      ${SLIDERS.map((d) => host.slider(s, d)).join('')}
      <p class="hint">Brightness stays between ${floor}% and ${cap}% (the floor is a fifth of the cap), so lights never black out between beats. Loudness is leveled automatically; a noise gate keeps hiss from moving the lights. Brightness rises fast and fades over at least a quarter second, which keeps full-depth flashes well under three per second. These settings are shared with Screen Sync.</p>
      <div class="row"><span>When I stop</span>
        <div class="segmented" role="radiogroup" aria-label="When I stop">
          <button role="radio" aria-checked="${!y.settings.restore}" data-action="sync-restore" data-value="0">Leave lights as they are</button>
          <button role="radio" aria-checked="${y.settings.restore}" data-action="sync-restore" data-value="1">Restore previous state</button>
        </div>
      </div>
    </section>
    ${!idle || (y.kind === 'audio' && y.stats.frames) ? `<section class="card-block" aria-labelledby="audio-stats-title"><h2 id="audio-stats-title">Session</h2>
      <dl class="stats"><div><dt>Analysis frames</dt><dd>${y.stats.frames}</dd></div><div><dt>Frames skipped</dt><dd>${y.stats.dropped}</dd></div><div><dt>Updates sent</dt><dd>${y.stats.sent}</dd></div><div><dt>Replaced before sending</dt><dd>${y.stats.superseded}</dd></div><div><dt>Send errors</dt><dd>${y.stats.errors}</dd></div></dl>
    </section>` : ''}
    ${idle && y.kind === 'audio' && y.lastStop ? `<p class="hint">Last session: ${esc(y.lastStop)}</p>` : ''}
  </section>`;
}

/** Keeps the local pump in step with main's session state. */
export function followAudio(snap: AppSnapshot): void {
  const y = snap.sync;
  if (!pump.live) return;
  if (y.kind !== 'audio' || y.generation > pump.generation! || y.phase === 'idle' || y.phase === 'stopping') pump.stop();
  else if (y.phase === 'paused') pump.pause();
}

export function commitAudioSetting(key: string, value: number): void {
  if (key !== 'sensitivity' || !Number.isFinite(value)) return;
  local.options.sensitivity = Math.round(Math.min(AUDIO_LIMITS.sensitivity[1], Math.max(AUDIO_LIMITS.sensitivity[0], value / 100)) * 100) / 100;
  save();
  void host.act(() => host.luma.audioOptions({ sensitivity: local.options.sensitivity }));
}

document.addEventListener('click', (event) => {
  const target = (event.target as Element).closest<HTMLElement>('[data-action^="audio-"]');
  if (!target || target instanceof HTMLInputElement || !host) return;
  const s = host.snap();
  switch (target.dataset.action) {
    case 'audio-mode': local.mode = target.dataset.value === 'audio' ? 'audio' : 'screen'; save(); host.render(); break;
    case 'audio-style':
      local.options.style = target.dataset.value === 'spectrum' ? 'spectrum' : 'pulse'; save();
      void host.act(() => host.luma.audioOptions({ style: local.options.style })); host.render();
      break;
    case 'audio-start': {
      const sup = s?.sync.audioSupport;
      const source = local.source && sup?.[local.source] ? local.source : sup?.system ? 'system' : 'input';
      const lights = local.lights.filter((id) => s?.sync.eligibility.some((e) => e.id === id && e.eligible)).map((id) => ({ id }));
      if (lights.length === 0) break;
      host.luma.audioStart(source, lights, { ...local.options }).then(
        (grant) => { void pump.start(grant); host.render(); }, // first, while the click's activation is fresh
        (error: unknown) => host.flash(host.errorText(error), true),
      );
      break;
    }
    case 'audio-pause': pump.pause(); void host.act(() => host.luma.syncPause()); break;
    case 'audio-resume': {
      const token = pump.token;
      if (!token) break;
      void host.act(async () => { await host.luma.syncResume(token); pump.resume(token); });
      break;
    }
    case 'audio-stop': pump.stop(); void host.act(() => host.luma.syncStop()); break;
  }
});

document.addEventListener('change', (event) => {
  const el = event.target as HTMLInputElement;
  if (!host) return;
  if (el.dataset.action === 'audio-source' && (el.value === 'system' || el.value === 'input')) { local.source = el.value; save(); host.render(); }
  if (el.dataset.action === 'audio-light' && el.dataset.id) {
    local.lights = local.lights.filter((id) => id !== el.dataset.id);
    if (el.checked) local.lights.push(el.dataset.id);
    save(); host.render();
  }
});

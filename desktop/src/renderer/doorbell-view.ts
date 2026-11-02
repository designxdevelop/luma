// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Automations › Doorbell alert: choose lights and the look, test it, connect your Alexa relay.

import type { AppSnapshot, DoorbellConfig, LumaBridge } from '../shared/types';
import { esc, hex, fromHex, icon } from './ui.js';
import { isLight } from '../shared/devices.js';

interface Host { luma: LumaBridge; snap(): AppSnapshot | undefined; act(work: () => Promise<unknown>, success?: string): Promise<void> }
let host: Host;

const time = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

export function doorbellView(s: AppSnapshot): string {
  const { config: c, phase, status, relayState, relayTokenSaved, pairing } = s.doorbell;
  const rooms = [...new Set(s.devices.filter(isLight).map((d) => d.room))].sort();
  const busy = phase !== 'idle';
  const num = (key: keyof DoorbellConfig, label: string, min: number, max: number, step: number, unit: string) =>
    `<div class="row"><label for="db-${key}">${label}</label><input id="db-${key}" type="number" min="${min}" max="${max}" step="${step}" value="${c[key] as number}" data-action="db-num" data-key="${key}"> ${unit}</div>`;
  return `<section class="card-block" aria-labelledby="db-title">
    <h2 id="db-title">Doorbell alert</h2>
    <div class="row"><label for="db-enabled">Flash lights when the doorbell rings</label><input id="db-enabled" type="checkbox" role="switch" class="switch" data-action="db-enabled" ${c.enabled ? 'checked' : ''}></div>
    <p class="sub" role="status">${busy ? `<span class="pill running">${phase === 'restoring' ? 'Restoring' : 'Flashing'}</span> ` : ''}${esc(status)}</p>
    <div class="actions">${busy ? `<button data-action="db-stop">${icon('stop')}Stop</button>` : `<button data-action="db-test" ${c.enabled ? '' : 'disabled'}>${icon('play')}Test alert</button>`}</div>
    <fieldset><legend>Rooms</legend>
      ${rooms.length ? rooms.map((r) => `<label class="chip"><input type="checkbox" data-action="db-room" data-room="${esc(r)}" ${c.rooms.includes(r) ? 'checked' : ''}> ${esc(r)}</label>`).join('') : '<p class="hint">No rooms yet.</p>'}
      <p class="hint">Lights in these rooms when the bell rings, so a light you add later is included. Appliances are never touched.</p>
    </fieldset>
    <details><summary>Individual lights (${c.deviceIDs.length})</summary>
      ${s.devices.filter(isLight).map((d) => `<label class="block"><input type="checkbox" data-action="db-light" data-id="${esc(d.id)}" ${c.deviceIDs.includes(d.id) ? 'checked' : ''}> ${esc(d.name)} · ${esc(d.room)}</label>`).join('')}
    </details>
    <div class="row"><label for="db-color">Alert color</label><input id="db-color" type="color" value="${hex(c.rgb)}" data-action="db-color"></div>
    ${num('durationSeconds', 'Length', 5, 60, 5, 's')}
    ${num('pulseSeconds', 'One pulse every', 2, 6, 0.5, 's')}
    ${num('brightnessCap', 'Brightest', 10, 100, 10, '%')}
    ${num('cooldownSeconds', 'Ignore new rings after an alert for', 0, 300, 10, 's')}
    <div class="row"><label for="db-quiet">Quiet hours</label><input id="db-quiet" type="checkbox" role="switch" class="switch" data-action="db-quiet" ${c.quietStart !== undefined ? 'checked' : ''}></div>
    ${c.quietStart !== undefined ? `<div class="row"><label for="db-qs">From</label><input id="db-qs" type="time" value="${time(c.quietStart)}" data-action="db-qtime" data-key="quietStart"><label for="db-qe">to</label><input id="db-qe" type="time" value="${time(c.quietEnd ?? 0)}" data-action="db-qtime" data-key="quietEnd"></div>
      ${num('quietBrightnessCap', 'During quiet hours, up to (0 leaves lights alone)', 0, 100, 10, '%')}` : ''}
    <p class="hint">Lights in Screen or Audio Sync, with DreamView on, or being changed are skipped. Cloud-only lights hold the color instead of pulsing, to stay inside Govee’s limits. Change a light during the alert and it stays as you set it.</p>

    <h3>Alexa and your doorbell</h3>
    <p class="sub"><span class="pill">${esc(relayState)}</span></p>
    <p class="hint">An Alexa routine (When the doorbell is pressed → Control scene “Doorbell Alert”) reaches Luma through a small relay you deploy to your own accounts. Luma connects out to it; nothing on this PC is opened to the internet. Luma must be running and the PC awake. Set-up steps: docs/DOORBELL-ALERT.md.</p>
    ${!c.relayURL || !relayTokenSaved ? `
      <div class="row"><label for="db-relay-url">Relay address</label><input id="db-relay-url" type="url" placeholder="https://…" value="${esc(c.relayURL ?? '')}"></div>
      <div class="row"><label for="db-relay-token">Relay token (HUB_TOKEN)</label><input id="db-relay-token" type="password" autocomplete="off"></div>
      <div class="actions"><button data-action="db-relay-save" ${s.demo ? 'disabled' : ''}>Connect relay</button></div>`
    : `<div class="actions"><button data-action="db-pair">Get pairing code</button><button data-action="db-unlink">Unlink Alexa</button><button data-action="db-forget">Forget relay</button></div>
      ${pairing ? `<p><code class="pairing" aria-label="Pairing code ${esc(pairing.code.split('').join(' '))}">${esc(pairing.code)}</code> Enter this when the Alexa app asks you to link Luma. Expires ${new Date(pairing.expiresAt * 1000).toLocaleTimeString()}.</p>` : ''}`}
    <p class="hint">Home Assistant and scripts can ring with <code>POST /v1/alerts/doorbell</code> on the webhook server: <code>{"eventId":"…","timestamp":&lt;Unix seconds&gt;}</code>.</p>
  </section>`;
}

function edit(change: (c: DoorbellConfig) => DoorbellConfig): void {
  const c = host.snap()?.doorbell.config;
  if (c) void host.act(() => host.luma.doorbell('update', change({ ...c, rooms: [...c.rooms], deviceIDs: [...c.deviceIDs] })));
}

export function initDoorbell(h: Host): void {
  host = h;
  document.addEventListener('click', (event) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>('[data-action^="db-"]');
    switch (target?.dataset.action) {
      case 'db-test': void host.act(() => host.luma.doorbell('test')); break;
      case 'db-stop': void host.act(() => host.luma.doorbell('stop')); break;
      case 'db-pair': void host.act(() => host.luma.doorbell('pairingCode')); break;
      case 'db-unlink': if (confirm('Unlink every Alexa account from your relay?')) void host.act(() => host.luma.doorbell('unlink')); break;
      case 'db-forget': void host.act(() => host.luma.doorbell('forgetRelay')); break;
      case 'db-relay-save': {
        const url = (document.getElementById('db-relay-url') as HTMLInputElement).value;
        const token = document.getElementById('db-relay-token') as HTMLInputElement;
        void host.act(() => host.luma.doorbell('saveRelay', url, token.value), 'Relay connected.').finally(() => { token.value = ''; });
        break;
      }
    }
  });
  document.addEventListener('change', (event) => {
    const el = event.target as HTMLInputElement;
    const key = el.dataset.key as keyof DoorbellConfig;
    switch (el.dataset.action) {
      case 'db-enabled': edit((c) => ({ ...c, enabled: el.checked })); break;
      case 'db-room': edit((c) => ({ ...c, rooms: el.checked ? [...c.rooms, el.dataset.room!] : c.rooms.filter((r) => r !== el.dataset.room) })); break;
      case 'db-light': edit((c) => ({ ...c, deviceIDs: el.checked ? [...c.deviceIDs, el.dataset.id!] : c.deviceIDs.filter((d) => d !== el.dataset.id) })); break;
      case 'db-color': edit((c) => ({ ...c, rgb: fromHex(el.value) })); break;
      case 'db-num': edit((c) => ({ ...c, [key]: Number(el.value) })); break;
      case 'db-quiet': edit((c) => el.checked ? { ...c, quietStart: 22 * 60, quietEnd: 7 * 60 } : { ...c, quietStart: undefined, quietEnd: undefined }); break;
      case 'db-qtime': { const [hh, mm] = el.value.split(':').map(Number); if (Number.isInteger(hh) && Number.isInteger(mm)) edit((c) => ({ ...c, [key]: hh! * 60 + mm! })); break; }
    }
  });
}

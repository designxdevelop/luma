// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Settings › Bluetooth lights, as on the Mac: scan, connect to one profiled light, read its
// state, control it, and decode a Govee Home capture. The renderer only carries GATT bytes
// (Web Bluetooth); the protocol, encryption and pacing live in main (main/bluetooth.ts).

import type { AppSnapshot, BluetoothAction, LumaBridge } from '../shared/types';
import { esc, hex, fromHex } from './ui.js';

interface Host { luma: LumaBridge; snap(): AppSnapshot | undefined; act(work: () => Promise<unknown>, success?: string): Promise<void>; render(): void }
let host: Host;

// Minimal Web Bluetooth shapes (TypeScript's DOM lib doesn't include Web Bluetooth).
interface BluetoothRemoteGATTCharacteristic extends EventTarget {
  properties: { writeWithoutResponse: boolean }; value?: DataView;
  readValue(): Promise<DataView>; writeValueWithoutResponse(v: BufferSource): Promise<void>; startNotifications(): Promise<unknown>;
}
interface BluetoothDevice extends EventTarget {
  gatt?: { connect(): Promise<{ getPrimaryService(uuid: string): Promise<{ getCharacteristic(uuid: string): Promise<BluetoothRemoteGATTCharacteristic> }> }>; disconnect(): void };
}
interface Bluetooth { requestDevice(options: object): Promise<BluetoothDevice> }

const GOVEE_SERVICE = '00010203-0405-0607-0809-0a0b0c0d1910';
const WRITE = '00010203-0405-0607-0809-0a0b0c0d2b11', NOTIFY = '00010203-0405-0607-0809-0a0b0c0d2b10', MARKER = '00010203-0405-0607-0809-0a0b0c0d2b12';
/** Govee puts advertisement flags in the low byte of the company ID (0x88xx). */
const GOVEE_COMPANIES = Array.from({ length: 256 }, (_, i) => 0x8800 | i);

type Gatt = { device: BluetoothDevice; write?: BluetoothRemoteGATTCharacteristic };
let link: Gatt | undefined;

const bytes = (v: DataView | undefined) => (v ? Array.from(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)) : undefined);

/** Manufacturer data as CoreBluetooth presents it: company ID little-endian, then the payload. Waits briefly; optional. */
async function advertisement(device: BluetoothDevice): Promise<{ data?: number[]; rssi?: number }> {
  const watch = (device as unknown as { watchAdvertisements?: () => Promise<void> }).watchAdvertisements;
  if (!watch) return {};
  return new Promise((resolve) => {
    const done = (r: { data?: number[]; rssi?: number }) => { clearTimeout(timer); device.removeEventListener('advertisementreceived', on as EventListener); resolve(r); };
    const on = (e: Event & { manufacturerData?: Map<number, DataView>; rssi?: number }) => {
      for (const [company, view] of e.manufacturerData ?? []) if ((company & 0xff00) === 0x8800) return done({ data: [company & 0xff, company >> 8, ...bytes(view)!], rssi: e.rssi });
    };
    const timer = setTimeout(() => done({}), 2500);
    device.addEventListener('advertisementreceived', on as EventListener);
    watch.call(device).catch(() => done({}));
  });
}

/** Opens the chooser (main fills the list as lights advertise) and, once one is chosen, connects in the evidenced order. */
async function scanAndConnect(): Promise<void> {
  const bt = (navigator as Navigator & { bluetooth?: Bluetooth }).bluetooth;
  if (!bt) { await host.luma.bluetooth('closed', 'This system has no Bluetooth LE support Luma can use.'); return; }
  await host.luma.bluetooth('scan');
  let device: BluetoothDevice;
  try {
    device = await bt.requestDevice({ acceptAllDevices: true, optionalServices: [GOVEE_SERVICE], optionalManufacturerData: GOVEE_COMPANIES });
  } catch { await host.luma.bluetooth('scanEnded'); return; }
  const ad = await advertisement(device);
  try {
    device.addEventListener('gattserverdisconnected', () => { if (link?.device === device) { link = undefined; void host.luma.bluetooth('closed', 'The light disconnected.'); } });
    const server = await device.gatt!.connect();
    const service = await server.getPrimaryService(GOVEE_SERVICE);
    const write = await service.getCharacteristic(WRITE), notify = await service.getCharacteristic(NOTIFY);
    // The source writes without response; a light that only takes acknowledged writes isn't the evidenced protocol.
    if (!write.properties.writeWithoutResponse) throw new Error("This light's control characteristic doesn't accept the writes Luma sends, so nothing was sent.");
    let marker: number[] | 'absent' | 'failed' = 'absent';
    try { const m = await service.getCharacteristic(MARKER); try { marker = bytes(await m.readValue())!; } catch { marker = 'failed'; } } catch { /* no marker characteristic */ }
    link = { device, write };
    if (!await host.luma.bluetooth('secure', { marker, advertisement: ad.data, rssi: ad.rssi })) { device.gatt?.disconnect(); return; }
    notify.addEventListener('characteristicvaluechanged', () => { void host.luma.bluetooth('notify', bytes(notify.value)); });
    await notify.startNotifications();
    await host.luma.bluetooth('notifying');
  } catch (error) {
    device.gatt?.disconnect(); link = undefined;
    await host.luma.bluetooth('closed', error instanceof Error && !error.name.endsWith('Error') ? error.message : "Couldn't connect. The light may be connected to another phone or hub.");
  }
}

export function bluetoothView(s: AppSnapshot): string {
  const b = s.bluetooth;
  const busy = b.phase !== 'idle' && b.phase !== 'failed';
  const c = b.connected, r = b.readback;
  const seg = (action: string, on: boolean, labels: [string, string], extra = '') => `<div class="segmented" role="radiogroup">${[true, false].map((v, i) => `<button role="radio" aria-checked="${on === v}" data-action="${action}" data-value="${v ? 1 : 0}" ${extra}>${labels[i]}</button>`).join('')}</div>`;
  return `<section class="pane" aria-labelledby="bt-title">
    <header class="toolbar"><div><h1 id="bt-title">Bluetooth</h1><p class="sub">Control supported Govee lights near this PC without Wi-Fi or the cloud. Luma connects only to the light you choose and lets go when you leave this page.</p></div>
      <div class="actions"><button data-action="view" data-view="settings">Done</button></div></header>
    <section class="card-block"><div class="room-head"><h2>Nearby${b.nearby.length ? ` <span class="sub">${b.nearby.length}</span>` : ''}</h2>
      <button class="primary" data-action="bt-scan" ${busy || s.demo ? 'disabled' : ''} title="${s.demo ? 'Disabled in demo' : ''}">${b.phase === 'scanning' ? 'Scanning…' : 'Scan'}</button></div>
      ${s.demo ? '<p class="hint">Bluetooth is disabled in demo mode: sample lights only.</p>' : !b.supported ? '<p class="hint warn">Bluetooth LE isn\'t available to Luma on this system.</p>'
        : b.nearby.length === 0 ? `<p class="hint">${b.phase === 'scanning' ? 'Looking for Govee lights…' : 'Scan to find Govee lights in Bluetooth range. Bluetooth reaches about 10 m; a light connected to a phone may not advertise.'}</p>` : ''}
      <ul class="pin-list">${b.nearby.map((n) => `<li class="row"><span><strong>${esc(n.title)}</strong><br><span class="sub">${esc([n.localName, n.account && `Govee Home: ${n.account}`, n.rssi !== undefined && `${n.rssi} dBm`].filter(Boolean).join(' · '))}</span>
        ${n.note ? `<br><span class="hint">${esc(n.note)}</span>` : ''}</span>
        ${n.connectable ? `<button data-action="bt-connect" data-id="${esc(n.id)}" ${b.phase !== 'scanning' ? 'disabled' : ''}>${c?.id === n.id ? 'Connected' : 'Connect'}</button>` : ''}</li>`).join('')}</ul>
    </section>
    ${c || b.phase === 'failed' || busy && b.phase !== 'scanning' ? `<section class="card-block"><div class="room-head"><h2>${esc(c?.title ?? 'Light')} <span class="sub">${esc(phaseText(b.phase))}</span></h2>${c ? '<button data-action="bt-disconnect">Disconnect</button>' : ''}</div>
      ${b.message ? `<p class="hint warn" role="alert">${esc(b.message)}</p>` : ''}
      ${b.phase === 'ready' && c ? `<p class="hint">${esc([c.encryption, r.firmware && `Firmware ${r.firmware}`, r.hardware && `Hardware ${r.hardware}`].filter(Boolean).join(' · '))}</p>
        ${c.limitation ? `<p class="hint">${esc(c.limitation)}</p>` : ''}
        <div class="row"><label for="bt-power">Power</label><input id="bt-power" type="checkbox" role="switch" class="switch" data-action="bt-power" ${r.power ? 'checked' : ''} ${r.power === undefined ? 'disabled' : ''}></div>
        <div class="row"><label for="bt-bri">Brightness ${r.brightness !== undefined ? `${r.brightness}%` : '—'}</label><input id="bt-bri" type="range" min="1" max="100" value="${Math.max(1, r.brightness ?? 50)}" data-action="bt-brightness" ${r.brightness === undefined ? 'disabled' : ''}></div>
        ${c.color ? `<div class="row"><label for="bt-color">Color</label><input id="bt-color" type="color" data-action="bt-color" value="${hex(0xffffff)}"></div><p class="hint">The light doesn't report its color back, so this sends only.</p>` : ''}
        ${c.videoMode ? `<h3>Video mode</h3>${r.video ? `${seg('bt-video-source', r.video.movie, ['Movie', 'Game'])}${seg('bt-video-area', r.video.whole, ['All', 'Part'])}
          <div class="row"><label for="bt-vsat">Saturation ${r.video.saturation}</label><input id="bt-vsat" type="range" min="1" max="100" step="5" value="${Math.max(1, r.video.saturation)}" data-action="bt-video-sat"></div>`
          : '<p class="hint">Start Video mode in Govee Home or with the light\'s button; Luma then shows Movie/Game, All/Part and saturation here.</p>'}` : ''}
        ${c.dreamView ? `<h3>DreamView group</h3><p class="hint">Settings for the group already set up in Govee Home. Members can't be read or changed over Bluetooth yet.</p>
          ${r.groupEnabled !== undefined ? `<div class="row"><label for="bt-dv">Group sync</label><input id="bt-dv" type="checkbox" role="switch" class="switch" data-action="bt-dv-enabled" ${r.groupEnabled ? 'checked' : ''}></div>` : ''}
          ${r.groupArea !== undefined && r.groupContent !== undefined ? (r.groupArea <= 1 && r.groupContent <= 1
            ? `${seg('bt-dv-content', r.groupContent === 1, ['Movie', 'Game'])}${seg('bt-dv-area', r.groupArea === 0, ['All', 'Part'])}`
            : '<p class="hint">The light reported group video values Luma doesn\'t recognise, so they aren\'t editable.</p>') : ''}
          ${r.groupSaturation !== undefined ? `<div class="row"><label for="bt-dvsat">Group saturation ${r.groupSaturation}</label><input id="bt-dvsat" type="range" min="0" max="100" step="5" value="${r.groupSaturation}" data-action="bt-dv-sat"></div>` : ''}
          ${r.memberSlots ? `<p class="hint"><code>Member connection slots (raw, up to ${c.memberLimit} used): ${esc(r.memberSlots)}</code></p>` : ''}` : ''}`
      : c ? `<p class="hint">${esc(phaseText(b.phase))}</p>` : ''}
    </section>` : ''}
    <section class="card-block"><div class="room-head"><h2>DreamView members from a capture</h2><button data-action="bt-capture">Read capture…</button></div>
      <p class="hint">Govee Home sends the whole member list, with each light's command version, when it saves a DreamView group. Capture that Bluetooth traffic (Wireshark on an Android HCI snoop log, or PacketLogger), export one line per frame as W &lt;hex&gt; for writes and N &lt;hex&gt; for notifications, and Luma decodes it here, encrypted or not. Nothing is sent to your lights.</p>
      ${b.capture?.error ? `<p class="error" role="alert">${esc(b.capture.error)}</p>` : ''}${b.capture?.summary ? `<pre class="code">${esc(b.capture.summary)}</pre>` : ''}
    </section>
  </section>`;
}

function phaseText(phase: AppSnapshot['bluetooth']['phase']): string {
  return { idle: 'Not connected', scanning: 'Scanning…', connecting: 'Connecting…', securing: 'Securing the connection…', reading: 'Reading state…', ready: 'Connected', failed: 'Disconnected' }[phase];
}

/** Leaving the page lets go of the light, as closing the Mac sheet does. */
export function leaveBluetooth(): void {
  if (host?.snap()?.bluetooth.phase !== 'idle') void host.luma.bluetooth('disconnect');
}

export function initBluetooth(h: Host): void {
  host = h;
  host.luma.onBluetoothWrite((frame) => {
    const write = link?.write;
    if (!write) return;
    write.writeValueWithoutResponse(new Uint8Array(frame)).catch(() => { void host.luma.bluetooth('closed', 'The light stopped accepting writes.'); });
  });
  host.luma.onBluetoothDisconnect(() => { link?.device.gatt?.disconnect(); link = undefined; });
  const send = (action: BluetoothAction) => void host.act(() => host.luma.bluetooth('send', action));
  document.addEventListener('click', (event) => {
    const t = (event.target as Element).closest<HTMLElement>('[data-action]');
    if (!t || t instanceof HTMLInputElement) return;
    const r = host.snap()?.bluetooth.readback, on = t.dataset.value === '1';
    switch (t.dataset.action) {
      case 'bt-scan': void scanAndConnect(); break;
      case 'bt-connect': void host.act(() => host.luma.bluetooth('choose', t.dataset.id)); break;
      case 'bt-disconnect': void host.act(() => host.luma.bluetooth('disconnect')); break;
      case 'bt-capture': void host.act(() => host.luma.bluetooth('capture')); break;
      case 'bt-video-source': if (r?.video) send({ kind: 'video', movie: on, whole: r.video.whole, saturation: Math.max(1, r.video.saturation) }); break;
      case 'bt-video-area': if (r?.video) send({ kind: 'video', movie: r.video.movie, whole: on, saturation: Math.max(1, r.video.saturation) }); break;
      case 'bt-dv-content': if (r?.groupArea !== undefined) send({ kind: 'groupVideo', whole: r.groupArea === 0, movie: on }); break;
      case 'bt-dv-area': if (r?.groupContent !== undefined) send({ kind: 'groupVideo', whole: on, movie: r.groupContent === 1 }); break;
    }
  });
  let colorTimer: ReturnType<typeof setTimeout> | undefined;
  document.addEventListener('input', (event) => {
    const el = event.target as HTMLInputElement;
    if (el.dataset.action !== 'bt-color') return;
    // Dragging in the picker sends only where it settles.
    clearTimeout(colorTimer);
    colorTimer = setTimeout(() => send({ kind: 'color', rgb: fromHex(el.value) }), 200);
  });
  document.addEventListener('change', (event) => {
    const el = event.target as HTMLInputElement, n = Number(el.value), r = host.snap()?.bluetooth.readback;
    switch (el.dataset.action) {
      case 'bt-power': send({ kind: 'power', on: el.checked }); break;
      case 'bt-brightness': send({ kind: 'brightness', value: n }); break;
      case 'bt-video-sat': if (r?.video) send({ kind: 'video', movie: r.video.movie, whole: r.video.whole, saturation: n }); break;
      case 'bt-dv-enabled': send({ kind: 'groupEnabled', on: el.checked }); break;
      case 'bt-dv-sat': send({ kind: 'groupSaturation', value: n }); break;
    }
  });
}

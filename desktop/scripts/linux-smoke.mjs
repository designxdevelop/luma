// Synthetic Linux smoke test. Launches Luma in --demo (synthetic frames only, no real capture, no
// network I/O) and drives the typed window.luma bridge over a loopback-only DevTools socket.
//
//   node scripts/linux-smoke.mjs                                  # dev tree: node_modules/electron + .
//   node scripts/linux-smoke.mjs --app release-linux/linux-unpacked/luma
//   node scripts/linux-smoke.mjs --app /app/luma -- --disable-setuid-sandbox   # extra Chromium args after --
//
// Needs a display (CI: xvfb-run -a node scripts/linux-smoke.mjs ...). Never passes --no-sandbox and
// refuses to run if asked to. Exit 0 = every check passed; otherwise the failing check is printed.

import { spawn } from 'node:child_process';
import { createConnection } from 'node:net';
import { createRequire } from 'node:module';

const argv = process.argv.slice(2);
const dash = argv.indexOf('--');
const own = dash < 0 ? argv : argv.slice(0, dash);
const extra = dash < 0 ? [] : argv.slice(dash + 1);
const appIndex = own.indexOf('--app');
const app = appIndex >= 0 ? own[appIndex + 1] : undefined;
if (extra.some((a) => /no-sandbox/i.test(a))) {
  console.error('linux-smoke: refusing --no-sandbox. Use the setuid chrome-sandbox or --disable-setuid-sandbox (user-namespace sandbox).');
  process.exit(2);
}
if (!process.getuid || process.getuid() === 0) {
  console.error('linux-smoke: do not run as root; Chromium needs a sandbox and root requires --no-sandbox.');
  process.exit(2);
}

const command = app ?? createRequire(import.meta.url)('electron');
const args = [...(app ? [] : ['.']), '--demo', '--remote-debugging-port=0', ...extra];
const child = spawn(command, args, { stdio: ['ignore', 'ignore', 'pipe'] });
let stderr = '';
let finished = false;
/** Hard exit: kills the app first, never lets a pending await keep the process alive. */
const exit = (code) => {
  if (finished) return;
  finished = true;
  try { child.kill('SIGKILL'); } catch { /* already gone */ }
  process.exit(code);
};
const fail = (message) => { console.error(`FAIL: ${message}`); exit(1); };
setTimeout(() => fail(`timed out after 120s\n${stderr.slice(-1500)}`), 120_000);
child.on('exit', (code, signal) => fail(`app exited before the checks finished (code ${code}, signal ${signal})\n${stderr.slice(-1500)}`));
child.on('error', (error) => fail(`could not start ${command}: ${error.message}`));

const wsPort = await new Promise((resolve) => {
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
    const m = /DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//.exec(stderr);
    if (m) resolve(Number(m[1]));
  });
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let page;
for (let i = 0; i < 100 && !page; i++) {
  try {
    const list = await (await fetch(`http://127.0.0.1:${wsPort}/json/list`)).json();
    page = list.find((t) => t.type === 'page' && t.url.startsWith('file://') && t.url.endsWith('/index.html'));
  } catch { /* not ready */ }
  if (!page) await sleep(200);
}
if (!page) fail('renderer page never appeared');

const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve) => { socket.onopen = resolve; socket.onerror = () => fail('CDP socket error'); });
let nextId = 1;
const waiting = new Map();
socket.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  const w = waiting.get(msg.id);
  if (w) { waiting.delete(msg.id); msg.error ? w.reject(new Error(msg.error.message)) : w.resolve(msg.result); }
};
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++;
  waiting.set(id, { resolve, reject });
  socket.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (expression, userGesture = false) => {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
};
const view = async () => (await evaluate('window.luma.snapshot()')).sync;
const click = (selector) => evaluate(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return false; el.click(); return true; })()`, true);
const until = async (what, predicate, ms = 15_000) => {
  const end = Date.now() + ms;
  for (;;) {
    const value = await predicate();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(150);
  }
};

const checks = [];
const check = (name, ok, detail = '') => { checks.push({ name, ok }); console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : ` ${detail}`}`); };

try {
  await until('renderer bridge', () => evaluate('document.readyState === "complete" && !!window.luma'));
  check('renderer loaded with the preload bridge (sandboxed, no Node)', await evaluate('typeof window.luma?.snapshot === "function" && typeof require === "undefined" && typeof process === "undefined"'));

  const snap = await evaluate('window.luma.snapshot()');
  check('demo mode with a synthetic home', snap.demo === true && snap.devices.length > 0);
  check('sync is synthetic and idle at launch', snap.sync.synthetic === true && snap.sync.phase === 'idle');

  // Demo must not open the webhook listener.
  const listening = await new Promise((resolve) => {
    const s = createConnection({ host: '127.0.0.1', port: 8787 });
    s.once('connect', () => { s.destroy(); resolve(true); });
    s.once('error', () => resolve(false));
  });
  check('webhook port 8787 not listening in demo', listening === false);

  // Real display capture and audio are refused in demo even with a user gesture.
  for (const [label, constraints] of [['video', '{ video: true }'], ['video+audio', '{ video: true, audio: true }']]) {
    const outcome = await evaluate(`navigator.mediaDevices.getDisplayMedia(${constraints}).then(s => { s.getTracks().forEach(t => t.stop()); return 'GRANTED'; }, e => e.name)`, true);
    check(`getDisplayMedia(${label}) is refused in demo`, outcome !== 'GRANTED', String(outcome));
  }

  // Real UI flow: the actual FramePump and module worker process generated synthetic frames.
  check('open Screen Sync', await click('[data-action="view"][data-view="sync"]'));
  await until('sources button', () => evaluate('!!document.querySelector(\'[data-action="sync-sources"]:not([disabled])\')'));
  await click('[data-action="sync-sources"]');
  const sourceName = await until('source list', () => evaluate('document.querySelector(\'input[data-action="sync-source"]\')?.closest("label")?.textContent?.trim()'));
  check('only synthetic sources offered', await evaluate('[...document.querySelectorAll(\'input[data-action="sync-source"]\')].every(i => /synthetic/i.test(i.closest("label").textContent))'), sourceName);
  await click('input[data-action="sync-source"]');
  const lightId = await until('eligible light', () => evaluate('document.querySelector(\'input[data-action="sync-light"]\')?.dataset.id'));
  const before = (await evaluate('window.luma.snapshot()')).devices.find((d) => d.id === lightId);
  await click('input[data-action="sync-light"]');
  await until('Start enabled', () => evaluate('!!document.querySelector(\'[data-action="sync-start"]:not([disabled])\')'));
  await click('[data-action="sync-start"]');
  const running = await until('running with frames processed by the worker', async () => { const v = await view(); return v.phase === 'running' && v.stats.frames > 0 ? v : false; }, 30_000);
  check('running: worker produced frames', running.synthetic === true && running.stats.frames > 0, JSON.stringify(running.stats));
  const streamed = await until('a requested color', async () => (await view()).lights.find((l) => l.id === lightId)?.requestedRGB !== undefined, 8_000).then(() => true, () => false);
  check('stream requested a color for the chosen light', streamed, JSON.stringify(await view()));

  await click('[data-action="sync-pause"]');
  await until('paused', async () => (await view()).phase === 'paused');
  await sleep(600);
  const p1 = (await view()).stats.frames;
  await sleep(1000);
  check('pause: no frames while paused', (await view()).stats.frames === p1, `frames ${p1}`);
  await click('[data-action="sync-resume"]');
  await until('running again', async () => (await view()).phase === 'running');
  await until('frames advance after resume', async () => (await view()).stats.frames > p1, 15_000);
  check('resume: frames advance again', true);

  await click('[data-action="sync-stop"]');
  await until('idle', async () => (await view()).phase === 'idle');
  await sleep(600);
  const s1 = (await view()).stats;
  await sleep(1500);
  const s2 = (await view()).stats;
  check('stop: counters stable (nothing sampled or sent afterwards)', s1.frames === s2.frames && s1.sent === s2.sent, `${JSON.stringify(s1)} -> ${JSON.stringify(s2)}`);
  const stale = await evaluate('window.luma.syncFrame("stale-token", 1, 9999, { full: [0.5, 0.5, 0.5], left: [0.5, 0.5, 0.5], right: [0.5, 0.5, 0.5], top: [0.5, 0.5, 0.5], bottom: [0.5, 0.5, 0.5] })');
  check('stop: a stale frame is rejected', stale === false);
  const after = (await evaluate('window.luma.snapshot()')).devices.find((d) => d.id === lightId);
  check('stream never rewrote the light\'s confirmed state', before.rgb === after.rgb && before.brightness === after.brightness && before.power === after.power, `${before.rgb}/${before.brightness} -> ${after.rgb}/${after.brightness}`);
  // Regression: a renderer reload while paused must end the session (no orphan grant, no stale colors).
  const key = await evaluate('window.luma.syncSources().then(list => list[0]?.key)');
  const light = (await evaluate('window.luma.snapshot()')).sync.eligibility.find((e) => e.eligible)?.id;
  check('reload regression: synthetic source and light available', !!key && !!light);
  if (key && light) {
    await evaluate(`window.luma.syncStart(${JSON.stringify(key)}, [{ id: ${JSON.stringify(light)}, region: 'full' }])`);
    await evaluate('window.luma.syncPause()');
    check('reload regression: session paused before reload', (await view()).phase === 'paused');
    await evaluate('window.__lumaSmokeMarker = 1');
    await send('Page.reload');
    await until('fresh bridge after reload', () => evaluate('document.readyState === "complete" && !!window.luma && window.__lumaSmokeMarker === undefined').catch(() => false));
    const after = await until('idle after reload', async () => { const v = await view(); return v.phase === 'idle' ? v : false; }, 10_000).catch(() => undefined);
    check('reload regression: paused session ended by the reload', after?.phase === 'idle', JSON.stringify(await view()));
  }
  check('no video/camera tracks remain', await evaluate('document.querySelectorAll("video").length === 0 || [...document.querySelectorAll("video")].every(v => !v.srcObject)'));
} catch (error) {
  check('smoke script ran to completion', false, String(error?.stack ?? error));
}

const failed = checks.filter((c) => !c.ok);
console.log(`\n${checks.length - failed.length}/${checks.length} checks passed (synthetic demo only; no real capture, no real lights).`);
exit(failed.length ? 1 : 0);

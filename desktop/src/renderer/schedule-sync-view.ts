// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// "Run schedules on [computer]": setup, pairing and sync health. Buttons carry
// data-action="ss" + data-op (a ScheduleSyncAction); app.ts forwards them to main.

import type { ScheduleSyncView, SceneSchedule } from '../shared/types';
import { esc, relativeTime } from './ui.js';

const btn = (op: string, label: string, extra = '') => `<button data-action="ss" data-op="${op}" ${extra}>${esc(label)}</button>`;
const FOOTNOTE = '<p class="hint">Shared: scenes, schedules, on/off and pause. Not shared: what your lights are showing right now. The computer that runs schedules must be on, awake and running Luma (the tray is fine); times due while it sleeps are skipped. Changes reach it over your home network.</p>';

function pairField(label: string): string {
  return `<div class="row"><label for="ss-code">${esc(label)}</label><input id="ss-code" type="text" spellcheck="false" autocomplete="off" placeholder="luma1/…" aria-label="Pairing code">${btn('pair', 'Pair')}</div>
    <p class="hint">On the computer that runs schedules: Automations › Shared schedules › copy its pairing code.</p>`;
}

export function scheduleSyncBlock(v: ScheduleSyncView): string {
  const notices = v.notices.length ? `${v.notices.map((n) => `<p class="hint warn">${esc(n)}</p>`).join('')}${btn('dismiss', 'Dismiss', 'class="ghost"')}` : '';
  let body: string;
  if (!v.available) body = `<p class="hint">${v.role === 'off' ? 'Shared schedules need secure storage (Windows DPAPI or a Linux keyring) and are off in the demo.' : 'Secure storage is unavailable.'}</p>`;
  else if (v.role === 'runner' && v.runner) {
    const r = v.runner;
    if (r.retiredTo) body = `<p><strong>Schedules moved to ${esc(r.retiredTo)}.</strong> This computer stopped running them.</p>${pairField(`Pair with ${r.retiredTo}`)}<div class="actions">${btn('off', 'Turn off sharing', 'class="danger"')}</div>`;
    else body = `<p><strong>${r.waitingFor ? `Waiting for ${esc(r.waitingFor)} to stop running schedules. Nothing runs until it confirms.` : 'Schedules run on this computer.'}</strong></p>
      <p class="sub">${esc(r.status)}</p>
      ${r.pairingCodes.length ? r.pairingCodes.map((c) => `<div class="row"><code class="pairing">${esc(c)}</code>${btn('copyCode', 'Copy', `data-code="${esc(c)}"`)}</div>`).join('') : '<p class="hint warn">No network address found, so there is no pairing code yet.</p>'}
      ${r.clients.length ? `<h3>Paired devices</h3><ul class="plain">${r.clients.map((c) => `<li>${esc(c.name)} · ${esc(c.platform)} · last seen ${esc(relativeTime(c.lastSeen))}</li>`).join('')}</ul>` : '<p class="hint">No devices have paired yet.</p>'}
      <div class="row"><label for="ss-awake">Keep this computer awake while it runs schedules</label><input id="ss-awake" type="checkbox" role="switch" class="switch" data-action="ss-awake" ${r.keepAwake ? 'checked' : ''}></div>
      <p class="hint">Prevents idle sleep only; closing a laptop lid or choosing Sleep still stops schedules.</p>
      <div class="actions">${btn('rotate', 'New pairing code')}${btn('off', 'Turn off sharing', 'class="danger"')}</div>`;
  } else if (v.role === 'paired' && v.paired) {
    const p = v.paired;
    body = `<p><strong>Schedules run on ${esc(p.runnerName)}.</strong> This computer doesn't run them.</p>
      ${p.moved ? `<p class="hint warn">${esc(p.moved)}</p>${pairField('Pair with the new computer')}` : p.lastError ? `<p class="hint warn">Not reachable: ${esc(p.lastError)}</p>` : ''}
      ${p.lastSync ? `<p class="sub">Last synced ${esc(relativeTime(p.lastSync))}.</p>` : ''}
      ${p.unsent ? `<p class="hint warn">${p.unsent} change${p.unsent === 1 ? '' : 's'} not yet delivered. They're sent when the runner is reachable; one that conflicts with a newer change there is dropped and you'll see why.</p>` : ''}
      ${p.runnerTimeZone && p.runnerTimeZone !== v.timeZone ? `<p class="hint warn">Times are in ${esc(p.runnerName)}'s time zone (${esc(p.runnerTimeZone)}).</p>` : ''}
      <div class="actions">${btn('syncNow', 'Sync now')}${btn('takeOver', 'Run schedules here instead')}${btn('off', 'Unpair', 'class="danger"')}</div>`;
  } else {
    body = `<p class="sub">Run your schedules on this computer and change or pause them from your iPhone, iPad or other computers. Or pair with the computer that already runs them.</p>
      <div class="actions">${btn('runHere', 'Run schedules on this computer', 'class="primary"')}</div>${pairField('Pair with a computer')}`;
  }
  return `<section class="card-block" aria-labelledby="ss-title"><h2 id="ss-title">Shared schedules</h2>${body}${notices}${FOOTNOTE}</section>`;
}

/** Status line under a schedule: pause state and what the runner last observed (telemetry, not settings). */
export function scheduleSyncLine(v: ScheduleSyncView, sch: SceneSchedule): string {
  const paused = sch.pausedUntil && sch.pausedUntil > Date.now()
    ? `<span class="hint">Paused until ${esc(new Date(sch.pausedUntil).toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }))}</span>${btn('resume', 'Resume', `data-id="${esc(sch.id)}"`)}`
    : `${btn('pause', 'Pause until tomorrow', `class="ghost" data-id="${esc(sch.id)}" data-days="1"`)}${btn('pause', 'Pause a week', `class="ghost" data-id="${esc(sch.id)}" data-days="7"`)}`;
  const runs = v.role === 'runner' ? v.runner?.runs : v.role === 'paired' ? v.paired?.runs : undefined;
  const r = runs?.find((x) => x.scheduleID.toUpperCase() === sch.id.toUpperCase());
  const where = v.role === 'runner' ? 'this computer' : v.paired?.runnerName ?? 'the runner';
  const when = r ? new Date(r.at).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
  const report = !r ? '' : ({
    completed: `Ran on ${where} ${when}. Sent to the lights, not confirmed by them.`,
    started: `Started on ${where} ${when}.`, running: `Started on ${where} ${when}.`,
    paused: `Skipped on ${where} ${when}: paused.`,
    missed: `Missed on ${where} ${when}. ${r.detail ?? ''}`,
  } as Record<string, string>)[r.status] ?? `Didn't run on ${where} ${when}: ${r.detail ?? r.status}`;
  return `<span class="sync-line">${paused}${report ? `<span class="hint ${['completed', 'started', 'running', 'paused'].includes(r!.status) ? '' : 'warn'}">${esc(report)}</span>` : ''}</span>`;
}

export function scheduleSyncSubtitle(v: ScheduleSyncView): string {
  if (v.role === 'paired') return `Schedules run on ${v.paired?.runnerName ?? 'the paired computer'}, even while Luma is closed here. Missed times are skipped.`;
  if (v.role === 'runner' && !v.mayExecute) return 'This computer doesn\'t run schedules right now. See Shared schedules below.';
  return 'Schedules run while Luma is open (including in the tray) and the PC is awake. Missed times are skipped.';
}

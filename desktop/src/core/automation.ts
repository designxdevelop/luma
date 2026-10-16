// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// One-at-a-time scene runner and local-time schedules.

import { randomUUID } from 'node:crypto';
import type { AutomationRun, LightScene, SceneSchedule, SceneStep } from '../shared/types';
import { LumaError, message, safeInt } from './model';

export const RUN_HISTORY_LIMIT = 100;

export class SceneRunner {
  readonly runs: AutomationRun[] = [];
  private current?: { sceneID: string; controller: AbortController };

  constructor(private readonly deps: {
    /** Sends one step; must reject on failure and honor the abort signal while queued. */
    send(step: SceneStep, signal: AbortSignal): Promise<void>;
    changed(): void;
    log(message: string, isError?: boolean): void;
    sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
  }) {}

  get runningSceneID(): string | undefined { return this.current?.sceneID; }

  /** The caller validates the whole scene first. Returns the run ID without awaiting completion. */
  start(scene: LightScene): string {
    if (this.current) throw new LumaError('A scene is already running. Stop it before starting another.', 409);
    const run: AutomationRun = { id: randomUUID(), sceneID: scene.id, name: scene.name, status: 'running', startedAt: Date.now() };
    this.runs.unshift(run);
    this.runs.splice(RUN_HISTORY_LIMIT);
    const controller = new AbortController();
    this.current = { sceneID: scene.id, controller };
    this.deps.log(`Running scene: ${scene.name}.`);
    this.deps.changed();
    void this.execute(scene, run, controller.signal).finally(() => {
      if (this.current?.controller === controller) this.current = undefined;
      this.deps.changed();
    });
    return run.id;
  }

  /** Cancels the running scene. Commands already sent are not undone. */
  stop(): void { this.current?.controller.abort(); }

  private async execute(scene: LightScene, run: AutomationRun, signal: AbortSignal): Promise<void> {
    const sleep = this.deps.sleep ?? abortableSleep;
    try {
      for (const step of scene.steps) {
        if (signal.aborted) throw abort();
        if (step.delayMilliseconds > 0) await sleep(step.delayMilliseconds, signal);
        if (signal.aborted) throw abort();
        await this.deps.send(step, signal);
      }
      this.finish(run, 'completed');
      this.deps.log(`Scene finished: ${scene.name}.`);
    } catch (error) {
      if (signal.aborted) {
        this.finish(run, 'cancelled');
        this.deps.log(`Scene stopped: ${scene.name}. Commands already sent stay applied.`);
      } else {
        this.finish(run, 'failed', message(error));
        this.deps.log(`Scene failed: ${message(error)}`, true);
      }
    }
  }

  private finish(run: AutomationRun, status: AutomationRun['status'], error?: string): void {
    run.status = status;
    run.finishedAt = Date.now();
    if (error) run.error = error;
  }
}

function abort(): Error { const e = new Error('Cancelled'); e.name = 'AbortError'; return e; }

export function abortableSleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(abort()); return; }
    const timer = setTimeout(() => { signal.removeEventListener('abort', onAbort); resolve(); }, ms);
    const onAbort = () => { clearTimeout(timer); reject(abort()); };
    signal.addEventListener('abort', onAbort, { once: true });
  });
}

// ---- Schedules (local time zone; 1 = Sunday … 7 = Saturday) ----

export function minuteKey(date: Date): string {
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}-${date.getHours()}-${date.getMinutes()}`;
}

/** True only during the scheduled local minute, once. Missed minutes (asleep/closed) are skipped. */
export function shouldRun(schedule: SceneSchedule, date: Date): boolean {
  return schedule.enabled && date.getHours() === schedule.hour && date.getMinutes() === schedule.minute
    && schedule.weekdays.includes(date.getDay() + 1) && schedule.lastRunMinute !== minuteKey(date);
}

/** Next local occurrence strictly after `from`, or undefined when disabled/no weekdays. DST-safe via local Date math. */
export function nextOccurrence(schedule: SceneSchedule, from: Date): Date | undefined {
  if (!schedule.enabled || schedule.weekdays.length === 0) return undefined;
  for (let offset = 0; offset <= 8; offset++) {
    const candidate = new Date(from.getFullYear(), from.getMonth(), from.getDate() + offset, schedule.hour, schedule.minute, 0, 0);
    if (candidate.getHours() !== schedule.hour || candidate.getMinutes() !== schedule.minute) continue; // skipped by DST
    if (candidate > from && schedule.weekdays.includes(candidate.getDay() + 1)) return candidate;
  }
  return undefined;
}

export function validateSchedule(input: unknown, sceneIDs: string[]): SceneSchedule {
  const s = input as Partial<SceneSchedule> | null;
  if (!s || typeof s !== 'object') throw new LumaError('Invalid schedule.');
  const hour = safeInt(s.hour, 0, 23), minute = safeInt(s.minute, 0, 59);
  if (hour === undefined || minute === undefined) throw new LumaError('Choose a valid time.');
  if (!Array.isArray(s.weekdays) || s.weekdays.length > 7) throw new LumaError('Choose weekdays.');
  const weekdays = [...new Set(s.weekdays.map((d) => safeInt(d, 1, 7)))];
  if (weekdays.some((d) => d === undefined)) throw new LumaError('Weekdays must be 1–7.');
  if (typeof s.sceneID !== 'string' || !sceneIDs.includes(s.sceneID)) throw new LumaError('Choose a saved scene.');
  return {
    id: typeof s.id === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(s.id) ? s.id : randomUUID(),
    sceneID: s.sceneID, hour, minute,
    weekdays: (weekdays as number[]).sort((a, b) => a - b),
    enabled: s.enabled !== false,
  };
}

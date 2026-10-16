// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Webhook API routes. Pure request → response mapping over an AutomationHost; all hardware
// work happens (asynchronously) behind host.runScene.

import { randomUUID } from 'node:crypto';
import type { AutomationRun, CapabilityCommand, LightDevice, LightScene, SceneStep } from '../shared/types';
import type { HttpRequest, HttpResponse } from './http';
import { LumaError, isObject, parseAction } from './model';

export interface AutomationHost {
  readonly demo: boolean;
  /** Confirmed state only (no pending overlay). */
  devices(): LightDevice[];
  scenes(): LightScene[];
  /** Newest first, at most 100. */
  runs(): AutomationRun[];
  /** Validates the whole scene (throws LumaError) and starts it; throws LumaError(409) if busy. Returns the run ID without awaiting completion. */
  runScene(scene: LightScene): string;
}

const NOTE = 'Commands run asynchronously. Completed means submitted, not hardware-confirmed. Cancelling does not undo commands already sent.';

const ok = (body: unknown, status = 200): HttpResponse => ({ status, body });
const accepted = (runID: string): HttpResponse => ok({ accepted: true, runID, statusURL: `/v1/runs/${runID}`, note: NOTE }, 202);

const publicDevice = (d: LightDevice) => ({
  id: d.id, sku: d.sku, name: d.name, room: d.room, capabilities: d.capabilities,
  power: d.power, brightness: d.brightness, rgb: d.rgb, colorTemperature: d.colorTemperature,
  online: d.online, lastSeen: d.lastSeen,
});

function parseBody(req: HttpRequest, allowEmpty = false): { [key: string]: unknown } {
  const text = req.body.toString('utf8');
  if (allowEmpty && text.trim() === '') return {};
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { throw new LumaError('Body must be valid JSON.'); }
  if (!isObject(parsed)) throw new LumaError('Body must be a JSON object.');
  return parsed;
}

function scene(name: string, steps: SceneStep[]): LightScene {
  return { id: randomUUID(), name, icon: 'sparkles', steps };
}

const step = (deviceID: string, command: CapabilityCommand): SceneStep => ({ id: randomUUID(), deviceID, command, delayMilliseconds: 0 });

type Route = { method: 'GET' | 'POST'; pattern: string[]; run: (params: string[], req: HttpRequest) => HttpResponse };

export function createApiHandler(host: AutomationHost): (req: HttpRequest) => Promise<HttpResponse> {
  const routes: Route[] = [
    { method: 'GET', pattern: ['health'], run: () => ok({ status: 'ok', demo: host.demo }) },
    { method: 'GET', pattern: ['v1', 'devices'], run: () => ok(host.devices().map(publicDevice)) },
    { method: 'GET', pattern: ['v1', 'scenes'], run: () => ok(host.scenes()) },
    { method: 'GET', pattern: ['v1', 'runs'], run: () => ok(host.runs()) },
    {
      method: 'GET', pattern: ['v1', 'runs', ':id'],
      run: ([id]) => {
        const run = host.runs().find((r) => r.id === id);
        return run ? ok(run) : ok({ error: 'Run not found.' }, 404);
      },
    },
    {
      method: 'POST', pattern: ['v1', 'scenes', ':id', 'run'],
      run: ([id], req) => {
        parseBody(req, true);
        const found = host.scenes().find((s) => s.id === id);
        return found ? accepted(host.runScene(found)) : ok({ error: 'Scene not found.' }, 404);
      },
    },
    {
      method: 'POST', pattern: ['v1', 'devices', ':id', 'commands'],
      run: ([id], req) => {
        const body = parseBody(req);
        const keys = Object.keys(body);
        if (keys.length !== 3 || !('type' in body) || !('instance' in body) || !('value' in body)) throw new LumaError('Command must have exactly type, instance and value.');
        if (typeof body.type !== 'string' || typeof body.instance !== 'string') throw new LumaError('Command type and instance must be strings.');
        if (!host.devices().some((d) => d.id === id)) return ok({ error: 'Device not found.' }, 404);
        const command: CapabilityCommand = { type: body.type, instance: body.instance, value: body.value as CapabilityCommand['value'] };
        return accepted(host.runScene(scene('Webhook command', [step(id!, command)])));
      },
    },
    {
      method: 'POST', pattern: ['v1', 'actions'],
      run: (_, req) => {
        const { deviceIDs, commands } = parseAction(parseBody(req), host.devices());
        // Command-major so every light gets each change before the next command starts.
        const steps = commands.flatMap((command) => deviceIDs.map((deviceID) => step(deviceID, command)));
        return accepted(host.runScene(scene('Webhook action', steps)));
      },
    },
  ];

  return async (req) => {
    try {
      let segments: string[];
      try { segments = req.path.split('/').slice(1).map(decodeURIComponent); } catch { throw new LumaError('Malformed percent-encoding in path.'); }
      let pathMatched = false;
      for (const route of routes) {
        if (route.pattern.length !== segments.length) continue;
        const params: string[] = [];
        const match = route.pattern.every((part, i) => {
          if (part.startsWith(':')) { params.push(segments[i]!); return true; }
          return part === segments[i];
        });
        if (!match) continue;
        pathMatched = true;
        if (route.method === req.method) return route.run(params, req);
      }
      return pathMatched ? ok({ error: 'Method not allowed.' }, 405) : ok({ error: 'Not found.' }, 404);
    } catch (error) {
      if (error instanceof LumaError) return ok({ error: error.message }, error.status);
      return ok({ error: 'Internal error.' }, 500);
    }
  };
}

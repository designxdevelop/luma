import test from 'node:test';
import assert from 'node:assert/strict';
import {
  LinuxLockMonitor, classifyWatchLine, createLinuxLockMonitor, linuxLockSupport, lockedHintArgs, parseLockedHint, type LockMonitorDeps, type WatchHandlers,
} from '../main/linux-lock';
import { CaptureGrants } from '../main/sync';

const GNOME = { XDG_CURRENT_DESKTOP: 'ubuntu:GNOME', XDG_SESSION_ID: '3' };

/** Fake command, fake subscription, fake timers: no D-Bus, no processes. */
function rig(opts: { env?: Record<string, string | undefined>; needed?: () => boolean; autoReady?: boolean } = {}) {
  const r = {
    reads: [] as string[],
    answer: (): string | Promise<string> => 'no\n',
    watchStarts: 0,
    watchStops: 0,
    handlers: undefined as WatchHandlers | undefined,
    timers: [] as Array<{ fn: () => void; ms: number; live: boolean }>,
    locks: [] as string[],
    monitor: undefined as unknown as LinuxLockMonitor,
    tick: async () => { for (const t of r.timers.filter((x) => x.live && x.ms === 500)) { t.live = false; t.fn(); } await flush(); },
    expireReady: () => { for (const t of r.timers.filter((x) => x.live && x.ms === 3000)) { t.live = false; t.fn(); } },
  };
  const deps: LockMonitorDeps = {
    support: linuxLockSupport(opts.env ?? GNOME),
    read: async (id) => { r.reads.push(id); return r.answer(); },
    watch: (h) => {
      r.watchStarts++; r.handlers = h;
      if (opts.autoReady !== false) queueMicrotask(() => h.ready());
      return () => { r.watchStops++; };
    },
    schedule: (fn, ms) => { const t = { fn, ms, live: true }; r.timers.push(t); return () => { t.live = false; }; },
    needed: opts.needed,
  };
  r.monitor = new LinuxLockMonitor(deps);
  r.monitor.onLock((kind) => r.locks.push(kind));
  return r;
}
const flush = async () => { for (let i = 0; i < 10; i++) await new Promise((res) => setImmediate(res)); };

test('support: only GNOME/KDE with a valid session id, argv fixed, no shell input', () => {
  assert.deepEqual(linuxLockSupport({ XDG_CURRENT_DESKTOP: 'ubuntu:GNOME' }), { ok: true, sessionId: 'self' });
  assert.deepEqual(linuxLockSupport({ XDG_CURRENT_DESKTOP: 'KDE', XDG_SESSION_ID: 'c2' }), { ok: true, sessionId: 'c2' });
  for (const env of [{}, { XDG_CURRENT_DESKTOP: 'XFCE' }, { XDG_CURRENT_DESKTOP: 'X-Cinnamon' }, { XDG_CURRENT_DESKTOP: 'sway' }]) {
    assert.equal(linuxLockSupport(env).ok, false, JSON.stringify(env));
  }
  for (const id of ['1; rm -rf /', '$(id)', 'a b', '--help', 'x'.repeat(33), '../x\n']) {
    assert.equal(linuxLockSupport({ XDG_CURRENT_DESKTOP: 'GNOME', XDG_SESSION_ID: id }).ok, false, id);
  }
  assert.deepEqual(lockedHintArgs('3'), ['show-session', '3', '-p', 'LockedHint', '--value']);
});

test('parseLockedHint: only yes/no are answers', () => {
  assert.equal(parseLockedHint('no\n'), 'unlocked');
  assert.equal(parseLockedHint('yes\n'), 'locked');
  for (const bad of ['', 'maybe', 'n/a', 'LockedHint=no extra']) assert.equal(parseLockedHint(bad), 'unavailable', bad);
});

test('gating: no observer for demo or non-Linux; nothing spawns for an unsupported desktop', async () => {
  assert.equal(createLinuxLockMonitor({ real: false, platform: 'linux', env: GNOME }), undefined);
  assert.equal(createLinuxLockMonitor({ real: true, platform: 'darwin', env: GNOME }), undefined);
  assert.equal(createLinuxLockMonitor({ real: true, platform: 'win32', env: GNOME }), undefined);
  const m = createLinuxLockMonitor({ real: true, platform: 'linux', env: {} });
  assert.ok(m);
  await assert.rejects(() => m.check(), /GNOME or KDE/); // refused before any process is started
  assert.equal(m.unlocked, false);
  m.dispose();
});

test('first read must affirm unlocked, and only after the subscription is established', async () => {
  const r = rig({ autoReady: false });
  const pending = r.monitor.check();
  await flush();
  assert.equal(r.reads.length, 0, 'no read before the subscription is ready');
  r.handlers!.ready();
  await pending;
  assert.deepEqual(r.reads, ['3']);
  assert.equal(r.monitor.unlocked, true);
});

test('unsupported desktop, locked, unknown output, read error and timeout all refuse', async () => {
  const unsupported = rig({ env: { XDG_CURRENT_DESKTOP: 'XFCE' } });
  await assert.rejects(() => unsupported.monitor.check(), { status: 501 });
  assert.equal(unsupported.watchStarts, 0);
  assert.equal(unsupported.reads.length, 0);

  const locked = rig(); locked.answer = () => 'yes\n';
  await assert.rejects(() => locked.monitor.check(), { status: 409 });
  assert.deepEqual(locked.locks, ['locked']);

  for (const answer of [() => 'garbage', () => '', () => Promise.reject(new Error('ENOENT loginctl'))]) {
    const r = rig(); r.answer = answer;
    await assert.rejects(() => r.monitor.check(), { status: 503 });
    assert.equal(r.monitor.unlocked, false);
    assert.deepEqual(r.locks, ['unavailable']);
  }

  const never = rig({ autoReady: false }); // subscription never becomes ready
  const p = never.monitor.check();
  const rejected = assert.rejects(p, { status: 503 });
  await flush(); never.expireReady();
  await rejected;
  assert.equal(never.reads.length, 0);
  assert.equal(never.watchStops, 1);
});

test('lock while a session exists: signal triggers a fresh read, locks once, no automatic restore', async () => {
  const r = rig({ needed: () => true });
  await r.monitor.check();
  r.answer = () => 'yes\n';
  r.handlers!.wake();
  await flush();
  assert.deepEqual(r.locks, ['locked']);
  assert.equal(r.monitor.unlocked, false);
  await r.tick(); await r.tick();
  assert.deepEqual(r.locks, ['locked'], 'repeated locked reads do not re-fire');
  // Unlocking alone changes nothing for a stopped session; only an explicit check() would allow a new one.
  r.answer = () => 'no\n';
  await r.tick();
  assert.deepEqual(r.locks, ['locked']);
  await r.monitor.check();
  assert.equal(r.monitor.unlocked, true);
});

test('polling runs only while needed and stops reading when idle', async () => {
  let active = false;
  const r = rig({ needed: () => active });
  await r.monitor.check();
  const base = r.reads.length;
  await r.tick(); await r.tick();
  assert.equal(r.reads.length, base, 'idle without choices or a session: no polling reads');
  active = true;
  r.answer = () => 'yes\n';
  await r.tick();
  assert.equal(r.reads.length, base + 1);
  assert.deepEqual(r.locks, ['locked']);
});

test('offered choices keep the observer polling (hold) until they expire', async () => {
  let t = 0;
  const r = rig();
  (r.monitor as unknown as { now: () => number }).now = () => t;
  await r.monitor.guard(async () => 'listed');
  const base = r.reads.length;
  r.answer = () => 'yes\n';
  await r.tick();
  assert.equal(r.reads.length, base + 1, 'offered sources: still observing while idle');
  assert.deepEqual(r.locks, ['locked']);
  // After the lock the hold is cleared: nothing offered survives it.
  r.answer = () => 'no\n';
  await r.monitor.check();
  const again = r.reads.length;
  t = 10 * 60_000; await r.tick();
  assert.equal(r.reads.length, again, 'hold expired and nothing active: no polling');
});

test('losing the subscription fails closed and stays closed until re-established', async () => {
  const r = rig({ needed: () => true });
  await r.monitor.check();
  r.handlers!.lost();
  assert.deepEqual(r.locks, ['unavailable']);
  assert.equal(r.monitor.unlocked, false);
  const reads = r.reads.length;
  await r.tick(); await r.tick();
  assert.equal(r.reads.length, reads, 'no polling can resurrect unlocked without a subscription');
  assert.equal(r.monitor.unlocked, false);
  await r.monitor.check(); // user-initiated: new subscription, then a fresh read
  assert.equal(r.watchStarts, 2);
  assert.equal(r.monitor.unlocked, true);
});

test('an unlocked read that finishes after the subscription died is not trusted', async () => {
  const r = rig({ needed: () => true });
  await r.monitor.check();
  let release!: (v: string) => void;
  r.answer = () => new Promise<string>((res) => { release = res; });
  const poll = r.monitor.check().catch((e) => e);
  await flush();
  r.handlers!.lost();
  release('no\n');
  assert.equal(((await poll) as Error).name, 'LumaError');
  assert.equal(r.monitor.unlocked, false);
});

test('pending guarded work is refused if a lock was observed meanwhile (no stale unlocked grant)', async () => {
  const r = rig();
  let secondRead = 0;
  await assert.rejects(() => r.monitor.guard(async (confirm) => {
    r.answer = () => { secondRead++; return 'yes\n'; };
    r.handlers!.wake(); await flush(); // lock lands while enumerating/resolving
    confirm();
    return 'granted';
  }), { status: 409 });
  assert.equal(secondRead, 1);
});

test('older locked result still counts; an older unlocked never overwrites a newer locked', async () => {
  const r = rig({ needed: () => true });
  await r.monitor.check();
  const slow: Array<(v: string) => void> = [];
  r.answer = () => new Promise<string>((res) => { slow.push(res); });
  r.handlers!.wake(); await flush();           // read A in flight
  void (r.monitor as unknown as { readOnce(): Promise<void> }).readOnce(); // read B overlaps (as a check() would)
  await flush();
  slow[1]!('yes\n');                          // newer says locked
  await flush();
  slow[0]!('no\n');                           // older says unlocked: must not win
  await flush();
  assert.deepEqual(r.locks, ['locked']);
  assert.equal(r.monitor.unlocked, false);

  // And the reverse: a newer unlocked, then an older locked, still fails closed.
  const q = rig({ needed: () => true });
  await q.monitor.check();
  const late: Array<(v: string) => void> = [];
  q.answer = () => new Promise<string>((res) => { late.push(res); });
  q.handlers!.wake(); await flush();
  void (q.monitor as unknown as { readOnce(): Promise<void> }).readOnce();
  await flush();
  late[1]!('no\n'); await flush();
  late[0]!('yes\n'); await flush();
  assert.deepEqual(q.locks, ['locked']);
  assert.equal(q.monitor.unlocked, false);
});

test('capture grants: lock revocation cancels in-flight list and resolve (epoch preserved)', async () => {
  const r = rig();
  const sources = [{ id: 'screen:1:0', name: 'Screen', kind: 'screen' as const }];
  let release!: () => void;
  const grants = new CaptureGrants(async () => { await new Promise<void>((res) => { release = res; }); return sources; });
  r.monitor.onLock(() => grants.revoke()); // what capture.ts does
  const listing = r.monitor.guard(() => grants.list());
  const settled = assert.rejects(listing, /cancelled|locked/);
  await flush();
  r.answer = () => 'yes\n';
  r.handlers!.wake(); await flush();           // lock observed while the enumeration is pending
  release();
  await settled;
});

test('dispose stops the subscription and the timers; later signals do nothing', async () => {
  const r = rig({ needed: () => true });
  await r.monitor.check();
  r.monitor.dispose();
  assert.equal(r.watchStops, 1);
  assert.ok(r.timers.every((t) => !t.live));
  const reads = r.reads.length;
  r.answer = () => 'yes\n';
  r.handlers!.wake(); await flush();
  assert.equal(r.reads.length, reads);
  assert.deepEqual(r.locks, []);
  assert.equal(r.monitor.unlocked, false);
  await assert.rejects(() => r.monitor.check(), { status: 503 });
});

test('fast Lock then Unlock: the Lock signal invalidates at once, before any read can say "no"', async () => {
  const r = rig({ needed: () => true });
  const epoch = await r.monitor.check();
  r.answer = () => 'no\n'; // by the time loginctl answers, the PC is already unlocked again
  r.handlers!.locked();
  assert.deepEqual(r.locks, ['locked'], 'revoked synchronously, no read needed');
  await flush();
  assert.throws(() => r.monitor.confirm(epoch), { status: 409 }); // an offered/paused token from before cannot be confirmed
  assert.equal(r.monitor.unlocked, true, 'the later fresh read may re-affirm unlocked for a NEW choice');
});

test('a lock signal while still subscribing refuses that attempt', async () => {
  const r = rig({ autoReady: false });
  const p = r.monitor.check();
  const rejected = assert.rejects(p, { status: 503 });
  await flush();
  r.handlers!.locked();
  await rejected;
  assert.equal(r.reads.length, 0);
  assert.equal(r.watchStops, 1);
});

test('gdbus line classification: Lock/LockedHint=true lock, other lock lines wake, owner loss or change is lost', () => {
  const lock = '/org/freedesktop/login1/session/_32: org.freedesktop.login1.Session.Lock ()';
  const hint = "/org/freedesktop/login1/session/_32: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'LockedHint': <true>}, @as [])";
  const unhint = hint.replace('<true>', '<false>');
  const unlock = '/org/freedesktop/login1/session/_32: org.freedesktop.login1.Session.Unlock ()';
  assert.equal(classifyWatchLine(lock, true), 'locked');
  assert.equal(classifyWatchLine(hint, true), 'locked');
  assert.equal(classifyWatchLine(unhint, true), 'wake');
  assert.equal(classifyWatchLine(unlock, true), 'wake');
  assert.equal(classifyWatchLine('/org/freedesktop/login1/seat/seat0: org.freedesktop.DBus.Properties.PropertiesChanged (...)', true), undefined);
  assert.equal(classifyWatchLine('The name org.freedesktop.login1 is owned by :1.5', false), 'owned');
  assert.equal(classifyWatchLine('The name org.freedesktop.login1 is owned by :1.9', true), 'lost'); // logind restarted
  assert.equal(classifyWatchLine('The name org.freedesktop.login1 does not have an owner', true), 'lost');
  assert.equal(classifyWatchLine('The name org.freedesktop.login1 does not have an owner', false), 'lost');
});

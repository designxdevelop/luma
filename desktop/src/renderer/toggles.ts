// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Effect toggles have no readable state in the Govee API, so the switch shows the latest
// requested value. It survives snapshots; only a failure of the newest request rolls it
// back, to the last value whose write succeeded (off when none did).
// ponytail: "succeeded" is when main resolved the write, in resolution order; a write coalesced
// away before sending also resolves. Exact truth would need main to expose last-sent values.

export class ToggleIntents {
  private readonly entries = new Map<string, { intent: boolean; lastOk?: boolean; seq: number }>();

  value(key: string): boolean { return this.entries.get(key)?.intent ?? false; }

  /** Records a new intent; returns its sequence number for `settle`. */
  request(key: string, on: boolean): number {
    const entry = this.entries.get(key) ?? { intent: on, seq: 0 };
    entry.intent = on;
    entry.seq++;
    this.entries.set(key, entry);
    return entry.seq;
  }

  settle(key: string, seq: number, on: boolean, ok: boolean): void {
    const entry = this.entries.get(key);
    if (!entry) return;
    if (ok) entry.lastOk = on;
    else if (seq === entry.seq) entry.intent = entry.lastOk ?? false; // stale failures are ignored
  }
}

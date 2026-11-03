import Foundation

/// Explicit same-account failover for one schedule. Synced as its own field so
/// older builds that re-encode the schedule definition cannot drop it.
public struct ScheduleCoordination: Codable, Sendable, Equatable {
    public var primary: String
    public var fallback: String?
    /// IANA identifier. Every device computes occurrences in this zone, never its own.
    public var timeZone: String
    /// How late an occurrence may still start. Later runs are skipped, never replayed.
    public var graceSeconds: Int
    public init(primary: String, fallback: String? = nil, timeZone: String = TimeZone.current.identifier, graceSeconds: Int = 600) {
        self.primary = primary; self.fallback = fallback; self.timeZone = timeZone; self.graceSeconds = graceSeconds
    }
}

/// A Luma installation that can run schedules (synced so the other device can pick it).
public struct SchedulerDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Cloud lease for one occurrence. Safety comes from compare-and-swap state
/// transitions: nothing is sent before the holder's own `running` write is
/// confirmed, and only a `claimed` (nothing sent) lease can be taken over.
public struct OccurrenceLease: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case claimed, running, completed, failed, uncertain, cancelled, skipped }
    public var holder: String
    /// Random per attempt, so a re-read after an ambiguous error can tell whether our write landed.
    public var nonce: String
    public var state: State
    public var expiresAt: Date
    public var step: Int
    public var note: String?
    public init(holder: String, nonce: String, state: State, expiresAt: Date, step: Int = 0, note: String? = nil) {
        self.holder = holder; self.nonce = nonce; self.state = state; self.expiresAt = expiresAt; self.step = step; self.note = note
    }
}

public struct FailoverPolicy: Sendable {
    /// The fallback waits this long after the fire time before claiming an unclaimed occurrence.
    public var takeoverDelay: TimeInterval = 90
    public var leaseTTL: TimeInterval = 60
    /// Assumed maximum clock difference between devices; only affects liveness, not exclusion.
    public var skew: TimeInterval = 15
    public var renewBelow: TimeInterval = 30
    public var maxAttempts = 4
    public init() {}
}

public enum ScheduleFailover {
    public enum Role: Sendable { case primary, fallback }

    public static func role(of device: String, in coordination: ScheduleCoordination) -> Role? {
        if coordination.primary == device { return .primary }
        if coordination.fallback == device { return .fallback }
        return nil
    }

    /// Latest scheduled instant at or before `now`, computed in the coordination's zone.
    /// DST: a skipped local time runs at the next existing time; a repeated time runs once, at its first instance.
    public static func fireInstant(_ schedule: SceneSchedule, zone: TimeZone, atOrBefore now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  let fire = calendar.nextDate(after: day.addingTimeInterval(-1), matching: DateComponents(hour: schedule.hour, minute: schedule.minute, second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                  calendar.isDate(fire, inSameDayAs: day), fire <= now,
                  schedule.weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            return fire
        }
        return nil
    }

    /// Deterministic across devices: schedule identity plus the UTC instant.
    public static func occurrenceID(_ scheduleID: UUID, fire: Date) -> String {
        "occ-\(scheduleID.uuidString)-\(Int64(fire.timeIntervalSince1970))"
    }

    public static func mayClaim(_ lease: OccurrenceLease?, device: String, role: Role, fire: Date, now: Date, grace: TimeInterval, policy: FailoverPolicy = .init()) -> Bool {
        guard now >= fire, now <= fire + grace else { return false }
        guard let lease else { return role == .primary || now >= fire + policy.takeoverDelay }
        // Only an expired claim with nothing sent may change hands. Running leases never do.
        return lease.state == .claimed && lease.holder != device && now > lease.expiresAt + policy.skew
    }
}

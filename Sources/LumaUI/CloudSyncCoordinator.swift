import Foundation
import LumaCore

@MainActor protocol CloudSyncExchanging {
    func accountID() async throws -> String
    func exchange(_ pending: [SyncMutation]) async throws -> [SyncMutation]
}
extension CloudSyncTransport: CloudSyncExchanging {}

/// Owns a durable mutation ledger. Cloud values contain configuration, never light telemetry.
@MainActor final class CloudSyncCoordinator {
    struct State: Codable {
        var ledger: SyncLedger
        var baseline: [String: Data]
    }
    private let file: URL
    private let transport: any CloudSyncExchanging
    private var state: State?
    private var exchanging = false
    private var applying = false
    private var task: Task<Void, Never>?
    let snapshot: () throws -> [String: Data]
    let apply: ([String: SyncMutation]) throws -> Void
    let status: (String) -> Void
    var writer: String? { state?.ledger.writer }
    /// Apple Account the synced configuration belongs to; nil until the first exchange.
    var account: String? { state?.ledger.account }

    init(folder: URL, transport: any CloudSyncExchanging = CloudSyncTransport(), snapshot: @escaping () throws -> [String: Data], apply: @escaping ([String: SyncMutation]) throws -> Void, status: @escaping (String) -> Void) {
        self.transport = transport
        file = folder.appending(path: "icloud-sync.json")
        self.snapshot = snapshot; self.apply = apply; self.status = status
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.exchange()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    func changed() {
        guard !applying, state != nil else { return }
        do { try capture(); try save() }
        catch { status("Changes saved locally; iCloud sync needs attention.") }
    }
    private func capture() throws {
        guard var current = state else { return }
        let now = try snapshot()
        for key in Set(now.keys).union(current.baseline.keys) where now[key] != current.baseline[key] {
            guard let slash = key.lastIndex(of: "/") else { continue }
            current.ledger.edit(entity: String(key[..<slash]), field: String(key[key.index(after: slash)...]), value: now[key])
        }
        current.baseline = now; state = current
    }
    private func save() throws {
        guard let state else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func exchange() async {
        guard !exchanging else { return }
        exchanging = true
        defer { exchanging = false }
        do {
            let account = try await transport.accountID()
            if state == nil {
                if FileManager.default.fileExists(atPath: file.path) {
                    state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                } else {
                    // Fetch first: a newly installed device must not overwrite an existing cloud home.
                    let remote = try await transport.exchange([])
                    var ledger = SyncLedger(account: account)
                    ledger.merge(remote, account: account)
                    state = State(ledger: ledger, baseline: [:])
                    applying = true
                    defer { applying = false }
                    try apply(ledger.records)
                    // Preserve local records missing remotely while honoring remote tombstones.
                    try capture(); try save()
                }
            }
            guard state?.ledger.account == account else {
                status("Apple Account changed. Your existing home is preserved; sync is paused.")
                return
            }
            try capture(); try save()
            let pending = Array(state!.ledger.outbox.values)
            let remote = try await transport.exchange(pending)
            guard !Task.isCancelled, try await transport.accountID() == account else { return }
            // Capture edits made while the network request was in flight before merging.
            try capture()
            state!.ledger.merge(remote, account: account)
            for sent in pending where remote.contains(sent) { state!.ledger.acknowledge(sent) }
            try save()
            applying = true
            defer { applying = false }
            try apply(state!.ledger.records)
            state!.baseline = try snapshot()
            try save()
            status("Up to date with iCloud")
        } catch {
            applying = false
            status("Saved on this device. iCloud sync is unavailable.")
        }
    }
}

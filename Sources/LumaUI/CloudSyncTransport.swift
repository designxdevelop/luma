import CloudKit
import CryptoKit
import Foundation
import LumaCore

/// Private configuration transport. Callers own the durable ledger and may only
/// supply configuration or sanitized floor-plan bytes, never credentials.
@MainActor final class CloudSyncTransport {
    static let containerIdentifier = "iCloud.com.designxdevelop.luma"
    private let container = CKContainer(identifier: containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "LumaConfig", ownerName: CKCurrentUserDefaultName)
    private let maximumAssetBytes = 80 * 1024 * 1024

    enum Failure: LocalizedError {
        case unavailable, accountChanged, malformedRecord, oversizedValue, conflictLimit
        var errorDescription: String? {
            switch self {
            case .unavailable: "Sign in to iCloud to sync Luma."
            case .accountChanged: "Your iCloud account changed. Sync was stopped."
            case .malformedRecord: "Luma could not read an iCloud configuration record."
            case .oversizedValue: "This floor-plan image is too large to sync."
            case .conflictLimit: "Luma is waiting for another device's changes. Try syncing again."
            }
        }
    }

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw Failure.unavailable }
        return try await container.userRecordID().recordName
    }

    /// Returns a complete current snapshot, including tombstones. A pending
    /// mutation is acknowledged by the caller only when an equal returned
    /// mutation exists; a newer returned mutation instead wins the merge.
    func exchange(_ pending: [SyncMutation]) async throws -> [SyncMutation] {
        try Task.checkCancellation()
        let account = try await accountID()
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        for mutation in pending {
            try Task.checkCancellation()
            guard try await accountID() == account else { throw Failure.accountChanged }
            try await save(mutation)
        }
        var token: CKServerChangeToken?
        var records: [CKRecord.ID: SyncMutation] = [:]
        repeat {
            try Task.checkCancellation()
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard record.recordType == "LumaMutation" else { continue }
                records[id] = try decode(record)
            }
            for deletion in page.deletions { records.removeValue(forKey: deletion.recordID) }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        guard try await accountID() == account else { throw Failure.accountChanged }
        return Array(records.values)
    }

    private func recordID(_ mutation: SyncMutation) -> CKRecord.ID {
        // Encode both components to avoid collisions between keys containing '/'.
        let source = Data((String(mutation.entity.utf8.count) + ":" + mutation.entity + mutation.field).utf8)
        let name = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func save(_ mutation: SyncMutation) async throws {
        guard mutation.counter <= UInt64(Int64.max), (mutation.value?.count ?? 0) <= maximumAssetBytes else {
            throw Failure.oversizedValue
        }
        let id = recordID(mutation)
        for _ in 0..<5 {
            try Task.checkCancellation()
            var record: CKRecord
            do {
                record = try await database.record(for: id)
                let old = try decode(record)
                guard old.entity == mutation.entity, old.field == mutation.field else { throw Failure.malformedRecord }
                if old.counter > mutation.counter || (old.counter == mutation.counter && old.writer >= mutation.writer) {
                    return
                }
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "LumaMutation", recordID: id)
            }
            record["entity"] = mutation.entity as CKRecordValue
            record["field"] = mutation.field as CKRecordValue
            record["counter"] = NSNumber(value: mutation.counter)
            record["writer"] = mutation.writer as CKRecordValue
            record["deleted"] = NSNumber(value: mutation.value == nil)
            record["value"] = nil
            record["asset"] = nil
            var temporaryFile: URL?
            defer { if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) } }
            if let value = mutation.value {
                if value.count > 500 * 1024 {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try value.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    temporaryFile = url
                    record["asset"] = CKAsset(fileURL: url)
                } else {
                    record["value"] = value as CKRecordValue
                }
            }
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
                guard let saved = result.saveResults[id] else { throw Failure.malformedRecord }
                _ = try saved.get()
                return
            } catch let error as CKError where error.code == .serverRecordChanged || error.code == .batchRequestFailed {
                continue
            }
        }
        throw Failure.conflictLimit
    }

    private func decode(_ record: CKRecord) throws -> SyncMutation {
        guard let entity = record["entity"] as? String, !entity.isEmpty,
              let field = record["field"] as? String, !field.isEmpty,
              let writer = record["writer"] as? String, !writer.isEmpty,
              let counter = record["counter"] as? NSNumber, counter.int64Value >= 0,
              let deleted = record["deleted"] as? NSNumber else { throw Failure.malformedRecord }
        let value: Data?
        if deleted.boolValue { value = nil }
        else if let inline = record["value"] as? Data {
            guard inline.count <= maximumAssetBytes else { throw Failure.oversizedValue }
            value = inline
        } else if let asset = record["asset"] as? CKAsset, let url = asset.fileURL {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= maximumAssetBytes else { throw Failure.oversizedValue }
            // Copy bytes while CKAsset's downloaded file is still alive.
            value = try Data(contentsOf: url)
            guard value!.count <= maximumAssetBytes else { throw Failure.oversizedValue }
        } else { throw Failure.malformedRecord }
        return SyncMutation(entity: entity, field: field, value: value, counter: counter.uint64Value, writer: writer)
    }
}

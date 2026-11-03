import Foundation
import ImageIO
import UniformTypeIdentifiers
import LumaCore

/// Private, local-only assets. UUID names never incorporate imported file paths.
struct FloorPlanStorage {
    let folder: URL
    init(folder: URL) { self.folder = folder.appending(path: "floor-plans") }

    func load() throws -> [FloorPlan] {
        let url = folder.appending(path: "plans.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([FloorPlan].self, from: Data(contentsOf: url))
    }

    func save(_ plans: [FloorPlan]) throws {
        try prepare()
        try write(JSONEncoder.pretty.encode(plans), to: folder.appending(path: "plans.json"))
    }

    /// Rasterizes a bounded thumbnail and removes source metadata (including GPS).
    func importImage(_ data: Data, id: UUID) throws {
        try rasterize(data, id: id, limit: 20 * 1024 * 1024)
    }
    /// Cloud assets are already sanitized PNGs; rasterize again before trusting them locally.
    func importSyncedImage(_ data: Data, id: UUID) throws {
        try rasterize(data, id: id, limit: 80 * 1024 * 1024)
    }
    private func rasterize(_ data: Data, id: UUID, limit: Int) throws {
        guard !data.isEmpty, data.count <= limit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw LumaError.message("Choose an image smaller than 20 MB.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw LumaError.message("Could not prepare the floor-plan image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LumaError.message("Could not save the floor-plan image.") }
        try prepare()
        try write(output as Data, to: imageURL(id))
    }

    func imageURL(_ id: UUID) -> URL { folder.appending(path: id.uuidString + ".png") }
    func removeImage(_ id: UUID) throws {
        let url = imageURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

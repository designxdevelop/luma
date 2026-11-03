import Foundation
import Testing
import LumaCore
@testable import LumaUI

@MainActor struct FloorPlanTests {
    @Test func positionsRejectInvalidCoordinatesAndDecode() throws {
        #expect(throws: (any Error).self) { try FloorPlanPin(deviceID: "lamp", x: .nan, y: 0) }
        #expect(throws: (any Error).self) { try FloorPlanPin(deviceID: "lamp", x: 1.1, y: 0) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FloorPlanPin.self, from: Data(#"{"deviceID":"lamp","x":-1,"y":0}"#.utf8))
        }
        let pin = try FloorPlanPin(deviceID: "lamp", x: 0.25, y: 1)
        #expect(try JSONDecoder().decode(FloorPlanPin.self, from: JSONEncoder().encode(pin)) == pin)
    }

    @Test func plansSurviveReloadAndInvalidImportPreservesImage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = FloorPlanStorage(folder: folder)
        #expect(try storage.load().isEmpty)
        let plan = FloorPlan(name: "Ground floor", pins: [try FloorPlanPin(deviceID: "lamp", x: 0.5, y: 0.2)])
        try storage.save([plan])
        #expect(try storage.load() == [plan])
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try storage.importImage(png, id: plan.id)
        let saved = try Data(contentsOf: storage.imageURL(plan.id))
        #expect(throws: (any Error).self) { try storage.importImage(Data("invalid".utf8), id: plan.id) }
        #expect(try Data(contentsOf: storage.imageURL(plan.id)) == saved)
        try storage.removeImage(plan.id)
        #expect(!FileManager.default.fileExists(atPath: storage.imageURL(plan.id).path))
    }
}

@Test func letterboxedImageCoordinatesExcludeBars() {
    // 2:1 image in a square: bars top and bottom.
    let rect = fittedImageRect(image: CGSize(width: 200, height: 100), in: CGSize(width: 100, height: 100))
    #expect(rect == CGRect(x: 0, y: 25, width: 100, height: 50))
    #expect(normalizedPoint(CGPoint(x: 50, y: 50), in: rect) == CGPoint(x: 0.5, y: 0.5))
    #expect(normalizedPoint(CGPoint(x: 50, y: 10), in: rect) == nil)
    #expect(normalizedPoint(CGPoint(x: 100, y: 75), in: rect) == CGPoint(x: 1, y: 1))
}

@MainActor @Test func pinBrightnessClampsToAdvertisedRange() {
    let caps = [Capability(type: "devices.capabilities.range", instance: "brightness", parameters: .object(["range": .object(["min": .number(5), "max": .number(90)])]))]
    var d = LightDevice(id: "a", sku: "s", name: "n", capabilities: caps, power: true, brightness: 85, online: true)
    #expect(pinBrightness(d, increment: true) == 90)
    d.brightness = 8
    #expect(pinBrightness(d, increment: false) == 5)
    d.online = false
    #expect(pinBrightness(d, increment: true) == nil)
    #expect(pinBrightness(LightDevice(id: "b", sku: "s", name: "n"), increment: true) == nil)
}

@Test(arguments: [(CGFloat(1), CGSize.zero), (2, .zero), (2, CGSize(width: -40, height: 25)), (3.5, CGSize(width: 60, height: -10))])
func zoomTransformRoundTripsAndDropsLandUnderFinger(zoom: CGFloat, offset: CGSize) {
    let size = CGSize(width: 400, height: 300)
    let rect = fittedImageRect(image: CGSize(width: 800, height: 400), in: size) // (0,50,400,200)
    for p in [CGPoint(x: 0, y: 0), CGPoint(x: 123, y: 77), CGPoint(x: 400, y: 300)] {
        let back = unzoomPoint(zoomPoint(p, size: size, zoom: zoom, offset: offset), size: size, zoom: zoom, offset: offset)
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
    }
    // A light dropped where the plan's 25%/75% point is drawn lands at 25%/75%.
    let target = CGPoint(x: rect.minX + 0.25 * rect.width, y: rect.minY + 0.75 * rect.height)
    let screen = zoomPoint(target, size: size, zoom: zoom, offset: offset)
    let n = normalizedPoint(unzoomPoint(screen, size: size, zoom: zoom, offset: offset), in: rect)!
    #expect(abs(n.x - 0.25) < 1e-9 && abs(n.y - 0.75) < 1e-9)
}

@Test func draggedPinFollowsFullTranslation() {
    // Translation from the stable pin space is applied 1:1 (the old local-space drag moved ~50%).
    #expect(draggedPinPoint(base: CGPoint(x: 100, y: 100), translation: CGSize(width: 80, height: -30)) == CGPoint(x: 180, y: 70))
}

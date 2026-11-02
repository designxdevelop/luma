import SwiftUI
import LumaCore

/// Sensor and appliance values from the last cloud state read (`DeviceReadings.parse`).
/// Readings are never persisted; offline devices show none because their values are historical.
struct DeviceReadingsCard: View {
    let readings: [DeviceReadings.Reading]
    var readAt: Date?

    var body: some View {
        if !readings.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Readings", detail: readAt.map { "Read \($0.formatted(.relative(presentation: .named)))" })
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(readings) { reading in
                            GridRow {
                                Text(reading.label).foregroundStyle(.secondary)
                                Text(reading.text).monospacedDigit().textSelection(.enabled)
                            }.font(.system(size: 13))
                        }
                    }
                    Text("From Govee's cloud. Units are the ones the device reports.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

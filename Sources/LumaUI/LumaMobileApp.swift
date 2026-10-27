#if os(iOS)
import SwiftUI

/// iPhone and iPad entry. Shares every page with the Mac app; there is no menu
/// bar, so schedules and webhooks run only while Luma is open in the foreground.
public struct LumaMobileApp: App {
    @State private var store = HomeStore()
    @State private var navigation = LumaNavigation()
    public init() {}
    public var body: some Scene {
        WindowGroup {
            RootView(store: store, navigation: navigation).tint(.lumaAccentFill)
        }
    }
}
#endif

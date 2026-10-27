#if os(iOS)
import SwiftUI

/// iPhone and iPad entry. Shares every page with the Mac app; there is no menu
/// bar, so schedules and webhooks run only while Luma is open in the foreground.
public struct LumaMobileApp: App {
    @State private var store: HomeStore
    @State private var navigation = LumaNavigation()
    private let watch = WatchRelay()
    public init() {
        let store = HomeStore()
        _store = State(initialValue: store)
        // Started here, not on appear: a watch message can launch Luma in the
        // background, where no window appears.
        watch.start(store)
    }
    public var body: some Scene {
        WindowGroup {
            RootView(store: store, navigation: navigation).tint(.lumaAccentFill)
                .onChange(of: store.watchSnapshot) { _, snapshot in watch.publish(snapshot) }
        }
    }
}
#endif

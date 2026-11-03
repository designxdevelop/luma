#if os(iOS)
import SwiftUI

/// iPhone and iPad entry. Shares every page with the Mac app; there is no menu
/// bar, so schedules and webhooks run only while Luma is open in the foreground.
public struct LumaMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: HomeStore
    @State private var navigation = LumaNavigation()
    private let watch = WatchRelay()
    public init() {
        // Shared with Siri / Shortcuts actions, which run in this process.
        let store = HomeStore.shared
        _store = State(initialValue: store)
        // Started here, not on appear: a watch message can launch Luma in the
        // background, where no window appears.
        watch.start(store)
    }
    public var body: some Scene {
        WindowGroup {
            RootView(store: store, navigation: navigation).tint(.lumaAccentFill)
                .onChange(of: scenePhase) { _, phase in if phase == .active { store.refreshICloud() } }
                .onChange(of: store.watchSnapshot) { _, snapshot in watch.publish(snapshot) }
                .onChange(of: store.shortcutVocabulary, initial: true) { LumaSiri.vocabularyChanged() }
        }
    }
}
#endif

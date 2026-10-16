import AppKit
import SwiftUI

extension View {
    /// Allow a control click to activate the window and perform its action.
    @ViewBuilder
    func acceptsActivationClicks() -> some View {
        if #available(macOS 15, *) {
            allowsWindowActivationEvents(true)
        } else {
            ActivationClickHost(content: self)
        }
    }
}

/// SwiftUI gained its activation-event modifier in macOS 15. Keep a public
/// AppKit hosting boundary for earlier systems, without intercepting events.
private struct ActivationClickHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> FirstMouseHostingView {
        FirstMouseHostingView(rootView: hostedContent(context))
    }

    func updateNSView(_ nsView: FirstMouseHostingView, context: Context) {
        nsView.rootView = hostedContent(context)
    }

    private func hostedContent(_ context: Context) -> AnyView {
        AnyView(content.environment(\.self, context.environment))
    }
}

private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

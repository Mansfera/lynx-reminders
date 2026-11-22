import LynxCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few platform differences the shared views need.
enum Platform {
    #if os(macOS)
    static let triggerPlatform: TriggerPlatform = .mac
    static let isMac = true
    #else
    static let triggerPlatform: TriggerPlatform = .ios
    static let isMac = false
    #endif

    @MainActor static func bringToFront() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Lynx Reminders" }) {
            w.makeKeyAndOrderFront(nil)
        }
        #endif
    }

    @MainActor static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

#if os(iOS)
/// Pull down to sync (signed in only). `.refreshable` reaches the ScrollView through the environment.
private struct SyncOnPull: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        if model.user != nil {
            content.refreshable { await model.runSync(manifest: true) }
        } else {
            content
        }
    }
}

extension View {
    func syncOnPull() -> some View { modifier(SyncOnPull()) }
}
#endif

extension View {
    /// Form rows read the same on both platforms; iOS gets slightly larger tap targets.
    @ViewBuilder func platformRowPadding() -> some View {
        #if os(iOS)
        padding(.vertical, Brand.Space.xs)
        #else
        self
        #endif
    }
}

import SwiftUI

@main
struct MacUtilityKitApp: App {
    var body: some Scene {
        WindowGroup("Mac Utility Kit") { Workspace() }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .defaultSize(width: 940, height: 690)
    }
}

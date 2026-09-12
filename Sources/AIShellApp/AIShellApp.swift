import AIShellCore
import SwiftUI

@main
struct AIShellApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 820, height: 620)
        .windowResizability(.contentMinSize)
    }
}

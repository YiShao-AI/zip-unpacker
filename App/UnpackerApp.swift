import SwiftUI

@main
struct UnpackerApp: App {
    @StateObject private var library = Library.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .onOpenURL { url in
                    library.importFile(url)
                    library.say(url.hasDirectoryPath ? "Added folder “\(url.lastPathComponent)” to the Inbox."
                                                     : "Added “\(url.lastPathComponent)” to the Inbox.")
                }
                .task { DemoMode.seed(library) }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !DemoMode.isOn && !library.isRunning { library.prepare() }
        }
    }
}

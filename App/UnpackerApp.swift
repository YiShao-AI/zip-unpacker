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
                    let added = library.importFile(url)
                    if url.hasDirectoryPath || added > 1 {
                        library.say(added == 0 ? "No files found in “\(url.lastPathComponent)”."
                                               : "Added \(plural(added, "file")) from folder “\(url.lastPathComponent)”.")
                    } else {
                        library.say("Added “\(url.lastPathComponent)” to the Inbox.")
                    }
                }
                .task { DemoMode.seed(library) }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !DemoMode.isOn && !library.isRunning { library.prepare() }
        }
    }
}

import SwiftUI
import UnpackCore

@main
struct UnpackerApp: App {
    @StateObject private var library = Library.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // CI: `simctl launch --console … -UnpackerSelfTest YES` prints what the linked app can open, then quits.
        if UserDefaults.standard.bool(forKey: "UnpackerSelfTest") {
            print("SELFTEST formats: " + SupportedFormats.names.joined(separator: ","))
            print("SELFTEST missing: " + SupportedFormats.engineMissing.joined(separator: ","))
            print("SELFTEST missing-count: \(SupportedFormats.engineMissing.count)")
            exit(SupportedFormats.engineMissing.isEmpty ? 0 : 1)
        }
    }

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

import SwiftUI

@main
struct UnpackerApp: App {
    @StateObject private var library = Library.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .onOpenURL { library.importFile($0) }
                .task { DemoMode.seed(library) }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !DemoMode.isOn { library.prepare() }
        }
    }
}

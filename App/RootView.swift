import SwiftUI
import UIKit

/// Which tab is showing, and the Results navigation stack (so other screens can open a batch).
@MainActor
final class AppNav: ObservableObject {
    enum Tab: Hashable { case inbox, results, settings }
    @Published var tab: Tab = .inbox
    @Published var resultsPath: [Batch] = []

    func open(_ batch: Batch) {
        resultsPath = [batch]
        tab = .results
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @StateObject private var nav = AppNav()

    var body: some View {
        TabView(selection: $nav.tab) {
            InboxScreen()
                .tabItem { Label(library.isRunning ? "Unpacking…" : "Inbox", systemImage: "tray.and.arrow.down") }
                .badge(library.isRunning ? 0 : library.pending.count)
                .tag(AppNav.Tab.inbox)
            ResultsScreen()
                .tabItem { Label("Results", systemImage: "folder") }
                .tag(AppNav.Tab.results)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppNav.Tab.settings)
        }
        .environmentObject(nav)
        .overlay(alignment: .top) {
            if let text = library.toast {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
                    .padding(.horizontal, 16).padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { library.toast = nil }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: library.toast)
        .overlay {
            if let busy = library.busy {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(busy).font(.headline)
                        Text("Big videos can take a moment.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
                }
            }
        }
        .alert(library.notice ?? "", isPresented: Binding(get: { library.notice != nil },
                                                         set: { if !$0 { library.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task { await DemoMode.route(nav: nav, library: library) }
    }
}

// MARK: Shared pieces

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// "Copied to “Unzip” · 3 Nov, 14:35" etc. for a batch.
func exportStatus(_ batch: Batch, copying: Bool, destination: String?) -> (text: String, color: Color) {
    if copying { return ("Copying to “\(destination ?? "")”…", .accentColor) }
    if let to = batch.info.exportedTo {
        let when = batch.info.exportedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return ("Copied to “\(to)”" + when, Color(red: 0.12, green: 0.48, blue: 0.23))
    }
    return ("Not exported yet", .secondary)
}

func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "" }
    let t = Int(seconds.rounded())
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

let successGreen = Color(red: 0.12, green: 0.48, blue: 0.23)

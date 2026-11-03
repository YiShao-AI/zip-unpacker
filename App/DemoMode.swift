import Foundation
import UnpackCore

/// Launch arguments used by CI to screenshot each screen in the Simulator:
///   -UnpackerDemo YES          fill the app with sample files (fake data, no real archives)
///   -UnpackerScreen <name>     inbox | select | sheet | progress | results | batch | player | settings
/// Launch arguments land in UserDefaults' argument domain, so nothing here persists.
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "UnpackerDemo") }
    static var screen: String { UserDefaults.standard.string(forKey: "UnpackerScreen") ?? "inbox" }

    static let inboxNames = ["7月17日舞蹈.pdf", "7月18日舞蹈.pdf", "7月19日舞蹈.pdf", "7月20日舞蹈.pdf", "7月21日教学.pdf"]

    @MainActor
    static func seed(_ library: Library) {
        guard isOn else { return }
        let fm = FileManager.default
        let docs = library.docs
        for item in (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
        library.prepare()

        func blob(_ kb: Int) -> Data { Data(repeating: 0x5A, count: kb * 1024) }
        for (i, name) in inboxNames.enumerated() {
            try? blob(300 + i * 40).write(to: library.pendingDir.appendingPathComponent(name))
        }
        let batches: [(String, [String], String?)] = [
            ("Batch 2026-11-03 14-30", ["7月13日舞蹈", "7月14日舞蹈"], "Unzip"),
            ("Batch 2026-11-02 21-05", ["7月15日舞蹈", "7月16日舞蹈"], nil),
        ]
        for (batch, originals, exported) in batches {
            let folder = docs.appendingPathComponent(batch)
            for o in originals {
                let dir = folder.appendingPathComponent(o)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for (f, kb) in [("\(o).mp4", 900), ("video_output_00001-audio_22.mp4", 450), ("video_output_00001-audio_23.mp4", 420)] {
                    try? blob(kb).write(to: dir.appendingPathComponent(f))
                }
            }
            BatchInfo(format: UnpackFormat.standard.summary, exportedTo: exported,
                      exportedAt: exported == nil ? nil : Date(timeIntervalSinceNow: -3600)).save(folder)
        }
        library.defaultFormat = .standard
        library.quickPicks = QuickPick.builtIn
        library.useGlobalFormat = screen != "sheet"
        library.autoCopy = true
        ExportDestination.setDemoName("Unzip")
        library.refresh()
        if screen == "progress" { library.showDemoRun() }
    }

    @MainActor
    static func route(nav: AppNav, library: Library) async {
        guard isOn else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
        switch screen {
        case "results": nav.tab = .results
        case "batch", "player": if let first = library.batches.first { nav.open(first) }
        case "settings": nav.tab = .settings
        default: break
        }
    }
}

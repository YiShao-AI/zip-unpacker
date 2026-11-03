import AppIntents
import Foundation

/// Shortcuts: "Unpack Inbox" — unpacks everything waiting and returns the unpacked files,
/// so a shortcut can continue with e.g. "Save to Photo Album" or "Save File".
struct UnpackInboxIntent: AppIntent {
    static var title: LocalizedStringResource = "Unpack Inbox"
    static var description = IntentDescription("Unpacks every file waiting in Unpacker and returns the unpacked files.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let summary = await Library.shared.unpackAll()
        let files = summary.outputFiles.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) }
        return .result(value: files, dialog: IntentDialog(stringLiteral: summary.text))
    }
}

/// Shortcuts: "Add Files to Unpacker" — for a share-sheet shortcut that takes files from Baidu
/// (or anywhere) and optionally unpacks them straight away.
struct AddFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Files to Unpacker"
    static var description = IntentDescription("Puts files in Unpacker's inbox and, if chosen, unpacks them.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Unpack Now", default: true)
    var unpackNow: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$files) to Unpacker") { \.$unpackNow }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let library = Library.shared
        for file in files {
            if let url = file.fileURL {
                library.importFile(url)
            } else {
                try library.importData(file.data, named: file.filename)
            }
        }
        guard unpackNow else {
            return .result(value: [], dialog: IntentDialog(stringLiteral: "Added \(files.count) file(s) to Unpacker."))
        }
        let summary = await library.unpackAll()
        let out = summary.outputFiles.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) }
        return .result(value: out, dialog: IntentDialog(stringLiteral: summary.text))
    }
}

struct UnpackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: UnpackInboxIntent(), phrases: ["Unpack inbox in \(.applicationName)",
                                                           "Unpack files with \(.applicationName)"])
    }
}

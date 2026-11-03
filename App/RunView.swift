import SwiftUI

/// The batch that is running (or just finished), with a status line per file.
struct RunView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var nav: AppNav

    var body: some View {
        if let run = library.run {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(run.batchName, systemImage: "folder").font(.headline)
                        ProgressView(value: run.overall)
                        Text(phaseText(run)).font(.subheadline)
                        Text("Format: \(run.format.summary)").font(.footnote).foregroundStyle(.secondary)
                        Text("Saving to On My iPhone › Unpacker › \(run.batchName)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } footer: {
                    if run.phase != .done { Text("Keep Unpacker open until this finishes.") }
                }

                Section("Files in this batch") {
                    ForEach(run.items) { item in RunRow(item: item, format: run.format, finished: run.phase == .done) }
                }

                if let export = exportRow(run) {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus").font(.title3).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Copy to “\(library.exportName ?? "export folder")”")
                                Text(export.text).font(.caption).foregroundStyle(export.color)
                            }
                        }
                    }
                }

                Section {
                    if run.phase == .done {
                        if let batch = run.result {
                            Button("Open batch folder") {
                                library.dismissRun()
                                nav.open(batch)
                            }
                        }
                        Button("Back to Inbox") { library.dismissRun() }
                    } else {
                        Button(run.stopRequested ? "Stopping after this file…" : "Stop after this file", role: .destructive) {
                            library.stopAfterCurrent()
                        }
                        .disabled(run.stopRequested || run.phase != .running)
                    }
                }
            }
            .navigationTitle(run.phase == .done ? "Batch finished" : "Unpacking")
        }
    }

    private func phaseText(_ run: BatchRun) -> String {
        switch run.phase {
        case .running:
            let current = min(run.finished + 1, run.items.count)
            return "File \(current) of \(run.items.count) · \(run.succeeded) done" + (run.failed > 0 ? " · \(run.failed) failed" : "")
        case .exporting:
            return "All files processed · copying the batch folder"
        case .done:
            var s = "\(run.succeeded) unpacked"
            if run.failed > 0 { s += " · \(run.failed) failed, back in Inbox" }
            if run.notStarted > 0 { s += " · \(run.notStarted) not started, back in Inbox" }
            return s
        }
    }

    private func exportRow(_ run: BatchRun) -> (text: String, color: Color)? {
        switch run.export {
        case .off: return nil
        case .waiting: return ("Waits until every file is done", .secondary)
        case .copying: return ("Copying…", .accentColor)
        case .copied(let target): return ("Copied to \(target)", successGreen)
        case .failed(let why): return ("Copy failed: \(why) The batch is still in Unpacker.", .red)
        case .notCopied: return ("Not copied", .secondary)
        }
    }
}

struct RunRow: View {
    let item: RunItem
    let format: UnpackFormat
    let finished: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(statusText).font(.caption).foregroundStyle(statusColor)
                if case .unpacking(_, let f) = item.status {
                    ProgressView(value: f)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .done: Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(successGreen)
        case .failed: Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.red)
        case .unpacking: ProgressView()
        case .waiting, .notStarted: Image(systemName: "circle.dashed").font(.title2).foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch item.status {
        case .waiting: return finished ? "Not started · back in Inbox" : "Waiting"
        case .notStarted: return "Not started · back in Inbox"
        case .unpacking(let layer, let f):
            let of = format.layers.map { " of \($0)" } ?? ""
            return "Layer \(layer)\(of) · \(Int((f * 100).rounded()))%"
        case .done(let text): return text
        case .failed(let text): return text
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .unpacking: return .accentColor
        case .done: return successGreen
        case .failed: return .red
        default: return .secondary
        }
    }
}

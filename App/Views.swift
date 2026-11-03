import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UnpackCore

private func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct ContentView: View {
    @EnvironmentObject var library: Library
    @AppStorage(Settings.passwordsKey) private var passwords = ""
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var shareItems: ShareItems?
    @State private var path: [FileItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if passwords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Button { showSettings = true } label: {
                            Label("Add the archive password in Settings", systemImage: "key.fill")
                        }
                    }
                }

                Section {
                    if library.isRunning {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: library.progressFraction)
                            Text(library.progressText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            Task { await library.unpackAll() }
                        } label: {
                            Label("Unpack all (\(library.pending.filter { !$0.isDirectory }.count))",
                                  systemImage: "archivebox")
                                .font(.headline)
                        }
                        .disabled(library.pending.isEmpty)
                    }
                    if let s = library.lastSummary, !library.isRunning {
                        Text(s).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    if let name = library.exportName {
                        Text("Each finished batch is also copied to “\(name)”.")
                    }
                }

                Section {
                    if library.pending.isEmpty {
                        Text("Share or “Open in…” files from Baidu Netdisk to Unpacker, or tap + to pick files.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(library.pending) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(2)
                            Text(sizeText(item.size)).font(.caption).foregroundStyle(.secondary)
                            if let err = library.errors[item.name] {
                                Text(err).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { library.pending[$0] }.forEach(library.delete) }
                } header: {
                    Text("To unpack")
                }

                Section {
                    ForEach(library.batches) { item in
                        NavigationLink(value: item) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).lineLimit(2)
                                    Text("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s") · \(sizeText(item.size))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if library.exportName != nil {
                                Button {
                                    Task { library.notice = await library.export(item.url) }
                                } label: { Label("Export", systemImage: "folder.badge.plus") }
                                    .tint(.green)
                            }
                            Button {
                                shareItems = ShareItems(urls: [item.url])
                            } label: { Label("Share folder", systemImage: "square.and.arrow.up") }
                                .tint(.blue)
                        }
                    }
                    .onDelete { idx in idx.map { library.batches[$0] }.forEach(library.delete) }
                } header: {
                    Text("Batches")
                } footer: {
                    Text("In the Files app: On My iPhone › Unpacker. Each batch is one folder there; import it into Unzip, or move, copy or AirDrop it.")
                }
            }
            .navigationTitle("Unpacker")
            .navigationDestination(for: FileItem.self) { FolderView(item: $0) }
            .refreshable { library.prepare() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(library.importFile) }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(library) }
            .sheet(item: $shareItems) { ActivityView(items: $0.urls) }
            .task {
                guard DemoMode.isOn else { return }
                try? await Task.sleep(nanoseconds: 600_000_000)
                switch DemoMode.screen {
                case "settings": showSettings = true
                case "batch", "results": if let first = library.batches.first { path = [first] }
                default: break
                }
            }
            .alert(library.notice ?? "", isPresented: Binding(get: { library.notice != nil },
                                                             set: { if !$0 { library.notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

struct FolderView: View {
    let item: FileItem
    @EnvironmentObject var library: Library
    @State private var share: ShareItems?

    var files: [URL] { item.isDirectory ? Unpacker.files(in: item.url) : [item.url] }

    var body: some View {
        List(files, id: \.self) { url in
            let rel = url.path.replacingOccurrences(of: item.url.path + "/", with: "")
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            Button { share = ShareItems(urls: [url]) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rel).foregroundStyle(.primary)
                    Text(sizeText(size)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                if let name = library.exportName {
                    Button {
                        Task { library.notice = await library.export(item.url) }
                    } label: { Label("Copy to “\(name)”", systemImage: "folder.badge.plus") }
                }
                Button { share = ShareItems(urls: [item.url]) } label: {
                    Label("Share folder", systemImage: "folder")
                }
                Button { share = ShareItems(urls: files) } label: {
                    Label("Share all files", systemImage: "square.and.arrow.up.on.square")
                }
            } label: { Image(systemName: "square.and.arrow.up") }
        }
        .sheet(item: $share) { ActivityView(items: $0.urls) }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var library: Library
    @AppStorage(Settings.passwordsKey) private var passwords = ""
    @AppStorage(Settings.deleteOriginalsKey) private var deleteOriginals = false
    @State private var pickFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $passwords)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 80)
                } header: {
                    Text("Passwords")
                } footer: {
                    Text("One per line. Each layer is tried with these in order. Stored only on this iPhone.")
                }

                Section {
                    if let name = library.exportName {
                        LabeledContent("Folder", value: name)
                        Button("Choose a different folder") { pickFolder = true }
                        Button("Stop exporting", role: .destructive) { library.clearExportDestination() }
                    } else {
                        Button("Choose folder…") { pickFolder = true }
                    }
                } header: {
                    Text("Export destination (optional)")
                } footer: {
                    Text("Each finished batch folder is copied here automatically, e.g. the Unzip app's folder in Files. Batches always stay in Unpacker too.")
                }

                Section {
                    Toggle("Delete originals after unpacking", isOn: $deleteOriginals)
                } footer: {
                    Text(deleteOriginals
                         ? "Originals are deleted once they unpack successfully. Middle layers are always deleted."
                         : "Originals move to the Originals folder once they unpack successfully. Middle layers are always deleted.")
                }

                Section {
                    Button("Empty Originals folder (\(library.originalsCount))", role: .destructive) { library.clearOriginals() }
                        .disabled(library.originalsCount == 0)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.setExportDestination(url) }
            }
        }
    }
}

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

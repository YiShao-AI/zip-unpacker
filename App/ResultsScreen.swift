import AVFoundation
import QuickLook
import SwiftUI
import UIKit
import UnpackCore

func subfolders(of dir: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// Shown at the bottom while something is on the clipboard.
struct ClipboardBar: View {
    let clip: Library.Clipboard
    /// nil = nowhere to paste on this screen.
    let paste: (() -> Void)?
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: clip.cut ? "scissors" : "doc.on.doc").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Clipboard: \(clip.text)").font(.subheadline.weight(.semibold))
                Text(paste == nil ? "Open a batch to paste" : "Pastes into this batch, keeping each original's folder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let paste {
                Button("Paste here", action: paste).buttonStyle(.borderedProminent)
            }
            Button(action: clear) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                .accessibilityLabel("Clear clipboard")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}

struct ResultsScreen: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var nav: AppNav
    @State private var selecting = false
    @State private var selected: Set<URL> = []
    @State private var naming = false
    @State private var newName = ""
    @State private var merging = false
    @State private var confirmDelete = false

    private var chosen: [Batch] { library.batches.filter { selected.contains($0.url) } }

    var body: some View {
        NavigationStack(path: $nav.resultsPath) {
            List {
                Section {
                    if library.batches.isEmpty {
                        Text("No batches yet. Unpack something from the Inbox.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 18)
                    }
                    ForEach(library.batches) { batch in
                        if selecting {
                            Button {
                                if selected.contains(batch.url) { selected.remove(batch.url) } else { selected.insert(batch.url) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(batch.url) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundStyle(selected.contains(batch.url) ? Color.accentColor : Color(.tertiaryLabel))
                                    BatchRow(batch: batch)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected.contains(batch.url) ? .isSelected : [])
                        } else {
                            NavigationLink(value: batch) { BatchRow(batch: batch) }
                        }
                    }
                } footer: {
                    Text(selecting ? "Tick batches to merge them into one, or to delete them."
                                   : "Each batch is one folder in the Files app under On My iPhone › Unpacker. Unzip can import it from there too.")
                }
            }
            .navigationTitle("Results")
            .navigationDestination(for: Batch.self) { BatchView(batchURL: $0.url) }
            .refreshable { library.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !library.batches.isEmpty {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            selected = []
                        }
                        .fontWeight(selecting ? .semibold : .regular)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { newName = ""; naming = true } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("New batch")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Button { merging = true } label: { Label("Merge (\(chosen.count))", systemImage: "arrow.triangle.merge") }
                            .disabled(chosen.count < 2)
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete (\(chosen.count))", systemImage: "trash") }
                            .disabled(chosen.isEmpty)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.bar)
                } else if let clip = library.clipboard {
                    ClipboardBar(clip: clip, paste: nil) { library.clipboard = nil }
                }
            }
            .alert("New batch", isPresented: $naming) {
                TextField("Name, e.g. July dances", text: $newName)
                Button("Create") {
                    if let url = library.createBatch(named: newName), let b = library.batches.first(where: { $0.url == url }) {
                        nav.resultsPath = [b]
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It shows up here as “Batch …”. Then use Copy, Cut or Move to put videos in it.")
            }
            .sheet(isPresented: $merging) {
                MergeSheet(batches: chosen) { merged in
                    selecting = false
                    selected = []
                    if let b = library.batches.first(where: { $0.url == merged }) { nav.resultsPath = [b] }
                }
                .environmentObject(library)
            }
            .confirmationDialog("Delete \(plural(chosen.count, "batch"))?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    library.deleteBatches(chosen.map(\.url))
                    selected = []
                    selecting = false
                }
            } message: {
                Text("Their files are removed from Unpacker. Copies already exported elsewhere are kept.")
            }
            .onChange(of: library.batches.map(\.url)) { urls in selected.formIntersection(urls) }
        }
    }
}

struct MergeSheet: View {
    let batches: [Batch]
    let done: (URL) -> Void
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keepOld = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Batch name", text: $name)
                }
                Section {
                    ForEach(batches) { b in
                        Text(b.name).font(.subheadline)
                    }
                } header: {
                    Text("Merging")
                } footer: {
                    Text("Folders with the same name become one folder. If two files have the same name, the second gets “ 2”, so nothing is overwritten.")
                }
                Section {
                    Toggle("Keep the old batches too", isOn: $keepOld)
                } footer: {
                    Text(keepOld ? "Copies everything; the old batches stay as they are (uses more space)."
                                 : "Moves everything into the new batch and removes the old, now empty, batches.")
                }
                Section {
                    Button {
                        let list = batches.map(\.url), n = name, keep = keepOld
                        dismiss()
                        Task { if let url = await library.merge(list, named: n, keepOld: keep) { done(url) } }
                    } label: {
                        Text("Merge \(plural(batches.count, "batch"))").font(.headline)
                            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .listRowBackground(Color.accentColor)
                    .disabled(FolderOps.cleanName(name) == nil)
                }
            }
            .navigationTitle("Merge batches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if name.isEmpty { name = library.nextBatchName() + " merged" } }
        }
    }
}

struct BatchRow: View {
    let batch: Batch
    @EnvironmentObject var library: Library

    var body: some View {
        let status = exportStatus(batch, copying: library.copying.contains(batch.url), destination: library.exportName)
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text("\(plural(batch.originals, "folder")) · \(plural(batch.fileCount, "file")) · \(sizeText(batch.size))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(status.text).font(.caption).foregroundStyle(status.color)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One original's folder inside a batch.
struct FolderSection: Identifiable {
    let id: URL
    let title: String
    let files: [URL]
}

struct PlayerRequest: Identifiable {
    let id = UUID()
    let items: [URL]
    let index: Int
}

struct TransferRequest: Identifiable {
    let id = UUID()
    let items: [URL]
    let move: Bool
}

struct BatchView: View {
    let batchURL: URL
    @EnvironmentObject var library: Library
    @EnvironmentObject var nav: AppNav
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [FolderSection] = []
    @State private var player: PlayerRequest?
    @State private var preview: URL?
    @State private var share: ShareItems?
    @State private var confirmDeleteBatch = false
    @State private var pickFolder = false
    @State private var confirmRename = false
    @State private var reload = 0
    @State private var selecting = false
    @State private var selected: Set<URL> = []
    @State private var deleting: [URL]?
    @State private var transfer: TransferRequest?
    @State private var newFolder = false
    @State private var renaming: URL?
    @State private var nameText = ""

    private var batch: Batch? { library.batches.first { $0.url == batchURL } }
    private var videos: [URL] { sections.flatMap(\.files).filter(Media.isVideo) }
    private var copying: Bool { library.copying.contains(batchURL) }

    /// The selection, without files whose whole folder is also selected.
    private var chosen: [URL] {
        let folders = sections.map(\.id).filter { selected.contains($0) && $0 != batchURL }
        let files = sections.flatMap(\.files).filter { f in
            selected.contains(f) && !folders.contains { f.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
        }
        return folders + files
    }

    var body: some View {
        List {
            if let batch, !selecting {
                let status = exportStatus(batch, copying: copying, destination: library.exportName)
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(plural(batch.originals, "folder")) · \(plural(batch.fileCount, "file")) · \(sizeText(batch.size))")
                        if let f = batch.info.format {
                            Text("Unpacked with: \(f)").font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("On My iPhone › Unpacker › \(batch.name)").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Button {
                        if library.exportName == nil { pickFolder = true } else { Task { await library.export(batchURL) } }
                    } label: {
                        Label(exportLabel(batch), systemImage: "folder.badge.plus").font(.headline)
                    }
                    .disabled(copying)

                    Text(status.text).font(.footnote).foregroundStyle(status.color)

                    Button { share = ShareItems(urls: [batchURL]) } label: {
                        Label("Share folder (extra)", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Tap Select (top right) to copy, cut, move or delete several videos or folders at once.")
                }
            }

            if sections.isEmpty {
                Text("This batch is empty. Paste or move videos into it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 18)
            }

            ForEach(sections) { section in
                Section {
                    if section.files.isEmpty {
                        Text("Empty folder").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(section.files, id: \.self) { url in
                        FileRow(url: url, base: section.id, selected: selecting ? isSelected(url) : nil) {
                            if selecting { toggle(url) } else { open(url) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !selecting {
                                Button(role: .destructive) { deleting = [url] } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .contextMenu { if !selecting { itemMenu([url]) } }
                    }
                } header: {
                    header(section)
                }
            }

            if !selecting {
                Section {
                    Button("Delete batch", role: .destructive) { confirmDeleteBatch = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(batchURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selecting {
                    Button("Done") { selecting = false; selected = [] }.fontWeight(.semibold)
                } else {
                    Menu {
                        Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                        Button { nameText = ""; newFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                        Button { nameText = batchURL.lastPathComponent; renaming = batchURL } label: {
                            Label("Rename batch", systemImage: "pencil")
                        }
                        if !videos.isEmpty {
                            Button { confirmRename = true } label: {
                                Label("Rename videos after their folders", systemImage: "character.cursor.ibeam")
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Batch options")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 4) {
                    barButton("Copy", "doc.on.doc") { library.copyToClipboard(chosen, from: batchURL, cut: false); endSelecting() }
                    barButton("Cut", "scissors") { library.copyToClipboard(chosen, from: batchURL, cut: true); endSelecting() }
                    barButton("Move to", "folder") { transfer = TransferRequest(items: chosen, move: true) }
                    barButton("Copy to", "plus.rectangle.on.folder") { transfer = TransferRequest(items: chosen, move: false) }
                    barButton("Delete", "trash", role: .destructive) { deleting = chosen }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.bar)
            } else if let clip = library.clipboard {
                ClipboardBar(clip: clip, paste: { paste(.batch(batchURL)) }) { library.clipboard = nil }
            }
        }
        .task(id: "\(batch?.fileCount ?? 0)-\(batch?.originals ?? 0)-\(reload)") {
            let url = batchURL
            sections = await Task.detached { Self.load(url) }.value
            selected = selected.filter { s in sections.contains { $0.id == s || $0.files.contains(s) } }
            if DemoMode.isOn, DemoMode.screen == "player", player == nil, !videos.isEmpty {
                player = PlayerRequest(items: videos, index: 1 < videos.count ? 1 : 0)
            }
        }
        .fullScreenCover(item: $player) { req in PlayerView(items: req.items, start: req.index) }
        .quickLookPreview($preview)
        .sheet(item: $share) { ActivityView(items: $0.urls) }
        .sheet(item: $transfer) { req in
            DestinationSheet(request: req, source: batchURL) {
                endSelecting()
                reload += 1
            }
            .environmentObject(library)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let items = deleting { library.delete(items, inBatch: batchURL) }
                deleting = nil
                endSelecting()
                reload += 1
            }
        } message: {
            Text("Removed from Unpacker. Copies already exported elsewhere are kept.")
        }
        .confirmationDialog("Delete “\(batchURL.lastPathComponent)”?", isPresented: $confirmDeleteBatch, titleVisibility: .visible) {
            Button("Delete batch", role: .destructive) {
                library.delete(batchURL)
                dismiss()
            }
        } message: {
            Text("Its files are removed from Unpacker. Copies already exported elsewhere are kept.")
        }
        .confirmationDialog("Rename the videos in “\(batchURL.lastPathComponent)”?", isPresented: $confirmRename,
                            titleVisibility: .visible) {
            Button("Rename videos") {
                library.renameVideos(inBatch: batchURL)
                reload += 1
            }
        } message: {
            Text("Each video is named after its folder, e.g. 7月13日舞蹈 (1).mp4, (2)… Copies already exported elsewhere keep their old names.")
        }
        .alert("New folder", isPresented: $newFolder) {
            TextField("Name", text: $nameText)
            Button("Create") {
                library.createFolder(named: nameText, in: batchURL)
                reload += 1
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Rename") {
                guard let item = renaming else { return }
                renaming = nil
                let newURL = library.rename(item, to: nameText)
                if item == batchURL, let newURL, let b = library.batches.first(where: { $0.url == newURL }) {
                    nav.resultsPath = [b]
                } else {
                    reload += 1
                }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            library.setExportDestination(url)
            Task { await library.export(batchURL) }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func header(_ section: FolderSection) -> some View {
        let isFolder = section.id != batchURL
        HStack {
            if selecting && isFolder {
                Button { toggle(section.id) } label: {
                    Image(systemName: selected.contains(section.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                }
                .accessibilityLabel("Select folder \(section.title)")
            }
            Label(section.title, systemImage: "folder")
            Spacer()
            if isFolder && !selecting {
                Menu {
                    if library.clipboard != nil {
                        Button { paste(.folder(section.id)) } label: { Label("Paste into this folder", systemImage: "doc.on.clipboard") }
                    }
                    Button { nameText = section.title; renaming = section.id } label: { Label("Rename folder", systemImage: "pencil") }
                    itemMenu([section.id])
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body).frame(width: 44, height: 32)
                }
                .accessibilityLabel("Folder options for \(section.title)")
            }
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func itemMenu(_ items: [URL]) -> some View {
        Button { library.copyToClipboard(items, from: batchURL, cut: false) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { library.copyToClipboard(items, from: batchURL, cut: true) } label: { Label("Cut", systemImage: "scissors") }
        Button { transfer = TransferRequest(items: items, move: true) } label: { Label("Move to…", systemImage: "folder") }
        Button { transfer = TransferRequest(items: items, move: false) } label: { Label("Copy to…", systemImage: "plus.rectangle.on.folder") }
        Button { share = ShareItems(urls: items) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button(role: .destructive) { deleting = items } label: { Label("Delete", systemImage: "trash") }
    }

    private func barButton(_ title: String, _ icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(chosen.isEmpty)
    }

    private func isSelected(_ url: URL) -> Bool {
        selected.contains(url) || selected.contains(url.deletingLastPathComponent())
    }

    private func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    private func endSelecting() {
        selecting = false
        selected = []
    }

    private func paste(_ destination: Library.Destination) {
        Task {
            await library.paste(to: destination)
            reload += 1
        }
    }

    private var deleteTitle: String {
        guard let items = deleting else { return "" }
        if items.count == 1 { return "Delete “\(items[0].lastPathComponent)”?" }
        return "Delete \(plural(items.count, "item"))?"
    }

    private func exportLabel(_ batch: Batch) -> String {
        guard let dest = library.exportName else { return "Choose an export folder…" }
        return batch.info.exportedTo == nil ? "Copy to “\(dest)”" : "Copy to “\(dest)” again"
    }

    private func open(_ url: URL) {
        if Media.isVideo(url), let i = videos.firstIndex(of: url) {
            player = PlayerRequest(items: videos, index: i)
        } else {
            preview = url
        }
    }

    nonisolated static func load(_ batch: URL) -> [FolderSection] {
        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(at: batch, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var sections: [FolderSection] = []
        var loose: [URL] = []
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                sections.append(FolderSection(id: item, title: item.lastPathComponent, files: Unpacker.files(in: item)))
            } else {
                loose.append(item)
            }
        }
        if !loose.isEmpty { sections.append(FolderSection(id: batch, title: "Other files", files: loose)) }
        return sections
    }
}

/// Where Move to… / Copy to… puts things: any batch (keeping each original's folder), a folder in a batch, or a new batch.
struct DestinationSheet: View {
    let request: TransferRequest
    let source: URL
    let done: () -> Void
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""
    @State private var folderParent: URL?
    @State private var folderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { newName = ""; naming = true } label: { Label("New batch…", systemImage: "folder.badge.plus") }
                }
                ForEach(library.batches) { b in
                    Section {
                        Button { go(.batch(b.url)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(b.name + (b.url == source ? " (this batch)" : "")).foregroundStyle(.primary)
                                    Text("Keeps each original's folder").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(subfolders(of: b.url), id: \.self) { f in
                            Button { go(.folder(f)) } label: {
                                Label(f.lastPathComponent, systemImage: "folder").foregroundStyle(.primary)
                                    .padding(.leading, 28)
                            }
                        }
                        Button { folderName = ""; folderParent = b.url } label: {
                            Label("New folder here…", systemImage: "plus").font(.subheadline).padding(.leading, 28)
                        }
                    }
                }
            }
            .navigationTitle("\(request.move ? "Move" : "Copy") \(plural(request.items.count, "item")) to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New batch", isPresented: $naming) {
                TextField("Name, e.g. July dances", text: $newName)
                Button("Create") { if let url = library.createBatch(named: newName) { go(.batch(url)) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New folder", isPresented: Binding(get: { folderParent != nil }, set: { if !$0 { folderParent = nil } })) {
                TextField("Name", text: $folderName)
                Button("Create") {
                    if let parent = folderParent, let url = try? FolderOps.createFolder(named: folderName, in: parent) {
                        library.refresh()
                        go(.folder(url))
                    }
                    folderParent = nil
                }
                Button("Cancel", role: .cancel) { folderParent = nil }
            }
        }
    }

    private func go(_ destination: Library.Destination) {
        let req = request, src = source, finish = done
        dismiss()
        Task {
            await library.transfer(req.items, from: src, to: destination, move: req.move)
            finish()
        }
    }
}

struct FileRow: View {
    let url: URL
    let base: URL
    /// nil when not selecting.
    var selected: Bool? = nil
    let action: () -> Void
    @State private var thumb: UIImage?
    @State private var duration: Double?

    private var name: String {
        let prefix = base.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private var size: Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : Color(.tertiaryLabel))
                }
                if Media.isVideo(url) {
                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            if let thumb {
                                Image(uiImage: thumb).resizable().scaledToFill()
                            } else {
                                LinearGradient(colors: [Color(white: 0.35), Color(white: 0.15)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                        .frame(width: 80, height: 45)
                        .clipped()
                        .overlay {
                            Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                                .padding(6).background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        if let d = duration, !durationText(d).isEmpty {
                            Text(durationText(d)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white)
                                .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.65)))
                                .padding(3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "doc").font(.title3).foregroundStyle(.secondary).frame(width: 80, height: 45)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(2).truncationMode(.middle).foregroundStyle(.primary)
                    Text(sizeText(size) + (duration.map { durationText($0).isEmpty ? "" : " · " + durationText($0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected != nil ? name : Media.isVideo(url) ? "Play \(name)" : "Open \(name)")
        .accessibilityAddTraits(selected == true ? .isSelected : [])
        .task(id: url) {
            guard Media.isVideo(url) else { return }
            let info = await MediaInfo.shared.info(for: url)
            thumb = info.image
            duration = info.duration
        }
    }
}

/// Thumbnails and lengths for videos, generated on demand and kept for the session.
actor MediaInfo {
    static let shared = MediaInfo()

    struct Info {
        let image: UIImage?
        let duration: Double?
    }

    private var cache: [URL: Info] = [:]

    func info(for url: URL) async -> Info {
        if let hit = cache[url] { return hit }
        guard Media.isPlayable(url) else { return Info(image: nil, duration: nil) }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let at = CMTime(seconds: min(1, max((seconds ?? 0) / 2, 0)), preferredTimescale: 600)
        var image: UIImage?
        if let frame = try? await generator.image(at: at) { image = UIImage(cgImage: frame.image) }
        let info = Info(image: image, duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        cache[url] = info
        return info
    }
}

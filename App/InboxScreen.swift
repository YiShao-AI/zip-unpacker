import SwiftUI
import UniformTypeIdentifiers

struct InboxScreen: View {
    @EnvironmentObject var library: Library

    var body: some View {
        NavigationStack {
            if library.run != nil {
                RunView()
            } else {
                InboxList()
            }
        }
    }
}

struct FormatRequest: Identifiable {
    let id = UUID()
    let files: [FileItem]
}

struct InboxList: View {
    enum ImportKind { case files, folder }

    @EnvironmentObject var library: Library
    @State private var selecting = false
    @State private var selected: Set<URL> = []
    @State private var importKind = ImportKind.files
    @State private var showImporter = false
    @State private var formatRequest: FormatRequest?
    @State private var removing: FileItem?

    private var pending: [FileItem] { library.pending }
    private var chosen: [FileItem] { pending.filter { selected.contains($0.url) } }
    private var allSelected: Bool { !pending.isEmpty && chosen.count == pending.count }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    importTile("Import files", systemImage: "doc.badge.plus") { importKind = .files; showImporter = true }
                    importTile("Import folder", systemImage: "folder.badge.plus") { importKind = .folder; showImporter = true }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Or in Baidu Netdisk: Share › Open in… › Unpacker. Files are recognised as archives by their contents, whatever the extension.")
            }

            Section {
                if pending.isEmpty {
                    Text("Nothing waiting. Import files or a folder, or share them from Baidu Netdisk.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 18)
                }
                ForEach(pending) { item in row(item) }
                    .onDelete { idx in idx.map { pending[$0].url }.forEach(library.delete) }
            } header: {
                HStack {
                    Text(heading).textCase(.uppercase)
                    Spacer()
                    if !pending.isEmpty {
                        if selecting {
                            Button(allSelected ? "Deselect all" : "Select all") {
                                selected = allSelected ? [] : Set(pending.map(\.url))
                            }
                        }
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            selected = []
                        }
                        .fontWeight(selecting ? .semibold : .regular)
                    }
                }
                .font(.footnote)
                .textCase(nil)
            } footer: {
                if !pending.isEmpty {
                    Text(selecting ? "Tick the files to put in this batch."
                                   : "Tap a file to unpack just that one. Tap Select to choose several.")
                }
            }
        }
        .navigationTitle("Inbox")
        .refreshable { library.prepare() }
        .safeAreaInset(edge: .bottom) { unpackBar }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importKind == .folder ? [.folder] : [.item],
                      allowsMultipleSelection: importKind == .files) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            if importKind == .folder { urls.forEach(library.importFolder) } else { library.importFiles(urls) }
        }
        .sheet(item: $formatRequest) { req in
            FormatSheet(files: req.files, start: library.defaultFormat).environmentObject(library)
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from Unpacker?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let item = removing { library.delete(item.url) }
                removing = nil
            }
        }
        .onChange(of: pending.map(\.url)) { urls in
            selected.formIntersection(urls)
            if urls.isEmpty { selecting = false }
        }
        .task {
            guard DemoMode.isOn else { return }
            if DemoMode.screen == "select" {
                selecting = true
                selected = Set(pending.prefix(3).map(\.url))
            }
            if DemoMode.screen == "sheet" {
                try? await Task.sleep(nanoseconds: 400_000_000)
                formatRequest = FormatRequest(files: pending)
            }
        }
    }

    private var heading: String {
        let total = pending.reduce(Int64(0)) { $0 + $1.size }
        return "Waiting · \(plural(pending.count, "file"))" + (pending.isEmpty ? "" : " · \(sizeText(total))")
    }

    private func importTile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.borderless)
    }

    private func meta(_ item: FileItem) -> String {
        var s = sizeText(item.size)
        if let added = item.added {
            let f = RelativeDateTimeFormatter()
            f.dateTimeStyle = .named
            s += " · added " + f.localizedString(for: min(added, Date()), relativeTo: Date())
        }
        return s
    }

    private func row(_ item: FileItem) -> some View {
        let isSelected = selected.contains(item.url)
        return HStack(spacing: 12) {
            Button {
                if selecting {
                    if isSelected { selected.remove(item.url) } else { selected.insert(item.url) }
                } else {
                    start([item])
                }
            } label: {
                HStack(spacing: 12) {
                    if selecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                    } else {
                        Image(systemName: "doc.zipper").font(.title3).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                        Text(meta(item)).font(.caption).foregroundStyle(.secondary)
                        if let err = library.errors[item.name] {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selecting ? item.name : "Unpack \(item.name) now")
            .accessibilityAddTraits(selecting && isSelected ? .isSelected : [])

            Button { removing = item } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.name)")
        }
    }

    private var unpackLabel: String {
        guard selecting, !pending.isEmpty else { return "Unpack all (\(pending.count))" }
        if allSelected { return "Unpack all (\(pending.count))" }
        return chosen.isEmpty ? "Tick files to unpack" : "Unpack \(chosen.count) selected"
    }

    private var caption: String {
        let format = library.useGlobalFormat ? library.defaultFormat.summary : "You choose the format before it starts"
        let dest = library.autoCopy ? library.exportName.map { "then copy to “\($0)”" } : nil
        return format + " · " + (dest ?? "results stay in Unpacker")
    }

    private var unpackBar: some View {
        VStack(spacing: 6) {
            Button {
                start(selecting ? chosen : pending)
            } label: {
                Text(unpackLabel).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selecting ? chosen.isEmpty : pending.isEmpty)
            Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(.bar)
    }

    private func start(_ files: [FileItem]) {
        guard !files.isEmpty, !library.isRunning else { return }
        selecting = false
        selected = []
        if library.useGlobalFormat {
            Task { await library.unpack(files, format: library.defaultFormat) }
        } else {
            formatRequest = FormatRequest(files: files)
        }
    }
}

/// Shown before a batch when "Use the same format for every batch" is off.
struct FormatSheet: View {
    let files: [FileItem]
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var format: UnpackFormat
    @State private var makeDefault = false

    init(files: [FileItem], start: UnpackFormat) {
        self.files = files
        _format = State(initialValue: start)
    }

    private var chips: [FormatChip] {
        var c = [FormatChip(id: "default", name: "Default", format: library.defaultFormat)]
        if let last = library.lastFormat, last.key != library.defaultFormat.key {
            c.append(FormatChip(id: "last", name: "Last used", format: last))
        }
        return c + library.quickPicks.map { FormatChip(id: $0.id.uuidString, name: $0.name, format: $0.format, pick: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Into a new folder: \(library.nextBatchName())")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                FormatEditor(format: $format, chips: chips, heading: "Format for this batch")
                Section {
                    Toggle("Also make this the default", isOn: $makeDefault)
                }
                Section {
                    Button {
                        if makeDefault { library.defaultFormat = format }
                        let files = files, format = format
                        dismiss()
                        Task { await library.unpack(files, format: format) }
                    } label: {
                        VStack(spacing: 2) {
                            Text("Start unpacking").font(.headline)
                            Text(format.summary).font(.caption)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .listRowBackground(Color.accentColor)
                }
            }
            .navigationTitle("Unpack \(plural(files.count, "file"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

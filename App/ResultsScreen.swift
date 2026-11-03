import AVFoundation
import QuickLook
import SwiftUI
import UIKit
import UnpackCore

struct ResultsScreen: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var nav: AppNav

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
                        NavigationLink(value: batch) { BatchRow(batch: batch) }
                    }
                } footer: {
                    Text("Each batch is one folder in the Files app under On My iPhone › Unpacker. Unzip can import it from there too.")
                }
            }
            .navigationTitle("Results")
            .navigationDestination(for: Batch.self) { BatchView(batchURL: $0.url) }
            .refreshable { library.refresh() }
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
                Text(batch.name).font(.body.weight(.semibold))
                Text("\(plural(batch.originals, "original")) · \(plural(batch.fileCount, "file")) · \(sizeText(batch.size))")
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

struct BatchView: View {
    let batchURL: URL
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [FolderSection] = []
    @State private var player: PlayerRequest?
    @State private var preview: URL?
    @State private var share: ShareItems?
    @State private var confirmDelete = false
    @State private var pickFolder = false

    private var batch: Batch? { library.batches.first { $0.url == batchURL } }
    private var videos: [URL] { sections.flatMap(\.files).filter(Media.isVideo) }
    private var copying: Bool { library.copying.contains(batchURL) }

    var body: some View {
        List {
            if let batch {
                let status = exportStatus(batch, copying: copying, destination: library.exportName)
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(plural(batch.originals, "original")) · \(plural(batch.fileCount, "file")) · \(sizeText(batch.size))")
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
                    Text("Sharing a whole folder doesn't work with every app; Copy or the Files app always does.")
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.files, id: \.self) { url in
                        FileRow(url: url, base: section.id) { open(url) }
                    }
                } header: {
                    Label(section.title, systemImage: "folder").textCase(nil)
                }
            }

            Section {
                Button("Delete batch", role: .destructive) { confirmDelete = true }
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(batchURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: batch?.fileCount) {
            let url = batchURL
            sections = await Task.detached { Self.load(url) }.value
            if DemoMode.isOn, DemoMode.screen == "player", player == nil, !videos.isEmpty {
                player = PlayerRequest(items: videos, index: 1 < videos.count ? 1 : 0)
            }
        }
        .fullScreenCover(item: $player) { req in PlayerView(items: req.items, start: req.index) }
        .quickLookPreview($preview)
        .sheet(item: $share) { ActivityView(items: $0.urls) }
        .confirmationDialog("Delete “\(batchURL.lastPathComponent)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete batch", role: .destructive) {
                library.delete(batchURL)
                dismiss()
            }
        } message: {
            Text("Its files are removed from Unpacker. Copies already exported elsewhere are kept.")
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            library.setExportDestination(url)
            Task { await library.export(batchURL) }
        }
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

struct FileRow: View {
    let url: URL
    let base: URL
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
        .accessibilityLabel(Media.isVideo(url) ? "Play \(name)" : "Open \(name)")
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

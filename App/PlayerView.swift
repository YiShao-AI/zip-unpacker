import AVFoundation
import AVKit
import SwiftUI

/// Full-screen player for every video in a batch. Swipe left/right (like Photos) for the next or previous one.
struct PlayerView: View {
    let items: [URL]
    @State private var index: Int
    @State private var share: ShareItems?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pool = PlayerPool()

    init(items: [URL], start: Int) {
        self.items = items
        _index = State(initialValue: min(max(start, 0), max(items.count - 1, 0)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Done") { dismiss() }.fontWeight(.semibold)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(items[index].lastPathComponent).font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(index + 1) of \(items.count) in this batch").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { share = ShareItems(urls: [items[index]]) } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share video")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            TabView(selection: $index) {
                ForEach(items.indices, id: \.self) { i in
                    page(i).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                Button { withAnimation { index -= 1 } } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(index == 0)
                Spacer()
                Text("Swipe for next or previous").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { withAnimation { index += 1 } } label: {
                    HStack(spacing: 4) { Text("Next"); Image(systemName: "chevron.right") }
                }
                .disabled(index >= items.count - 1)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .padding(.bottom, 4)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(.white)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            pool.activate(index, items: items)
        }
        .onChange(of: index) { pool.activate($0, items: items) }
        .onDisappear { pool.stopAll() }
        .sheet(item: $share) { ActivityView(items: $0.urls) }
    }

    @ViewBuilder
    private func page(_ i: Int) -> some View {
        if let player = pool.players[i] {
            PlayerController(player: player)
        } else if !Media.isPlayable(items[i]) {
            VStack(spacing: 14) {
                Image(systemName: "film").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Unpacker can't play .\(items[i].pathExtension) videos.")
                Button("Open in another app") { share = ShareItems(urls: [items[i]]) }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Keeps players for the current video and its neighbours, so a swipe starts playing straight away.
@MainActor
final class PlayerPool: ObservableObject {
    private(set) var players: [Int: AVPlayer] = [:]
    private var current: Int?

    func activate(_ index: Int, items: [URL]) {
        let keep = Set([index - 1, index, index + 1].filter { items.indices.contains($0) })
        for (i, p) in players where !keep.contains(i) {
            p.pause()
            players[i] = nil
        }
        for i in keep where players[i] == nil && Media.isPlayable(items[i]) {
            let p = AVPlayer(url: items[i])
            p.actionAtItemEnd = .pause
            players[i] = p
        }
        for (i, p) in players where i != index { p.pause() }
        if current != index, let p = players[index] {
            p.seek(to: .zero)
            p.play()
        }
        current = index
        objectWillChange.send()
    }

    func stopAll() {
        players.values.forEach { $0.pause() }
        players = [:]
        current = nil
    }
}

/// The standard iOS player: scrubber, ±15 s, AirPlay, Picture in Picture.
struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.view.backgroundColor = .black
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

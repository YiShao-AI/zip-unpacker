import AVFoundation
import AVKit
import SwiftUI

/// Full-screen player for every video in a batch. Swipe left/right (like Photos) for the next or previous one.
struct PlayerView: View {
    let items: [URL]
    @State private var index: Int
    @State private var share: ShareItems?
    @Environment(\.dismiss) private var dismiss

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

            VideoPager(items: items, index: $index) { url in share = ShareItems(urls: [url]) }

            HStack {
                Button { index -= 1 } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(index == 0)
                Spacer()
                Text("Swipe for next or previous").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { index += 1 } label: {
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
        }
        .sheet(item: $share) { ActivityView(items: $0.urls) }
    }
}

/// UIKit page controller: the slide always finishes before the next video starts, like Photos.
struct VideoPager: UIViewControllerRepresentable {
    let items: [URL]
    @Binding var index: Int
    let onShare: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 16])
        pager.view.backgroundColor = .black
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        context.coordinator.parent = self
        pager.setViewControllers([context.coordinator.page(index)], direction: .forward, animated: false)
        context.coordinator.didShow(index)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let c = context.coordinator
        c.parent = self
        // Previous/Next buttons: slide to the new page, then start it.
        guard !c.transitioning, c.shown != index, items.indices.contains(index) else { return }
        let target = index
        c.transitioning = true
        pager.setViewControllers([c.page(target)], direction: target > c.shown ? .forward : .reverse, animated: true) { _ in
            c.transitioning = false
            c.didShow(target)
            if c.parent.index != target { c.parent.index = target }
        }
    }

    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        coordinator.stopAll()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VideoPager?
        let items: [URL]
        private var pages: [Int: VideoPage] = [:]
        var shown = -1
        var transitioning = false

        init(items: [URL]) { self.items = items }

        func page(_ i: Int) -> VideoPage {
            if let p = pages[i] { return p }
            let p = VideoPage(index: i, url: items[i]) { [weak self] url in self?.parent?.onShare(url) }
            pages[i] = p
            return p
        }

        /// Plays the page now on screen from the start, pauses the rest, keeps only its neighbours loaded.
        func didShow(_ i: Int) {
            shown = i
            for (k, p) in pages where abs(k - i) > 1 {
                p.release()
                pages[k] = nil
            }
            for k in [i - 1, i + 1] where items.indices.contains(k) { page(k).loadViewIfNeeded() }
            for (k, p) in pages {
                if k == i { p.playFromStart() } else { p.pause() }
            }
        }

        func stopAll() {
            pages.values.forEach { $0.release() }
            pages = [:]
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let p = vc as? VideoPage, p.index > 0 else { return nil }
            return page(p.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let p = vc as? VideoPage, p.index < items.count - 1 else { return nil }
            return page(p.index + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
            transitioning = true
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            guard let p = pvc.viewControllers?.first as? VideoPage else { return }
            if p.index != shown { didShow(p.index) }
            if parent?.index != p.index { parent?.index = p.index }
        }
    }
}

/// One video: the standard iOS player (scrubber, ±15 s, AirPlay, Picture in Picture), or a note for formats iOS can't play.
final class VideoPage: UIViewController {
    let index: Int
    let url: URL
    private let onShare: (URL) -> Void
    private var playerVC: AVPlayerViewController?

    init(index: Int, url: URL, onShare: @escaping (URL) -> Void) {
        self.index = index
        self.url = url
        self.onShare = onShare
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let child: UIViewController
        if Media.isPlayable(url) {
            let pv = AVPlayerViewController()
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            pv.player = player
            pv.allowsPictureInPicturePlayback = true
            pv.entersFullScreenWhenPlaybackBegins = false
            pv.exitsFullScreenWhenPlaybackEnds = false
            pv.view.backgroundColor = .black
            playerVC = pv
            child = pv
        } else {
            let url = url, onShare = onShare
            let note = UIHostingController(rootView: UnplayableNote(ext: url.pathExtension) { onShare(url) })
            note.view.backgroundColor = .black
            child = note
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    func playFromStart() {
        loadViewIfNeeded()
        guard let player = playerVC?.player else { return }
        player.seek(to: .zero)
        player.play()
    }

    func pause() { playerVC?.player?.pause() }

    func release() {
        pause()
        playerVC?.player = nil
    }
}

struct UnplayableNote: View {
    let ext: String
    let share: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Unpacker can't play .\(ext) videos.").foregroundStyle(.white)
            Button("Open in another app", action: share).buttonStyle(.bordered).tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

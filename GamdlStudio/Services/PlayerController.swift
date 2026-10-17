import AVFoundation
import Foundation
import Observation

/// Built-in player for listening to a downloaded track without leaving the app.
@MainActor
@Observable
final class PlayerController {
    private(set) var current: LibraryTrack?
    private(set) var album: LibraryAlbum?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
    }

    var fraction: Double { duration > 0 ? position / duration : 0 }

    func play(_ track: LibraryTrack, in album: LibraryAlbum?) {
        if current?.url == track.url { toggle(); return }
        current = track
        self.album = album
        position = 0
        duration = 0
        let item = AVPlayerItem(url: track.url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        player.play()
        isPlaying = true
    }

    func toggle() {
        guard current != nil else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let target = CMTime(seconds: duration * min(max(fraction, 0), 1), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        position = target.seconds
    }

    func next() { step(+1) }
    func previous() {
        if position > 3 { seek(to: 0); return }
        step(-1)
    }

    private func step(_ delta: Int) {
        guard let album, let current, let i = album.tracks.firstIndex(of: current) else { stop(); return }
        let j = i + delta
        guard album.tracks.indices.contains(j) else { stop(); return }
        self.current = nil
        play(album.tracks[j], in: album)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        current = nil
        album = nil
        position = 0
        duration = 0
    }
}

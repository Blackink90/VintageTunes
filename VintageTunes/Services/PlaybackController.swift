import Foundation
import AVFoundation
import Combine

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var nowPlaying: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    /// Coda della lista da cui è partita la riproduzione (per ◀◀ / ▶▶).
    private(set) var queue: [Track] = []

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusCancellable: AnyCancellable?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var currentTimeLabel: String { format(currentTime) }
    var durationLabel: String { format(duration) }

    func play(_ track: Track, queue newQueue: [Track]? = nil) {
        if let newQueue {
            queue = newQueue
        } else if queue.isEmpty {
            queue = [track]
        } else if !queue.contains(where: { $0.id == track.id }) {
            queue.append(track)
        }

        guard let url = track.resolvedPath,
              FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File audio non trovato"
            return
        }

        stopInternal(clearTrack: false, clearQueue: false)
        errorMessage = nil
        nowPlaying = track

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        statusCancellable = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Riproduzione fallita"
                    self.isPlaying = false
                }
            }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let item = self.player?.currentItem {
                let d = item.duration.seconds
                if d.isFinite, d > 0 {
                    self.duration = d
                } else if track.durationMs > 0 {
                    self.duration = Double(track.durationMs) / 1000
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.playNext() {
                    self.isPlaying = false
                    self.currentTime = self.duration
                }
            }
        }

        if track.durationMs > 0 {
            duration = Double(track.durationMs) / 1000
        }

        newPlayer.play()
        isPlaying = true
    }

    @discardableResult
    func playNext() -> Bool {
        guard let current = nowPlaying,
              let idx = queue.firstIndex(where: { $0.id == current.id }),
              idx + 1 < queue.count else {
            return false
        }
        play(queue[idx + 1])
        return true
    }

    @discardableResult
    func playPrevious() -> Bool {
        // Comportamento iPod: oltre ~3s riparte il brano corrente.
        if currentTime > 3, let current = nowPlaying {
            seekToStart()
            if !isPlaying {
                player?.play()
                isPlaying = true
            }
            return true
        }
        guard let current = nowPlaying,
              let idx = queue.firstIndex(where: { $0.id == current.id }),
              idx > 0 else {
            seekToStart()
            return false
        }
        play(queue[idx - 1])
        return true
    }

    func togglePlayPause() {
        guard let player, nowPlaying != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration, duration > 0 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        stopInternal(clearTrack: true, clearQueue: true)
    }

    func playOrToggle(_ track: Track, queue newQueue: [Track]? = nil) {
        if nowPlaying?.id == track.id {
            togglePlayPause()
        } else {
            play(track, queue: newQueue)
        }
    }

    private func seekToStart() {
        player?.seek(to: .zero)
        currentTime = 0
    }

    private func stopInternal(clearTrack: Bool, clearQueue: Bool) {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusCancellable = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if clearTrack {
            nowPlaying = nil
        }
        if clearQueue {
            queue = []
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

import Foundation
import Darwin

/// Osserva una cartella e individua file audio non ancora presenti in libreria.
@MainActor
final class FolderSyncService {
    var onFolderChanged: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: CInt = -1
    private var debounceTask: Task<Void, Never>?

    func startWatching(url: URL) {
        stopWatching()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib, .link, .revoke],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.scheduleChangeNotification()
        }
        src.setCancelHandler { [weak self] in
            if let self, self.directoryFileDescriptor >= 0 {
                close(self.directoryFileDescriptor)
                self.directoryFileDescriptor = -1
            }
        }
        source = src
        src.resume()
    }

    func stopWatching() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
        if directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
            directoryFileDescriptor = -1
        }
    }

    private func scheduleChangeNotification() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            onFolderChanged?()
        }
    }

    /// Scansiona la cartella e restituisce i file audio mancanti sull’iPod.
    static func findNewCandidates(
        in folder: URL,
        libraryTracks: [Track],
        dismissedHashes: Set<String>
    ) async -> [AutoSyncCandidate] {
        let files = AudioFileCollector.collectAudioFiles(from: [folder])
        guard !files.isEmpty else { return [] }

        let existingHashes = Set(libraryTracks.compactMap(\.contentHash))
        let existingIdentities = Set(libraryTracks.map(\.identityKey))

        var results: [AutoSyncCandidate] = []
        results.reserveCapacity(min(files.count, 64))

        for url in files {
            if Task.isCancelled { break }

            let hash: String
            do {
                hash = try await Task.detached(priority: .utility) {
                    try FileHasher.sha256(of: url)
                }.value
            } catch {
                continue
            }

            if dismissedHashes.contains(hash) || existingHashes.contains(hash) {
                continue
            }

            let meta = await AudioMetadataReader.read(url: url)
            let identity = meta.identityKey
            let hasMeaningfulIdentity = !meta.artist.isEmpty || !meta.title.isEmpty
            if hasMeaningfulIdentity, existingIdentities.contains(identity) {
                continue
            }

            let needsConversion =
                AudioConverter.needsConversion(url) && !AudioMetadataReader.isSupportedAudio(url)

            results.append(
                AutoSyncCandidate(
                    url: url,
                    title: meta.title,
                    artist: meta.artist,
                    album: meta.album,
                    contentHash: hash,
                    needsConversion: needsConversion
                )
            )
        }

        return results.sorted { a, b in
            let artistCmp = a.displayArtist.localizedCaseInsensitiveCompare(b.displayArtist)
            if artistCmp != .orderedSame { return artistCmp == .orderedAscending }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
    }
}

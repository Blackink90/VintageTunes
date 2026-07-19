import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor
final class LibraryController: ObservableObject {
    @Published var connectedDevice: iPodDevice?
    @Published var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var selectedSection: LibrarySection = .songs
    @Published var selectedPlaylistID: UInt64?
    @Published var searchText = ""
    @Published var selection = Set<Track.ID>()
    @Published var syncStatus: SyncStatus = .idle
    @Published var isLoading = false
    @Published var dbVersion: UInt32 = 0x14
    @Published var pendingImports: [ImportCandidate] = []
    @Published var conversionPrompt: ConversionPrompt?

    let detector = iPodDetector()
    private let sync = SyncService()
    private var detectorCancellable: AnyCancellable?

    var filteredTracks: [Track] {
        let base: [Track]
        if selectedSection == .playlists, let pid = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == pid }) {
            let map = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            base = playlist.trackIDs.compactMap { map[$0] }
        } else {
            base = tracks
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    var artists: [(name: String, count: Int)] {
        Dictionary(grouping: tracks, by: \.displayArtist)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var albums: [(name: String, artist: String, count: Int)] {
        Dictionary(grouping: tracks, by: { "\($0.displayAlbum)|||(\($0.displayArtist))" })
            .map { _, group in
                (name: group[0].displayAlbum, artist: group[0].displayArtist, count: group.count)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start() {
        detector.start()
        detectorCancellable = detector.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.handleDevices(devices)
            }
    }

    func refresh() {
        detector.scan()
        if let device = connectedDevice {
            Task { await load(device: device) }
        }
    }

    func eject() {
        guard let device = connectedDevice else { return }
        if device.isSimulated {
            connectedDevice = nil
            tracks = []
            playlists = []
            selection.removeAll()
            syncStatus = .success("Demo disconnessa")
            return
        }
        do {
            try detector.eject(device)
            connectedDevice = nil
            tracks = []
            playlists = []
            syncStatus = .success("iPod espulso")
        } catch {
            syncStatus = .failure(error.localizedDescription)
        }
    }

    func startDemo(reset: Bool = false) {
        Task {
            do {
                let device = try SimulatediPod.prepare(reset: reset)
                await load(device: device)
                syncStatus = .success(reset ? "Demo azzerata e ricaricata" : "Modalità demo attiva")
            } catch {
                syncStatus = .failure("Impossibile creare la demo: \(error.localizedDescription)")
            }
        }
    }

    func revealDemoFolder() {
        SimulatediPod.revealInFinder()
    }

    func revealMusicFolder() {
        guard let device = connectedDevice else { return }
        let url = device.musicURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealConvertedFolder() {
        let url = AudioConverter.convertedFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func revealSelectedTracksInFinder() {
        let urls = tracks.compactMap { track -> URL? in
            guard selection.contains(track.id) else { return nil }
            return track.resolvedPath
        }.filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !urls.isEmpty else {
            syncStatus = .failure("File non trovato sul dispositivo")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func load(device: iPodDevice) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var result = try sync.loadLibrary(for: device)
            let before = result.tracks
            await sync.backfillMissingMetadata(&result.tracks)
            if result.tracks != before {
                try? sync.savePlaylists(
                    tracks: result.tracks,
                    playlists: result.playlists,
                    dbVersion: result.dbVersion,
                    device: device
                )
            }
            connectedDevice = device
            tracks = result.tracks
            playlists = result.playlists
            dbVersion = result.dbVersion
            if selectedPlaylistID == nil {
                selectedPlaylistID = playlists.first(where: { !$0.isMaster })?.id
            }
            syncStatus = .success("Caricate \(result.tracks.count) tracce")
        } catch {
            syncStatus = .failure(error.localizedDescription)
        }
    }

    func importDroppedURLs(_ urls: [URL]) {
        // Evita di lavorare dentro la callback IPC del drag (kDragIPCCompleted / reentrant).
        DispatchQueue.main.async {
            self.prepareImport(urls)
        }
    }

    func confirmConversion() {
        guard let prompt = conversionPrompt else { return }
        conversionPrompt = nil
        Task {
            await runImport(
                ready: prompt.readyURLs,
                toConvert: prompt.convertibleURLs,
                convert: true
            )
        }
    }

    func declineConversion() {
        guard let prompt = conversionPrompt else { return }
        conversionPrompt = nil
        if prompt.readyURLs.isEmpty {
            syncStatus = .failure("Trasferimento annullato: nessun file compatibile")
            return
        }
        Task {
            await runImport(ready: prompt.readyURLs, toConvert: [], convert: false)
        }
    }

    private func prepareImport(_ urls: [URL]) {
        Task {
            guard connectedDevice != nil else {
                syncStatus = .failure("Collega un iPod (o avvia la demo) per sincronizzare")
                return
            }

            let ready = urls.filter(AudioMetadataReader.isSupportedAudio)
            let convertible = urls.filter {
                AudioConverter.needsConversion($0) && !AudioMetadataReader.isSupportedAudio($0)
            }
            let rejected = urls.filter { url in
                !ready.contains(where: { $0 == url }) && !convertible.contains(where: { $0 == url })
            }

            if !convertible.isEmpty {
                conversionPrompt = ConversionPrompt(
                    convertibleURLs: convertible,
                    readyURLs: ready,
                    rejectedNames: rejected.map(\.lastPathComponent)
                )
                syncStatus = .idle
                return
            }

            if ready.isEmpty {
                syncStatus = .failure(
                    AudioMetadataReader.rejectionMessage(
                        for: urls,
                        firmware: connectedDevice?.firmwareMode ?? .stock
                    ) ?? "Nessun file audio supportato"
                )
                return
            }

            await runImport(ready: ready, toConvert: [], convert: false)
        }
    }

    private func runImport(
        ready: [URL],
        toConvert: [URL],
        convert: Bool
    ) async {
        var accessed: [URL] = []
        for url in ready + toConvert {
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            }
        }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        guard let device = connectedDevice else {
            syncStatus = .failure("Collega un iPod (o avvia la demo) per sincronizzare")
            return
        }

        var items: [ImportCandidate] = []
        var tempFiles: [URL] = []

        for url in ready {
            syncStatus = .working("Leggo \(url.lastPathComponent)…")
            items.append(await AudioMetadataReader.read(url: url))
        }

        if convert {
            for (index, url) in toConvert.enumerated() {
                syncStatus = .working("Leggo tag \(index + 1)/\(toConvert.count): \(url.lastPathComponent)")
                // Leggi i tag DAL FILE ORIGINALE (FLAC ecc.) prima della conversione:
                // afconvert non copia artista/album nel M4A.
                let sourceMeta = await AudioMetadataReader.read(url: url)

                syncStatus = .working("Conversione \(index + 1)/\(toConvert.count): \(url.lastPathComponent)")
                do {
                    let niceNameParts = [sourceMeta.artist, sourceMeta.title].filter { !$0.isEmpty }
                    let niceName = niceNameParts.isEmpty
                        ? sourceMeta.title
                        : niceNameParts.joined(separator: " - ")
                    let m4a = try await AudioConverter.convertToM4A(
                        url,
                        preferredName: niceName
                    ) { message in
                        Task { @MainActor in self.syncStatus = .working(message) }
                    }
                    // Se la durata mancava sul FLAC, prova dal M4A
                    var merged = AudioMetadataReader.remapped(sourceMeta, to: m4a)
                    if merged.durationMs == 0 {
                        let m4aMeta = await AudioMetadataReader.read(url: m4a)
                        if m4aMeta.durationMs > 0 {
                            merged = ImportCandidate(
                                url: m4a,
                                title: merged.title,
                                artist: merged.artist,
                                album: merged.album,
                                genre: merged.genre,
                                durationMs: m4aMeta.durationMs,
                                sizeBytes: m4aMeta.sizeBytes,
                                trackNumber: merged.trackNumber,
                                year: merged.year,
                                bitrate: merged.bitrate == 0 ? 256 : merged.bitrate,
                                sampleRate: m4aMeta.sampleRate > 0 ? m4aMeta.sampleRate : merged.sampleRate
                            )
                        }
                    }
                    items.append(merged)
                    tempFiles.append(m4a)
                } catch {
                    syncStatus = .failure("Conversione fallita: \(error.localizedDescription)")
                    tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
                    return
                }
            }
        }

        guard !items.isEmpty else {
            syncStatus = .failure("Nessun file da trasferire")
            return
        }

        syncStatus = .working("Preparazione import…")
        do {
            let result = try await sync.importFiles(
                items,
                to: device,
                existingTracks: tracks,
                existingPlaylists: playlists,
                dbVersion: dbVersion,
                targetPlaylistID: selectedSection == .playlists ? selectedPlaylistID : nil
            ) { progress in
                Task { @MainActor in
                    self.syncStatus = .working(progress.message)
                }
            }
            tracks = result.tracks
            playlists = result.playlists
            dbVersion = result.dbVersion
            let converted = tempFiles.count
            if converted > 0 {
                syncStatus = .success("Aggiunte \(items.count) canzoni (\(converted) convertite in M4A)")
            } else {
                syncStatus = .success("Aggiunte \(items.count) canzoni")
            }
            selectedSection = .songs
        } catch {
            syncStatus = .failure(error.localizedDescription)
        }

        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func createPlaylist(named name: String) {
        guard let device = connectedDevice else { return }
        let playlist = sync.createPlaylist(name: name, playlists: &playlists)
        selectedSection = .playlists
        selectedPlaylistID = playlist.id
        persistPlaylists(device: device)
    }

    func renamePlaylist(_ id: UInt64, to name: String) {
        guard let device = connectedDevice,
              let idx = playlists.firstIndex(where: { $0.id == id && !$0.isMaster }) else { return }
        playlists[idx].name = name
        persistPlaylists(device: device)
    }

    func deletePlaylist(_ id: UInt64) {
        guard let device = connectedDevice else { return }
        playlists.removeAll { $0.id == id && !$0.isMaster }
        if selectedPlaylistID == id {
            selectedPlaylistID = playlists.first(where: { !$0.isMaster })?.id
        }
        persistPlaylists(device: device)
    }

    func addSelectionToPlaylist(_ playlistID: UInt64) {
        guard let device = connectedDevice,
              let idx = playlists.firstIndex(where: { $0.id == playlistID && !$0.isMaster }) else { return }
        let ids = selection
        for id in ids where !playlists[idx].trackIDs.contains(id) {
            playlists[idx].trackIDs.append(id)
        }
        persistPlaylists(device: device)
        syncStatus = .success("Aggiunte \(ids.count) tracce alla playlist")
    }

    func removeSelectionFromCurrentPlaylist() {
        guard let device = connectedDevice,
              let pid = selectedPlaylistID,
              let idx = playlists.firstIndex(where: { $0.id == pid && !$0.isMaster }) else { return }
        playlists[idx].trackIDs.removeAll { selection.contains($0) }
        persistPlaylists(device: device)
    }

    func deleteSelectedTracks() {
        guard let device = connectedDevice, !selection.isEmpty else { return }
        do {
            try sync.deleteTracks(
                ids: selection,
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device
            )
            selection.removeAll()
            syncStatus = .success("Tracce rimosse dall'iPod")
        } catch {
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func persistPlaylists(device: iPodDevice) {
        do {
            try sync.savePlaylists(tracks: tracks, playlists: playlists, dbVersion: dbVersion, device: device)
            syncStatus = .success("Playlist salvate")
        } catch {
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func handleDevices(_ devices: [iPodDevice]) {
        if let current = connectedDevice {
            if current.isSimulated {
                // Resta in demo finché non arriva un iPod reale.
                if let real = devices.first(where: { !$0.isSimulated }) {
                    Task { await load(device: real) }
                }
                return
            }

            if let updated = devices.first(where: { $0.id == current.id }) {
                connectedDevice = updated
            } else {
                connectedDevice = nil
                tracks = []
                playlists = []
                syncStatus = .idle
            }
        }

        if connectedDevice == nil, let first = devices.first {
            Task { await load(device: first) }
        }
    }
}

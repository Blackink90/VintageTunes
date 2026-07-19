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
    @Published var browseArtist: String?
    @Published var browseAlbum: AlbumRef?
    @Published var searchText = ""
    @Published var selection = Set<Track.ID>()
    @Published var syncStatus: SyncStatus = .idle
    @Published var isLoading = false
    @Published var dbVersion: UInt32 = 0x14
    @Published var pendingImports: [ImportCandidate] = []
    @Published var conversionPrompt: ConversionPrompt?
    @Published var trackEditDraft: TrackEditDraft?

    let detector = iPodDetector()
    let playback = PlaybackController()
    let artwork = ArtworkCache.shared
    private let sync = SyncService()
    private var detectorCancellable: AnyCancellable?
    private var statusDismissTask: Task<Void, Never>?

    /// Aggiorna lo stato UI; success/failure spariscono da soli dopo pochi secondi.
    func setStatus(_ status: SyncStatus) {
        statusDismissTask?.cancel()
        syncStatus = status
        switch status {
        case .success, .failure:
            let captured = status
            statusDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                if self.syncStatus == captured {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.syncStatus = .idle
                    }
                }
            }
        case .idle, .working:
            break
        }
    }

    var filteredTracks: [Track] {
        let base: [Track]
        if selectedSection == .playlists, let pid = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == pid }) {
            let map = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            base = playlist.trackIDs.compactMap { map[$0] }
        } else if let album = browseAlbum {
            base = tracks.filter {
                $0.displayAlbum == album.name && $0.displayArtist == album.artist
            }
        } else if let artist = browseArtist {
            base = tracks.filter { $0.displayArtist == artist }
        } else {
            base = tracks
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
                || $0.genre.localizedCaseInsensitiveContains(q)
                || ($0.year != 0 && "\($0.year)".contains(q))
        }
    }

    /// Brani usati per la barra riepilogo: selezione se presente, altrimenti lista corrente.
    var statsTracks: [Track] {
        let scope = filteredTracks
        if selection.isEmpty { return scope }
        let selected = scope.filter { selection.contains($0.id) }
        return selected.isEmpty ? scope : selected
    }

    var artists: [(name: String, count: Int)] {
        Dictionary(grouping: tracks, by: \.displayArtist)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var albums: [AlbumRef] {
        albums(forArtist: nil)
    }

    func albums(forArtist artist: String?) -> [AlbumRef] {
        let source: [Track]
        if let artist {
            source = tracks.filter { $0.displayArtist == artist }
        } else {
            source = tracks
        }
        return Dictionary(grouping: source, by: \.albumKey)
            .map { _, group in
                AlbumRef(
                    name: group[0].displayAlbum,
                    artist: group[0].displayArtist,
                    trackCount: group.count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func representativeTrack(for album: AlbumRef) -> Track? {
        tracks.first {
            $0.displayAlbum == album.name
                && $0.displayArtist == album.artist
                && $0.resolvedPath != nil
        } ?? tracks.first {
            $0.displayAlbum == album.name && $0.displayArtist == album.artist
        }
    }

    /// Cover “stile Apple” per artista: album più recente (anno), altrimenti primo in ordine alfabetico.
    func representativeTrack(forArtist name: String) -> Track? {
        let artistAlbums = albums(forArtist: name)
        guard !artistAlbums.isEmpty else {
            return tracks.first { $0.displayArtist == name && $0.resolvedPath != nil }
                ?? tracks.first { $0.displayArtist == name }
        }

        let ranked = artistAlbums.sorted { a, b in
            let ya = maxYear(for: a)
            let yb = maxYear(for: b)
            if ya != yb { return ya > yb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        for album in ranked {
            if let track = representativeTrack(for: album) {
                return track
            }
        }
        return nil
    }

    private func maxYear(for album: AlbumRef) -> UInt32 {
        tracks
            .filter { $0.displayAlbum == album.name && $0.displayArtist == album.artist }
            .map(\.year)
            .max() ?? 0
    }

    func selectSection(_ section: LibrarySection) {
        selectedSection = section
        clearBrowse()
        if section != .playlists {
            selectedPlaylistID = nil
        }
        selection.removeAll()
        searchText = ""
    }

    func openArtist(_ name: String) {
        browseArtist = name
        browseAlbum = nil
        selection.removeAll()
        searchText = ""
    }

    func openAlbum(_ album: AlbumRef) {
        browseAlbum = album
        if selectedSection == .artists, browseArtist == nil {
            browseArtist = album.artist
        }
        selection.removeAll()
        searchText = ""
    }

    func browseBack() {
        if browseAlbum != nil {
            browseAlbum = nil
            if selectedSection == .albums {
                browseArtist = nil
            }
        } else if browseArtist != nil {
            browseArtist = nil
        }
        selection.removeAll()
        searchText = ""
    }

    func clearBrowse() {
        browseArtist = nil
        browseAlbum = nil
    }

    private func prefetchArtwork() {
        for album in albums {
            guard let track = representativeTrack(for: album) else { continue }
            artwork.request(artist: album.artist, album: album.name, fileURL: track.resolvedPath)
        }
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
        playback.stop()
        guard let device = connectedDevice else { return }
        if device.isSimulated {
            connectedDevice = nil
            tracks = []
            playlists = []
            selection.removeAll()
            clearBrowse()
            artwork.clear()
            setStatus(.success("Demo disconnessa"))
            return
        }
        do {
            try detector.eject(device)
            connectedDevice = nil
            tracks = []
            playlists = []
            clearBrowse()
            artwork.clear()
            setStatus(.success("iPod espulso"))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func playTrack(_ track: Track) {
        playback.play(track)
    }

    func beginEditingSelectedTrack() {
        guard selection.count == 1, let id = selection.first,
              let track = tracks.first(where: { $0.id == id }) else { return }
        trackEditDraft = TrackEditDraft(track: track)
    }

    func beginEditingTrack(id: UInt32) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        selection = [id]
        trackEditDraft = TrackEditDraft(track: track)
    }

    func cancelTrackEdit() {
        trackEditDraft = nil
    }

    func saveTrackEdit() {
        guard var draft = trackEditDraft,
              let device = connectedDevice,
              let idx = tracks.firstIndex(where: { $0.id == draft.trackID }) else {
            trackEditDraft = nil
            return
        }

        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.artist = draft.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.album = draft.album.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.genre = draft.genre.trimmingCharacters(in: .whitespacesAndNewlines)

        let trackNumber = UInt32(draft.trackNumber.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let year = UInt32(draft.year.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        tracks[idx].title = draft.title
        tracks[idx].artist = draft.artist
        tracks[idx].album = draft.album
        tracks[idx].genre = draft.genre
        tracks[idx].trackNumber = trackNumber
        tracks[idx].year = year

        var overrides = TrackTagStore.load(from: device)
        overrides[tracks[idx].location] = TrackTagOverride(
            title: draft.title,
            artist: draft.artist,
            album: draft.album,
            genre: draft.genre,
            trackNumber: trackNumber,
            year: year
        )

        do {
            try TrackTagStore.save(overrides, to: device)
            try sync.savePlaylists(
                tracks: tracks,
                playlists: playlists,
                dbVersion: dbVersion,
                device: device
            )
            artwork.request(
                artist: tracks[idx].displayArtist,
                album: tracks[idx].displayAlbum,
                fileURL: tracks[idx].resolvedPath
            )
            trackEditDraft = nil
            setStatus(.success("Informazioni brano aggiornate"))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func playSelectedOrToggle() {
        if let id = selection.first, let track = tracks.first(where: { $0.id == id }) {
            playback.playOrToggle(track)
            return
        }
        playback.togglePlayPause()
    }

    func startDemo(reset: Bool = false) {
        Task {
            do {
                let device = try SimulatediPod.prepare(reset: reset)
                await load(device: device)
                setStatus(.success(reset ? "Demo azzerata e ricaricata" : "Modalità demo attiva"))
            } catch {
                setStatus(.failure("Impossibile creare la demo: \(error.localizedDescription)"))
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
            setStatus(.failure("File non trovato sul dispositivo"))
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
            TrackTagStore.apply(TrackTagStore.load(from: device), to: &result.tracks)
            if result.tracks != before {
                try? sync.savePlaylists(
                    tracks: result.tracks,
                    playlists: result.playlists,
                    dbVersion: result.dbVersion,
                    device: device
                )
            }
            connectedDevice = device
            artwork.clear()
            clearBrowse()
            tracks = result.tracks
            playlists = pruneOrphanPlaylistEntries(result.playlists, tracks: result.tracks)
            dbVersion = result.dbVersion
            if playlists != result.playlists {
                try? sync.savePlaylists(
                    tracks: tracks,
                    playlists: playlists,
                    dbVersion: dbVersion,
                    device: device
                )
            }
            prefetchArtwork()
            if selectedPlaylistID == nil {
                selectedPlaylistID = playlists.first(where: { !$0.isMaster })?.id
            }
            setStatus(.success("Caricate \(result.tracks.count) tracce"))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func importDroppedURLs(_ urls: [URL]) {
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
            setStatus(.failure("Trasferimento annullato: nessun file compatibile"))
            return
        }
        Task {
            await runImport(ready: prompt.readyURLs, toConvert: [], convert: false)
        }
    }

    private func prepareImport(_ urls: [URL]) {
        Task {
            guard connectedDevice != nil else {
                setStatus(.failure("Collega un iPod (o avvia la demo) per sincronizzare"))
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
                setStatus(.idle)
                return
            }

            if ready.isEmpty {
                setStatus(.failure(
                    AudioMetadataReader.rejectionMessage(
                        for: urls,
                        firmware: connectedDevice?.firmwareMode ?? .stock
                    ) ?? "Nessun file audio supportato"
                ))
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
            setStatus(.failure("Collega un iPod (o avvia la demo) per sincronizzare"))
            return
        }

        var items: [ImportCandidate] = []
        var tempFiles: [URL] = []
        var skippedBeforeImport = 0

        for url in ready {
            setStatus(.working("Leggo \(url.lastPathComponent)…"))
            var meta = await AudioMetadataReader.read(url: url)
            meta.contentHash = try? FileHasher.sha256(of: url)
            if tracks.contains(where: { $0.contentHash == meta.contentHash && meta.contentHash != nil })
                || tracks.contains(where: { $0.identityKey == meta.identityKey }) {
                skippedBeforeImport += 1
                continue
            }
            items.append(meta)
        }

        if convert {
            for (index, url) in toConvert.enumerated() {
                setStatus(.working("Leggo tag \(index + 1)/\(toConvert.count): \(url.lastPathComponent)"))
                var sourceMeta = await AudioMetadataReader.read(url: url)
                do {
                    sourceMeta.contentHash = try FileHasher.sha256(of: url)
                } catch {
                    setStatus(.failure("Hash fallito: \(error.localizedDescription)"))
                    return
                }

                if tracks.contains(where: { $0.contentHash == sourceMeta.contentHash })
                    || tracks.contains(where: { $0.identityKey == sourceMeta.identityKey }) {
                    skippedBeforeImport += 1
                    continue
                }

                setStatus(.working("Conversione \(index + 1)/\(toConvert.count): \(url.lastPathComponent)"))
                do {
                    let niceNameParts = [sourceMeta.artist, sourceMeta.title].filter { !$0.isEmpty }
                    let niceName = niceNameParts.isEmpty
                        ? sourceMeta.title
                        : niceNameParts.joined(separator: " - ")
                    let m4a = try await AudioConverter.convertToM4A(
                        url,
                        preferredName: niceName,
                        artist: sourceMeta.artist,
                        album: sourceMeta.album
                    ) { message in
                        Task { @MainActor in self.setStatus(.working(message)) }
                    }
                    var merged = AudioMetadataReader.remapped(sourceMeta, to: m4a)
                    if merged.durationMs == 0 {
                        let m4aMeta = await AudioMetadataReader.read(url: m4a)
                        if m4aMeta.durationMs > 0 {
                            merged.durationMs = m4aMeta.durationMs
                            merged.sizeBytes = m4aMeta.sizeBytes
                            if m4aMeta.sampleRate > 0 { merged.sampleRate = m4aMeta.sampleRate }
                        }
                    }
                    let artData: Data?
                    if let disk = CoverArtService.loadFromDisk(artist: merged.artist, album: merged.album) {
                        artData = disk
                    } else {
                        artData = await CoverArtService.loadEmbeddedData(from: m4a)
                    }
                    if let artData {
                        let artistName = merged.artist.isEmpty ? "Artista sconosciuto" : merged.artist
                        let albumName = merged.album.isEmpty ? "Album sconosciuto" : merged.album
                        artwork.store(artist: artistName, album: albumName, data: artData)
                    }
                    items.append(merged)
                    tempFiles.append(m4a)
                } catch {
                    setStatus(.failure("Conversione fallita: \(error.localizedDescription)"))
                    tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
                    return
                }
            }
        }

        if items.isEmpty {
            removeLibraryDuplicates(silentIfNone: true)
            if skippedBeforeImport > 0 {
                setStatus(.success("Nessuna nuova traccia · \(skippedBeforeImport) già presenti"))
            } else {
                setStatus(.failure("Nessun file da trasferire"))
            }
            return
        }

        setStatus(.working("Preparazione import…"))
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
                    self.setStatus(.working(progress.message))
                }
            }
            tracks = result.tracks
            playlists = result.playlists
            dbVersion = result.dbVersion
            let converted = tempFiles.count
            let skipped = result.skippedDuplicates + skippedBeforeImport
            var parts: [String] = []
            if result.imported > 0 { parts.append("Aggiunte \(result.imported)") }
            if skipped > 0 { parts.append("\(skipped) già presenti (saltate)") }
            if converted > 0 { parts.append("\(converted) convertite in M4A") }
            setStatus(.success(parts.isEmpty ? "Nessuna nuova traccia da aggiungere" : parts.joined(separator: " · ")))
            selectSection(.songs)
            prefetchArtwork()
        } catch {
            setStatus(.failure(error.localizedDescription))
        }

        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func removeLibraryDuplicates(silentIfNone: Bool = false) {
        guard let device = connectedDevice else { return }
        do {
            var hashIndex = TrackHashIndex.load(from: device)
            let removed = try sync.removeDuplicateTracks(
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device,
                hashIndex: &hashIndex,
                persistNow: true
            )
            if removed > 0 {
                if let playingID = playback.nowPlaying?.id,
                   !tracks.contains(where: { $0.id == playingID }) {
                    playback.stop()
                }
                setStatus(.success("Rimossi \(removed) duplicati"))
            } else if !silentIfNone {
                setStatus(.success("Nessun duplicato trovato"))
            }
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func createPlaylist(named name: String) {
        guard let device = connectedDevice else { return }
        let playlist = sync.createPlaylist(name: name, playlists: &playlists)
        selectSection(.playlists)
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
        setStatus(.success("Aggiunte \(ids.count) tracce alla playlist"))
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
        if let playingID = playback.nowPlaying?.id, selection.contains(playingID) {
            playback.stop()
        }
        do {
            try sync.deleteTracks(
                ids: selection,
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device
            )
            selection.removeAll()
            setStatus(.success("Tracce rimosse dall'iPod"))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    private func persistPlaylists(device: iPodDevice) {
        do {
            try sync.savePlaylists(tracks: tracks, playlists: playlists, dbVersion: dbVersion, device: device)
            setStatus(.success("Playlist salvate"))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    private func pruneOrphanPlaylistEntries(_ playlists: [Playlist], tracks: [Track]) -> [Playlist] {
        let known = Set(tracks.map(\.id))
        return playlists.map { playlist in
            var p = playlist
            p.trackIDs = playlist.trackIDs.filter { known.contains($0) }
            return p
        }
    }

    private func handleDevices(_ devices: [iPodDevice]) {
        if let current = connectedDevice {
            if current.isSimulated {
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
                clearBrowse()
                artwork.clear()
                setStatus(.idle)
            }
        }

        if connectedDevice == nil, let first = devices.first {
            Task { await load(device: first) }
        }
    }
}

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
    @Published var browseGenre: String?
    @Published var searchText = ""
    @Published var selection = Set<Track.ID>()
    @Published var syncStatus: SyncStatus = .idle
    @Published var isLoading = false
    @Published var dbVersion: UInt32 = 0x14
    @Published var pendingImports: [ImportCandidate] = []
    @Published var trackEditDraft: TrackEditDraft?
    @Published var showiPodPreview = false
    @Published var autoSyncPrompt: AutoSyncPrompt?

    let detector = iPodDetector()
    let playback = PlaybackController()
    let artwork = ArtworkCache.shared
    private let sync = SyncService()
    private let folderSync = FolderSyncService()
    private weak var appSettings: AppSettings?
    private var detectorCancellable: AnyCancellable?
    private var statusDismissTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var importCancelled = false
    private var autoSyncTask: Task<Void, Never>?
    private var pendingAutoSyncCheck = false
    private var syncFolderScopedURL: URL?

    var isImportRunning: Bool {
        if case .working = syncStatus { return true }
        return false
    }

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
        } else if let genre = browseGenre {
            let inGenre = tracks.filter { $0.genreKey?.caseInsensitiveCompare(genre) == .orderedSame }
            if let artist = browseArtist {
                base = inGenre.filter { $0.displayArtist == artist }
            } else {
                base = inGenre
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
        artists(forGenre: nil)
    }

    func artists(forGenre genre: String?) -> [(name: String, count: Int)] {
        let source: [Track]
        if let genre {
            source = tracks.filter { $0.genreKey?.caseInsensitiveCompare(genre) == .orderedSame }
        } else {
            source = tracks
        }
        return Dictionary(grouping: source, by: \.displayArtist)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var albums: [AlbumRef] {
        albums(forArtist: nil)
    }

    var genres: [GenreRef] {
        Dictionary(grouping: tracks.filter { $0.genreKey != nil }, by: { $0.genreKey! })
            .map { name, group in
                GenreRef(
                    name: name,
                    trackCount: group.count,
                    artistCount: Set(group.map(\.displayArtist)).count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    func representativeTrack(forArtist name: String, genre: String? = nil) -> Track? {
        let pool: [Track]
        if let genre {
            pool = tracks.filter {
                $0.displayArtist == name
                    && $0.genreKey?.caseInsensitiveCompare(genre) == .orderedSame
            }
        } else {
            pool = tracks.filter { $0.displayArtist == name }
        }
        guard !pool.isEmpty else { return nil }

        let albumKeys = Dictionary(grouping: pool, by: \.albumKey)
        let ranked = albumKeys.keys.sorted { a, b in
            let ya = albumKeys[a]?.map(\.year).max() ?? 0
            let yb = albumKeys[b]?.map(\.year).max() ?? 0
            if ya != yb { return ya > yb }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }

        for key in ranked {
            if let track = albumKeys[key]?.first(where: { $0.resolvedPath != nil })
                ?? albumKeys[key]?.first {
                return track
            }
        }
        return pool.first
    }

    func representativeTrack(forGenre name: String) -> Track? {
        let pool = tracks.filter { $0.genreKey?.caseInsensitiveCompare(name) == .orderedSame }
        guard !pool.isEmpty else { return nil }
        // Preferisci traccia con file e anno più alto
        return pool
            .sorted { a, b in
                if a.year != b.year { return a.year > b.year }
                return a.displayAlbum.localizedCaseInsensitiveCompare(b.displayAlbum) == .orderedAscending
            }
            .first(where: { $0.resolvedPath != nil })
            ?? pool.first
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

    func openGenre(_ name: String) {
        browseGenre = name
        browseArtist = nil
        browseAlbum = nil
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
        } else if browseGenre != nil {
            browseGenre = nil
        }
        selection.removeAll()
        searchText = ""
    }

    func clearBrowse() {
        browseArtist = nil
        browseAlbum = nil
        browseGenre = nil
    }

    private func prefetchArtwork() {
        for album in albums {
            guard let track = representativeTrack(for: album) else { continue }
            artwork.request(artist: album.artist, album: album.name, fileURL: track.resolvedPath)
        }
    }

    func start(settings: AppSettings) {
        appSettings = settings
        detector.start()
        detectorCancellable = detector.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.handleDevices(devices)
            }
        folderSync.onFolderChanged = { [weak self] in
            self?.checkAutoSync()
        }
        playback.onTrackPlayStarted = { [weak self] track in
            self?.recordPlayback(of: track.id)
        }
        refreshAutoSyncWatching()
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
            clearAutoSyncUI()
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
            clearAutoSyncUI()
            setStatus(.success("iPod espulso"))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    /// Rinomina l’iPod collegato (etichetta volume, come in iTunes).
    func renameConnectedDevice(to rawName: String) {
        guard let device = connectedDevice else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setStatus(.failure("Il nome non può essere vuoto"))
            return
        }
        guard name != device.name else { return }

        do {
            if device.isSimulated {
                try SimulatediPod.rename(to: name)
                connectedDevice = SimulatediPod.makeDevice(at: SimulatediPod.rootURL)
            } else {
                try detector.rename(device, to: name)
                if let updated = detector.devices.first(where: { $0.id == device.id }) {
                    connectedDevice = updated
                } else {
                    connectedDevice = iPodDevice(
                        id: device.id,
                        name: name,
                        volumeURL: device.volumeURL,
                        capacityBytes: device.capacityBytes,
                        availableBytes: device.availableBytes,
                        modelHint: device.modelHint,
                        firmwareMode: device.firmwareMode,
                        hasDatabase: device.hasDatabase,
                        isSimulated: false
                    )
                }
            }
            setStatus(.success("Rinominato in \"\(name)\""))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func playTrack(_ track: Track) {
        playback.play(track, queue: filteredTracks)
    }

    /// Incrementa play count + last played (come ascolto in iTunes) e salva con debounce.
    func recordPlayback(of trackID: UInt32) {
        guard let idx = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[idx].playCount &+= 1
        tracks[idx].lastPlayedMacTime = Track.macTimestamp()
        schedulePlayStatsPersist()
    }

    private var playStatsPersistTask: Task<Void, Never>?

    private func schedulePlayStatsPersist() {
        playStatsPersistTask?.cancel()
        playStatsPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            persistPlayStatsNow()
        }
    }

    private func persistPlayStatsNow() {
        guard let device = connectedDevice else { return }
        var overrides = TrackTagStore.load(from: device)
        for track in tracks {
            overrides[track.location] = TrackTagOverride(
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                trackNumber: track.trackNumber,
                year: track.year,
                rating: track.rating,
                playCount: track.playCount,
                lastPlayedMacTime: track.lastPlayedMacTime
            )
        }
        do {
            try TrackTagStore.save(overrides, to: device)
            try sync.savePlaylists(
                tracks: tracks,
                playlists: playlists,
                dbVersion: dbVersion,
                device: device
            )
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func refreshArtwork(for ids: [UInt32]) {
        let selected = ids.compactMap { id in tracks.first(where: { $0.id == id }) }
        guard !selected.isEmpty else { return }
        var seen = Set<String>()
        for track in selected {
            let key = artwork.key(artist: track.displayArtist, album: track.displayAlbum)
            guard seen.insert(key).inserted else { continue }
            artwork.refresh(
                artist: track.displayArtist,
                album: track.displayAlbum,
                fileURL: track.resolvedPath
            )
        }
        setStatus(.success(
            selected.count == 1
                ? "Ricarico copertina…"
                : "Ricarico copertine per \(seen.count) album…"
        ))
    }

    func beginEditingSelectedTrack() {
        beginEditingTracks(ids: Array(selection))
    }

    func beginEditingTrack(id: UInt32) {
        beginEditingTracks(ids: [id])
    }

    func beginEditingTracks(ids: [UInt32]) {
        let selected = ids.compactMap { id in tracks.first(where: { $0.id == id }) }
        guard !selected.isEmpty else { return }
        selection = Set(selected.map(\.id))
        trackEditDraft = TrackEditDraft(tracks: selected)
    }

    func cancelTrackEdit() {
        trackEditDraft = nil
    }

    /// Imposta stelle 0…5 su uno o più brani e salva su iPod.
    func setStarRating(_ stars: Int, for ids: [UInt32]) {
        guard let device = connectedDevice, !ids.isEmpty else { return }
        let rating = Track.rating(fromStars: stars)
        var overrides = TrackTagStore.load(from: device)
        var updated = 0

        for id in ids {
            guard let idx = tracks.firstIndex(where: { $0.id == id }) else { continue }
            tracks[idx].rating = rating
            overrides[tracks[idx].location] = TrackTagOverride(
                title: tracks[idx].title,
                artist: tracks[idx].artist,
                album: tracks[idx].album,
                genre: tracks[idx].genre,
                trackNumber: tracks[idx].trackNumber,
                year: tracks[idx].year,
                rating: tracks[idx].rating,
                playCount: tracks[idx].playCount,
                lastPlayedMacTime: tracks[idx].lastPlayedMacTime
            )
            updated += 1
        }

        guard updated > 0 else { return }

        do {
            try TrackTagStore.save(overrides, to: device)
            try sync.savePlaylists(
                tracks: tracks,
                playlists: playlists,
                dbVersion: dbVersion,
                device: device
            )
            setStatus(.success(
                updated == 1
                    ? (stars == 0 ? "Valutazione rimossa" : "Valutazione: \(stars) ★")
                    : "Valutazione aggiornata su \(updated) brani"
            ))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func saveTrackEdit() {
        guard var draft = trackEditDraft,
              let device = connectedDevice,
              !draft.trackIDs.isEmpty else {
            trackEditDraft = nil
            return
        }

        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.artist = draft.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.album = draft.album.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.genre = draft.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackNumberText = draft.trackNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let yearText = draft.year.trimmingCharacters(in: .whitespacesAndNewlines)

        var overrides = TrackTagStore.load(from: device)
        var updated = 0
        var artworkRefresh: [(artist: String, album: String, fileURL: URL?)] = []

        for id in draft.trackIDs {
            guard let idx = tracks.firstIndex(where: { $0.id == id }) else { continue }

            let previousArtist = tracks[idx].displayArtist
            let previousAlbum = tracks[idx].displayAlbum

            if !draft.isMulti {
                tracks[idx].title = draft.title
                tracks[idx].artist = draft.artist
                tracks[idx].album = draft.album
                tracks[idx].genre = draft.genre
                tracks[idx].trackNumber = UInt32(trackNumberText) ?? 0
                tracks[idx].year = UInt32(yearText) ?? 0
                tracks[idx].rating = Track.rating(fromStars: draft.starRating)
            } else {
                // Multi: campo vuoto = non modificare quel dato sul brano
                if !draft.artist.isEmpty { tracks[idx].artist = draft.artist }
                if !draft.album.isEmpty { tracks[idx].album = draft.album }
                if !draft.genre.isEmpty { tracks[idx].genre = draft.genre }
                if !trackNumberText.isEmpty {
                    tracks[idx].trackNumber = UInt32(trackNumberText) ?? 0
                }
                if !yearText.isEmpty {
                    tracks[idx].year = UInt32(yearText) ?? 0
                }
                if !draft.mixedRating {
                    tracks[idx].rating = Track.rating(fromStars: draft.starRating)
                }
            }

            overrides[tracks[idx].location] = TrackTagOverride(
                title: tracks[idx].title,
                artist: tracks[idx].artist,
                album: tracks[idx].album,
                genre: tracks[idx].genre,
                trackNumber: tracks[idx].trackNumber,
                year: tracks[idx].year,
                rating: tracks[idx].rating,
                playCount: tracks[idx].playCount,
                lastPlayedMacTime: tracks[idx].lastPlayedMacTime
            )

            let newArtist = tracks[idx].displayArtist
            let newAlbum = tracks[idx].displayAlbum
            if previousArtist != newArtist || previousAlbum != newAlbum {
                // Non riusare l’embedded del file: può essere dell’album precedente e avvelenare la cache.
                artwork.invalidate(artist: previousArtist, album: previousAlbum)
                artworkRefresh.append((newArtist, newAlbum, tracks[idx].resolvedPath))
            }
            updated += 1
        }

        guard updated > 0 else {
            trackEditDraft = nil
            return
        }

        do {
            try TrackTagStore.save(overrides, to: device)
            try sync.savePlaylists(
                tracks: tracks,
                playlists: playlists,
                dbVersion: dbVersion,
                device: device
            )
            trackEditDraft = nil

            var seenKeys = Set<String>()
            for item in artworkRefresh {
                let key = artwork.key(artist: item.artist, album: item.album)
                guard seenKeys.insert(key).inserted else { continue }
                artwork.refresh(artist: item.artist, album: item.album, fileURL: item.fileURL)
            }

            setStatus(.success(
                updated == 1
                    ? "Informazioni brano aggiornate"
                    : "Informazioni aggiornate su \(updated) brani"
            ))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func playSelectedOrToggle() {
        if let id = selection.first, let track = tracks.first(where: { $0.id == id }) {
            playback.playOrToggle(track, queue: filteredTracks)
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
            await sync.backfillFromFiles(&result.tracks)
            TrackTagStore.apply(TrackTagStore.load(from: device), to: &result.tracks)
            setStatus(.working("Completo metadati mancanti…"))
            await sync.enrichMissingFromOnline(&result.tracks)
            if result.tracks != before {
                // Salva solo override su disco: NON riscrivere iTunesDB al solo collegamento
                // (un rewrite automatico ha già confuso il firmware con sezioni playlist duplicate).
                let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
                var overrides = TrackTagStore.load(from: device)
                for track in result.tracks {
                    guard let old = beforeByID[track.id], old != track else { continue }
                    overrides[track.location] = TrackTagOverride(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        genre: track.genre,
                        trackNumber: track.trackNumber,
                        year: track.year,
                        rating: track.rating,
                        playCount: track.playCount,
                        lastPlayedMacTime: track.lastPlayedMacTime
                    )
                }
                try? TrackTagStore.save(overrides, to: device)
            }
            if device.firmwareMode == .stock {
                setStatus(.working("Verifico cover sul dispositivo…"))
                if try await sync.repairArtworkIfNeeded(
                    tracks: &result.tracks,
                    playlists: result.playlists,
                    dbVersion: result.dbVersion,
                    device: device
                ) {
                    setStatus(.success("Cover riscritte per l'iPod"))
                }
            }
            connectedDevice = device
            artwork.clear()
            clearBrowse()
            tracks = result.tracks
            playlists = pruneOrphanPlaylistEntries(result.playlists, tracks: result.tracks)
            dbVersion = result.dbVersion
            // Non auto-persist playlist prune sul device al load.
            prefetchArtwork()
            if selectedPlaylistID == nil {
                selectedPlaylistID = playlists.first(where: { !$0.isMaster })?.id
            }
            setStatus(.success("Caricate \(result.tracks.count) tracce"))
            checkAutoSync()
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    private var importSecurityRoots: [URL] = []

    func importDroppedURLs(_ urls: [URL]) {
        cancelImport(silent: true)
        importCancelled = false
        importTask = Task { @MainActor in
            await prepareImport(urls)
        }
    }

    func chooseFolderToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Importa"
        panel.message = "Scegli una o più cartelle da scansionare per file audio"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")

        guard panel.runModal() == .OK else { return }
        importDroppedURLs(panel.urls)
    }

    /// Interrompe scan/conversione/import in corso.
    func cancelImport(silent: Bool = false) {
        importCancelled = true
        importTask?.cancel()
        importTask = nil
        releaseImportSecurityRoots()
        if !silent {
            setStatus(.success("Import annullato"))
            finishImportAndMaybeAutoSync()
        }
    }

    private func throwIfImportCancelled() throws {
        try Task.checkCancellation()
        if importCancelled { throw CancellationError() }
    }

    private func beginImportSecurityAccess(for urls: [URL]) {
        releaseImportSecurityRoots()
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                importSecurityRoots.append(url)
            }
        }
    }

    private func releaseImportSecurityRoots() {
        importSecurityRoots.forEach { $0.stopAccessingSecurityScopedResource() }
        importSecurityRoots.removeAll()
    }

    private func prepareImport(_ urls: [URL]) async {
        guard connectedDevice != nil else {
            setStatus(.failure("Collega un iPod (o avvia la demo) per sincronizzare"))
            return
        }

        beginImportSecurityAccess(for: urls)
        setStatus(.working("Cerco file audio…"))

        do {
            try throwIfImportCancelled()
            let files = AudioFileCollector.collectAudioFiles(from: urls)
            try throwIfImportCancelled()

            let ready = files.filter {
                AudioMetadataReader.isSupportedAudio($0) && !AudioConverter.needsConversion($0)
            }
            let convertible = files.filter(AudioConverter.needsConversion)

            if files.isEmpty {
                setStatus(.failure("Nessun file audio trovato nella selezione (mp3, m4a, flac, wav, …)"))
                releaseImportSecurityRoots()
                return
            }

            setStatus(.working("Trovati \(files.count) file audio…"))
            try throwIfImportCancelled()

            // FLAC/WAV/… → M4A AAC (come Music.app). MP3/M4A pronti restano in ready.
            await runImport(
                ready: ready,
                toConvert: convertible,
                convert: !convertible.isEmpty
            )
            releaseImportSecurityRoots()
        } catch is CancellationError {
            releaseImportSecurityRoots()
            if importCancelled {
                setStatus(.success("Import annullato"))
            }
        } catch {
            releaseImportSecurityRoots()
            setStatus(.failure(error.localizedDescription))
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

        do {
            for url in ready {
                try throwIfImportCancelled()
                setStatus(.working("Leggo \(url.lastPathComponent)…"))
                var meta = await AudioMetadataReader.read(url: url)
                try throwIfImportCancelled()
                meta = await MetadataLookup.enrich(meta)
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
                    try throwIfImportCancelled()
                    setStatus(.working("Leggo tag \(index + 1)/\(toConvert.count): \(url.lastPathComponent)"))
                    var sourceMeta = await AudioMetadataReader.read(url: url)
                    sourceMeta = await MetadataLookup.enrich(sourceMeta)
                    sourceMeta.contentHash = try FileHasher.sha256(of: url)

                    if tracks.contains(where: { $0.contentHash == sourceMeta.contentHash })
                        || tracks.contains(where: { $0.identityKey == sourceMeta.identityKey }) {
                        skippedBeforeImport += 1
                        continue
                    }

                    try throwIfImportCancelled()
                    setStatus(.working("Conversione \(index + 1)/\(toConvert.count): \(url.lastPathComponent)"))
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
                    try throwIfImportCancelled()
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
                    if let embedded = await CoverArtService.loadEmbeddedData(from: url) {
                        artData = embedded
                    } else if let remote = await CoverArtService.fetchFromOnline(
                        artist: merged.artist,
                        album: merged.album
                    ) {
                        artData = remote
                    } else {
                        artData = CoverArtService.loadFromDisk(artist: merged.artist, album: merged.album)
                    }
                    if let artData {
                        let artistName = merged.artist.isEmpty ? "Artista sconosciuto" : merged.artist
                        let albumName = merged.album.isEmpty ? "Album sconosciuto" : merged.album
                        artwork.store(artist: artistName, album: albumName, data: artData)
                    }
                    items.append(merged)
                    tempFiles.append(m4a)
                }
            }

            try throwIfImportCancelled()

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
            // Se una playlist utente è selezionata (anche dopo switch di sezione), aggiungi lì.
            let playlistTarget = selectedPlaylistID.flatMap { pid in
                playlists.first(where: { $0.id == pid && !$0.isMaster })?.id
            }
            let result = try await sync.importFiles(
                items,
                to: device,
                existingTracks: tracks,
                existingPlaylists: playlists,
                dbVersion: dbVersion,
                targetPlaylistID: playlistTarget
            ) { progress in
                Task { @MainActor in
                    self.setStatus(.working(progress.message))
                }
            }
            try throwIfImportCancelled()
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
        } catch is CancellationError {
            if importCancelled {
                setStatus(.success("Import annullato"))
            }
        } catch {
            setStatus(.failure(error.localizedDescription))
        }

        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        finishImportAndMaybeAutoSync()
    }

    private func finishImportAndMaybeAutoSync() {
        if pendingAutoSyncCheck {
            pendingAutoSyncCheck = false
            checkAutoSync()
        }
    }

    // MARK: - Auto sync

    func refreshAutoSyncWatching() {
        folderSync.stopWatching()
        releaseSyncFolderAccess()
        guard let settings = appSettings, settings.syncMode == .automatic else { return }
        guard let folder = ensureSyncFolderAccess() else { return }
        folderSync.startWatching(url: folder)
    }

    func checkAutoSync() {
        guard let settings = appSettings, settings.syncMode == .automatic else { return }
        guard connectedDevice != nil, !isLoading else { return }

        if isImportRunning || autoSyncPrompt != nil {
            pendingAutoSyncCheck = true
            return
        }

        guard let folder = ensureSyncFolderAccess() else { return }

        autoSyncTask?.cancel()
        let dismissed = settings.dismissedSyncHashes
        let librarySnapshot = tracks
        autoSyncTask = Task { @MainActor in
            let candidates = await FolderSyncService.findNewCandidates(
                in: folder,
                libraryTracks: librarySnapshot,
                dismissedHashes: dismissed
            )
            guard !Task.isCancelled else { return }
            guard !candidates.isEmpty else { return }

            if self.isImportRunning {
                self.pendingAutoSyncCheck = true
                return
            }
            if self.autoSyncPrompt != nil { return }

            self.autoSyncPrompt = AutoSyncPrompt(candidates: candidates)
            for candidate in candidates {
                self.artwork.request(
                    artist: candidate.displayArtist,
                    album: candidate.displayAlbum,
                    fileURL: candidate.url
                )
            }
        }
    }

    func confirmAutoSync() {
        guard let prompt = autoSyncPrompt else { return }
        let urls = prompt.candidates.map(\.url)
        autoSyncPrompt = nil
        importDroppedURLs(urls)
    }

    func dismissAutoSync() {
        guard let prompt = autoSyncPrompt else { return }
        appSettings?.dismissSyncHashes(prompt.candidates.map(\.contentHash))
        autoSyncPrompt = nil
        if pendingAutoSyncCheck {
            pendingAutoSyncCheck = false
            checkAutoSync()
        }
    }

    private func ensureSyncFolderAccess() -> URL? {
        if let syncFolderScopedURL { return syncFolderScopedURL }
        guard let url = appSettings?.resolvedSyncFolderURL() else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        syncFolderScopedURL = url
        return url
    }

    private func releaseSyncFolderAccess() {
        syncFolderScopedURL?.stopAccessingSecurityScopedResource()
        syncFolderScopedURL = nil
    }

    private func clearAutoSyncUI() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        autoSyncPrompt = nil
        pendingAutoSyncCheck = false
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
                clearAutoSyncUI()
                setStatus(.idle)
            }
        }

        if connectedDevice == nil, let first = devices.first {
            Task { await load(device: first) }
        }
    }
}

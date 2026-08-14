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
    @Published var photos: [DevicePhoto] = []
    @Published var photoSelection = Set<UInt32>()
    @Published var photoAlbumName = L10n.t("photos.default_album")
    @Published var selectedSection: LibrarySection = .songs
    @Published var selectedPlaylistID: UInt64?
    @Published var browseArtist: String?
    @Published var browseAlbum: AlbumRef?
    @Published var browseGenre: String?
    @Published var searchText = ""
    @Published var selection = Set<Track.ID>()
    @Published var syncStatus: SyncStatus = .idle
    /// Frazione 0…1 per operazioni lunghe (es. conversione video); `nil` = solo spinner.
    @Published var workingProgress: Double? = nil
    @Published var isLoading = false
    /// Espulsione volume in corso (mostra feedback UI).
    @Published var isEjecting = false
    /// Conteggio brani in attesa di conferma eliminazione; `nil` = nessun dialogo.
    @Published var pendingTrackDeleteCount: Int? = nil
    /// Manifest letto da .vbk in attesa di conferma ripristino.
    @Published var pendingRestore: PendingVolumeRestore? = nil
    /// Dialogo conversione FLAC (modalità «Chiedi»).
    @Published var pendingFlacConversionAsk: PendingFlacConversionAsk? = nil
    /// Incrementato a ogni sostituzione di `tracks`: forza il refresh della Table macOS (bug SwiftUI).
    @Published private(set) var tracksListEpoch: UInt64 = 0
    @Published var dbVersion: UInt32 = 0x14
    @Published var pendingImports: [ImportCandidate] = []
    @Published var trackEditDraft: TrackEditDraft?
    @Published var lyricsEditDraft: LyricsEditDraft?
    @Published var smartPlaylistDraft: SmartPlaylistEditDraft?
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
    private var backupTask: Task<Void, Never>?
    private var backupCancelFlag: BackupCancelFlag?
    private var autoSyncTask: Task<Void, Never>?
    private var pendingAutoSyncCheck = false
    private var syncFolderScopedURL: URL?
    private var flacAskContinuation: CheckedContinuation<FlacConversionAskDecision, Error>?
    /// Scope UI del foglio «Chiedi» (solo questo / applica a tutti).
    @Published var flacAskApplyToAll = false

    var isImportRunning: Bool {
        if case .working = syncStatus { return true }
        return false
    }

    /// Aggiorna lo stato UI; success/failure spariscono da soli dopo pochi secondi.
    func setStatus(_ status: SyncStatus, progress: Double? = nil) {
        statusDismissTask?.cancel()
        syncStatus = status
        switch status {
        case .working:
            workingProgress = progress
        case .idle, .success, .failure:
            workingProgress = nil
        }
        switch status {
        case .success, .failure:
            let captured = status
            statusDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                if self.syncStatus == captured {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.syncStatus = .idle
                        self.workingProgress = nil
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
        } else if selectedSection == .videos {
            base = tracks.filter(\.isVideo)
        } else if let album = browseAlbum {
            base = tracks.filter {
                !$0.isVideo
                    && $0.displayAlbum == album.name
                    && $0.displayArtist == album.artist
            }
        } else if let genre = browseGenre {
            let inGenre = tracks.filter {
                !$0.isVideo && $0.genreKey?.caseInsensitiveCompare(genre) == .orderedSame
            }
            if let artist = browseArtist {
                base = inGenre.filter { $0.displayArtist == artist }
            } else {
                base = inGenre
            }
        } else if let artist = browseArtist {
            base = tracks.filter { !$0.isVideo && $0.displayArtist == artist }
        } else {
            // Canzoni / drop zone: solo audio.
            base = tracks.filter { !$0.isVideo }
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

    var videoTracks: [Track] { tracks.filter(\.isVideo) }

    /// Playlist utente in sidebar: niente master, niente On-The-Go vuote.
    var sidebarPlaylists: [Playlist] {
        playlists.filter { playlist in
            guard !playlist.isMaster else { return false }
            if playlist.isOnTheGo, playlist.resolvedSongCount(using: tracks) == 0 {
                return false
            }
            return true
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
            source = tracks.filter {
                !$0.isVideo && $0.genreKey?.caseInsensitiveCompare(genre) == .orderedSame
            }
        } else {
            source = tracks.filter { !$0.isVideo }
        }
        return Dictionary(grouping: source, by: \.displayArtist)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var albums: [AlbumRef] {
        albums(forArtist: nil)
    }

    var genres: [GenreRef] {
        Dictionary(grouping: tracks.filter { !$0.isVideo && $0.genreKey != nil }, by: { $0.genreKey! })
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
            source = tracks.filter { !$0.isVideo && $0.displayArtist == artist }
        } else {
            source = tracks.filter { !$0.isVideo }
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
        if section != .photos {
            photoSelection.removeAll()
        }
        selection.removeAll()
        searchText = ""
    }

    /// Deseleziona brani (e foto): la barra canzoni/tempo/MB torna sul totale della lista.
    func clearListSelection() {
        guard !selection.isEmpty || !photoSelection.isEmpty else { return }
        selection.removeAll()
        photoSelection.removeAll()
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
        Task { @MainActor in
            setStatus(.working(L10n.t("status.reconnecting")))
            await Task.yield()
            await detector.scanAndRemountAsync()
            if let device = connectedDevice {
                await load(device: device)
            } else if detector.devices.isEmpty {
                setStatus(.failure(L10n.t("status.ipod_not_found")))
            }
            // Se un dispositivo è comparso, handleDevices avvia il load e aggiorna lo status.
        }
    }

    func eject() {
        playback.stop()
        guard let device = connectedDevice, !isEjecting else { return }
        if device.isSimulated {
            connectedDevice = nil
            replaceTracks([])
            playlists = []
            clearPhotosState()
            selection.removeAll()
            clearBrowse()
            artwork.clear()
            clearAutoSyncUI()
            setStatus(.success(L10n.t("status.demo_disconnected")))
            return
        }

        isEjecting = true
        setStatus(.working(L10n.t("status.ejecting")))
        Task { @MainActor in
            // Due yield: ridisegna rotella + testo prima dell’unmount (può bloccare il main).
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
            do {
                try detector.eject(device)
                connectedDevice = nil
                replaceTracks([])
                playlists = []
                clearPhotosState()
                clearBrowse()
                artwork.clear()
                clearAutoSyncUI()
                selection.removeAll()
                setStatus(.success(L10n.t("status.ejected")))
            } catch {
                setStatus(.failure(error.localizedDescription))
            }
            // Breve pausa così si legge ancora il messaggio prima dello empty state.
            try? await Task.sleep(nanoseconds: 350_000_000)
            isEjecting = false
        }
    }

    /// Rinomina l’iPod collegato (etichetta volume, come in iTunes).
    func renameConnectedDevice(to rawName: String) {
        guard var device = connectedDevice else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setStatus(.failure(L10n.t("status.name_empty")))
            return
        }
        // Music.app mostra il nome della playlist master, non solo l’etichetta volume.
        let masterName = playlists.first(where: \.isMaster)?.name
        guard name != device.name || masterName != name else { return }

        do {
            if name != device.name {
                if device.isSimulated {
                    try SimulatediPod.rename(to: name)
                    device = SimulatediPod.makeDevice(at: SimulatediPod.rootURL)
                } else {
                    try detector.rename(device, to: name)
                    if let updated = detector.devices.first(where: { $0.id == device.id }) {
                        device = updated
                    } else {
                        device = iPodDevice(
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
                connectedDevice = device
            }

            if let idx = playlists.firstIndex(where: \.isMaster), playlists[idx].name != name {
                playlists[idx].name = name
                try sync.savePlaylists(
                    tracks: &tracks,
                    playlists: &playlists,
                    dbVersion: dbVersion,
                    device: device
                )
                refreshLibraryCache(for: device)
            }

            setStatus(.success(L10n.tf("status.renamed", name)))
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
            overrides[track.location] = TrackTagStore.override(from: track)
        }
        do {
            try TrackTagStore.save(overrides, to: device)
            try sync.savePlaylists(
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device,
                reevaluateSmart: true
            )
            refreshLibraryCache(for: device)
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
                fileURL: track.resolvedPath,
                title: track.displayTitle
            )
        }

        guard let device = connectedDevice, device.firmwareMode == .stock else {
            setStatus(.success(
                selected.count == 1
                    ? L10n.t("status.reload_artwork_one")
                    : L10n.tf("status.reload_artwork_many", seen.count)
            ))
            return
        }

        setStatus(.working(L10n.t("status.writing_artwork")))
        let targetIDs = Set(selected.map(\.id))
        let playlistSnapshot = playlists
        let version = dbVersion
        Task {
            do {
                var localTracks = tracks
                let updated = try await sync.pushArtworkToDevice(
                    forTrackIDs: targetIDs,
                    includeAlbumMates: true,
                    preferRemote: true,
                    tracks: &localTracks,
                    playlists: playlistSnapshot,
                    dbVersion: version,
                    device: device
                )
                replaceTracks(localTracks)
                refreshLibraryCache(for: device)
                if updated > 0 {
                    setStatus(.success(
                        updated == 1
                            ? L10n.t("status.artwork_written_one")
                            : L10n.tf("status.artwork_written_many", updated)
                    ))
                } else {
                    setStatus(.failure(L10n.t("status.artwork_not_written")))
                }
            } catch {
                setStatus(.failure(error.localizedDescription))
            }
        }
    }

    /// Scarica i testi (LRCLIB) e li scrive nei **tag del file** + iTunesDB (flag lyrics).
    /// Con `replaceExisting` riusa il testo già in libreria e lo re-applica ai file (riparazione).
    func downloadLyrics(for ids: [UInt32], replaceExisting: Bool = true) {
        guard connectedDevice != nil else { return }
        let selected = ids.compactMap { id in tracks.first(where: { $0.id == id }) }
            .filter { !$0.isVideo }
        let targets = replaceExisting
            ? selected
            : selected.filter { !$0.hasLyrics }
        guard !targets.isEmpty else {
            if !selected.isEmpty, !replaceExisting {
                setStatus(.success(L10n.t("status.lyrics_already_present")))
            }
            return
        }

        setStatus(.working(
            targets.count == 1
                ? L10n.t("status.lyrics_downloading_one")
                : L10n.tf("status.lyrics_downloading_many", targets.count)
        ))

        let snapshot = targets.map {
            (id: $0.id, artist: $0.artist, title: $0.title, album: $0.album,
             durationMs: $0.durationMs, existing: $0.lyrics)
        }
        Task {
            var found = 0
            var missing = 0
            var embedFailed = 0
            var updatedIDs: [UInt32] = []

            for (index, item) in snapshot.enumerated() {
                let text: String?
                if let existing = item.existing?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !existing.isEmpty,
                   replaceExisting {
                    // Ripara: non ri-scaricare, riscrivi tag + flag.
                    text = existing
                } else {
                    if index > 0 { await LyricsLookup.throttle() }
                    text = await LyricsLookup.fetch(
                        artist: item.artist,
                        title: item.title,
                        album: item.album,
                        durationMs: item.durationMs
                    )
                }

                guard let text, !text.isEmpty else {
                    missing += 1
                    continue
                }

                found += 1
                let embedOK = await applyLyricsToTrack(id: item.id, text: text, persist: false)
                if !embedOK { embedFailed += 1 }
                updatedIDs.append(item.id)
            }

            guard !updatedIDs.isEmpty, let device = connectedDevice else {
                setStatus(.failure(
                    snapshot.count == 1
                        ? L10n.t("status.lyrics_not_found_one")
                        : L10n.tf("status.lyrics_not_found_many", missing)
                ))
                return
            }

            do {
                try persistLyricsOverrides(for: updatedIDs, on: device)

                if embedFailed > 0 {
                    setStatus(.failure(L10n.tf("status.lyrics_embed_failed_many", embedFailed)))
                } else if missing == 0 {
                    setStatus(.success(
                        found == 1
                            ? L10n.t("status.lyrics_saved_one")
                            : L10n.tf("status.lyrics_saved_many", found)
                    ))
                } else {
                    setStatus(.success(L10n.tf("status.lyrics_saved_partial", found, missing)))
                }
            } catch {
                setStatus(.failure(error.localizedDescription))
            }
        }
    }

    func beginManualLyricsEdit(id: UInt32) {
        guard let track = tracks.first(where: { $0.id == id }), !track.isVideo else { return }
        selection = [id]
        lyricsEditDraft = LyricsEditDraft(track: track)
    }

    func cancelManualLyricsEdit() {
        lyricsEditDraft = nil
    }

    func saveManualLyrics() {
        guard var draft = lyricsEditDraft, connectedDevice != nil else {
            lyricsEditDraft = nil
            return
        }
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setStatus(.failure(L10n.t("error.lyrics.empty")))
            return
        }
        draft.text = trimmed
        lyricsEditDraft = nil
        setStatus(.working(L10n.t("status.lyrics_saving")))

        Task {
            let embedOK = await applyLyricsToTrack(id: draft.trackID, text: trimmed, persist: true)
            if embedOK {
                setStatus(.success(L10n.t("status.lyrics_saved_one")))
            } else {
                setStatus(.failure(L10n.tf("status.lyrics_embed_failed_many", 1)))
            }
        }
    }

    /// Scrive testo su track + tag file. Con `persist` salva anche override e iTunesDB.
    /// - Returns: `false` se l’embed nel file audio non è riuscito.
    @discardableResult
    private func applyLyricsToTrack(id: UInt32, text: String, persist: Bool) async -> Bool {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return false }
        tracks[idx].setLyrics(text)
        var embedOK = false
        if let fileURL = tracks[idx].resolvedPath {
            do {
                let newSize = try await LyricsTagWriter.embed(lyrics: text, into: fileURL)
                if newSize > 0 { tracks[idx].sizeBytes = newSize }
                embedOK = true
            } catch {
                embedOK = false
            }
        }
        if persist, let device = connectedDevice {
            do {
                try persistLyricsOverrides(for: [id], on: device)
            } catch {
                setStatus(.failure(error.localizedDescription))
                return false
            }
        }
        return embedOK
    }

    private func persistLyricsOverrides(for ids: [UInt32], on device: iPodDevice) throws {
        var overrides = TrackTagStore.load(from: device)
        for id in ids {
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            overrides[track.location] = TrackTagStore.override(from: track)
        }
        try TrackTagStore.save(overrides, to: device)
        try sync.savePlaylists(
            tracks: &tracks,
            playlists: &playlists,
            dbVersion: dbVersion,
            device: device
        )
        refreshLibraryCache(for: device)
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
            overrides[tracks[idx].location] = TrackTagStore.override(from: tracks[idx])
            updated += 1
        }

        guard updated > 0 else { return }

        do {
            try TrackTagStore.save(overrides, to: device)
            try sync.savePlaylists(
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device,
                reevaluateSmart: true
            )
            refreshLibraryCache(for: device)
            setStatus(.success(
                updated == 1
                    ? (stars == 0 ? L10n.t("status.rating_cleared") : L10n.tf("status.rating_set", stars))
                    : L10n.tf("status.rating_updated_many", updated)
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
        var artworkRefresh: [(artist: String, album: String, fileURL: URL?, title: String?)] = []
        var coverTargets = Set<UInt32>()

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

            overrides[tracks[idx].location] = TrackTagStore.override(from: tracks[idx])

            let newArtist = tracks[idx].displayArtist
            let newAlbum = tracks[idx].displayAlbum
            if previousArtist != newArtist || previousAlbum != newAlbum {
                CoverArtService.migrateManualArtwork(
                    fromArtist: previousArtist,
                    fromAlbum: previousAlbum,
                    toArtist: newArtist,
                    toAlbum: newAlbum
                )
                // Non riusare l’embedded del file: può essere dell’album precedente e avvelenare la cache.
                artwork.invalidate(artist: previousArtist, album: previousAlbum)
                if let migrated = CoverArtService.loadManualFromDisk(artist: newArtist, album: newAlbum) {
                    artwork.store(artist: newArtist, album: newAlbum, data: migrated)
                } else {
                    artworkRefresh.append((newArtist, newAlbum, tracks[idx].resolvedPath, tracks[idx].displayTitle))
                }
            }

            if draft.coverDidChange {
                if draft.removeManualCover {
                    CoverArtService.removeManualFromDisk(artist: newArtist, album: newAlbum)
                    CoverArtService.removeFromDisk(artist: newArtist, album: newAlbum)
                    artwork.invalidate(artist: newArtist, album: newAlbum)
                    artworkRefresh.append((newArtist, newAlbum, tracks[idx].resolvedPath, tracks[idx].displayTitle))
                } else if let coverData = draft.coverImageData {
                    CoverArtService.saveManualToDisk(data: coverData, artist: newArtist, album: newAlbum)
                    artwork.store(artist: newArtist, album: newAlbum, data: coverData)
                    coverTargets.insert(tracks[idx].id)
                }
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
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device,
                reevaluateSmart: true
            )
            refreshLibraryCache(for: device)
            let coverData = draft.coverDidChange && !draft.removeManualCover ? draft.coverImageData : nil
            let coverIDs = coverTargets
            trackEditDraft = nil

            var seenKeys = Set<String>()
            for item in artworkRefresh {
                let key = artwork.key(artist: item.artist, album: item.album)
                guard seenKeys.insert(key).inserted else { continue }
                artwork.refresh(
                    artist: item.artist,
                    album: item.album,
                    fileURL: item.fileURL,
                    title: item.title
                )
            }

            if let coverData, !coverIDs.isEmpty, device.firmwareMode == .stock {
                setStatus(.working(L10n.t("status.writing_cover")))
                let playlistSnapshot = playlists
                let version = dbVersion
                Task {
                    do {
                        var localTracks = tracks
                        let n = try await sync.pushArtworkDataToDevice(
                            imageData: coverData,
                            forTrackIDs: coverIDs,
                            tracks: &localTracks,
                            playlists: playlistSnapshot,
                            dbVersion: version,
                            device: device
                        )
                        replaceTracks(localTracks)
                        refreshLibraryCache(for: device)
                        setStatus(.success(
                            n > 0
                                ? (updated == 1
                                    ? L10n.t("status.info_and_cover_updated")
                                    : L10n.t("status.info_updated_cover_written"))
                                : (updated == 1
                                    ? L10n.t("status.info_updated_one")
                                    : L10n.tf("status.info_updated_many", updated))
                        ))
                    } catch {
                        setStatus(.failure(error.localizedDescription))
                    }
                }
            } else {
                setStatus(.success(
                    updated == 1
                        ? L10n.t("status.info_updated_one")
                        : L10n.tf("status.info_updated_many", updated)
                ))
            }
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
                setStatus(.success(reset ? L10n.t("status.demo_reset") : L10n.t("status.demo_active")))
            } catch {
                setStatus(.failure(L10n.tf("status.demo_create_failed", error.localizedDescription)))
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

    /// Riallinea size/durate da disco, toglie cover embedded enormi (es. La recette), riscrive iTunesDB.
    func repairLibraryPlaybackMetadata() {
        guard let device = connectedDevice else {
            setStatus(.failure(L10n.t("status.connect_to_repair")))
            return
        }
        guard !isImportRunning, !isEjecting else { return }

        importCancelled = false
        importTask?.cancel()
        importTask = Task { @MainActor in
            setStatus(.working(L10n.t("status.repairing_library")))
            do {
                var workingTracks = tracks
                let result = try await sync.repairPlaybackMetadata(
                    tracks: &workingTracks,
                    playlists: playlists,
                    dbVersion: dbVersion,
                    device: device
                ) { message in
                    Task { @MainActor in
                        self.setStatus(.working(message))
                    }
                }
                try Task.checkCancellation()
                replaceTracks(workingTracks)
                refreshLibraryCache(for: device)
                var parts: [String] = []
                if result.metadataFixed > 0 {
                    parts.append(L10n.tf("status.metadata_fixed", result.metadataFixed))
                }
                if result.stripped > 0 {
                    parts.append(L10n.tf("status.embedded_covers_stripped", result.stripped))
                }
                setStatus(.success(parts.isEmpty ? L10n.t("status.library_already_aligned") : parts.joined(separator: " · ")))
            } catch is CancellationError {
                setStatus(.success(L10n.t("status.repair_cancelled")))
            } catch {
                setStatus(.failure(error.localizedDescription))
            }
            importTask = nil
        }
    }

    // MARK: - Backup / ripristino totale (.vbk)

    /// Crea un archivio `.vbk` con tutto il contenuto utente del volume.
    func createFullVolumeBackup() {
        guard let device = connectedDevice else {
            setStatus(.failure(iPodBackupError.noDevice.localizedDescription))
            return
        }
        guard !device.isSimulated else {
            setStatus(.failure(iPodBackupError.simulatedDevice.localizedDescription))
            return
        }
        guard !isEjecting else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [iPodVolumeBackup.utType]
        panel.nameFieldStringValue = sanitizedBackupName(for: device)
        panel.message = L10n.t("panel.backup_message")
        panel.prompt = L10n.t("panel.backup_prompt")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        cancelImport(silent: true)
        let cancelFlag = BackupCancelFlag()
        backupCancelFlag = cancelFlag
        backupTask?.cancel()
        let deviceSnapshot = device
        let destURL = url
        backupTask = Task { @MainActor in
            setStatus(.working(L10n.t("status.backup_running")), progress: 0)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try iPodVolumeBackup.createBackup(device: deviceSnapshot, to: destURL) { progress in
                        Task { @MainActor in
                            self.setStatus(.working(progress.message), progress: progress.fraction)
                        }
                    } isCancelled: {
                        Task.isCancelled || cancelFlag.value
                    }
                }.value
                try Task.checkCancellation()
                if cancelFlag.value { throw iPodBackupError.cancelled }
                setStatus(.success(L10n.tf("status.backup_saved", destURL.lastPathComponent)), progress: nil)
                NSWorkspace.shared.activateFileViewerSelecting([destURL])
            } catch is CancellationError {
                setStatus(.success(L10n.t("status.backup_cancelled")))
            } catch let error as iPodBackupError where error == .cancelled {
                setStatus(.success(L10n.t("status.backup_cancelled")))
            } catch {
                setStatus(.failure(error.localizedDescription))
            }
            backupTask = nil
            backupCancelFlag = nil
        }
    }

    /// Sceglie un `.vbk` e chiede conferma prima di ripristinare (cancella il contenuto attuale).
    func chooseFullVolumeRestore() {
        guard let device = connectedDevice else {
            setStatus(.failure(iPodBackupError.noDevice.localizedDescription))
            return
        }
        guard !device.isSimulated else {
            setStatus(.failure(iPodBackupError.simulatedDevice.localizedDescription))
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [iPodVolumeBackup.utType]
        panel.message = L10n.t("panel.restore_message")
        panel.prompt = L10n.t("common.open")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let manifest = try iPodVolumeBackup.readManifest(from: url)
            pendingRestore = PendingVolumeRestore(archiveURL: url, manifest: manifest)
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    func cancelPendingRestore() {
        pendingRestore = nil
    }

    func confirmFullVolumeRestore() {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        guard let device = connectedDevice else {
            setStatus(.failure(iPodBackupError.noDevice.localizedDescription))
            return
        }
        guard !device.isSimulated else {
            setStatus(.failure(iPodBackupError.simulatedDevice.localizedDescription))
            return
        }

        playback.stop()
        cancelImport(silent: true)
        let cancelFlag = BackupCancelFlag()
        backupCancelFlag = cancelFlag
        backupTask?.cancel()
        let archive = pending.archiveURL
        let deviceSnapshot = device
        backupTask = Task { @MainActor in
            setStatus(.working(L10n.t("status.restore_running")), progress: 0)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try iPodVolumeBackup.restoreBackup(from: archive, to: deviceSnapshot) { progress in
                        Task { @MainActor in
                            self.setStatus(.working(progress.message), progress: progress.fraction)
                        }
                    } isCancelled: {
                        Task.isCancelled || cancelFlag.value
                    }
                }.value
                try Task.checkCancellation()
                if cancelFlag.value { throw iPodBackupError.cancelled }
                // Ricarica libreria dal volume ripristinato.
                await load(device: deviceSnapshot)
                setStatus(.success(L10n.tf("status.restore_completed", archive.lastPathComponent)))
            } catch is CancellationError {
                setStatus(.success(L10n.t("status.restore_cancelled")))
            } catch let error as iPodBackupError where error == .cancelled {
                setStatus(.success(L10n.t("status.restore_cancelled")))
            } catch {
                setStatus(.failure(error.localizedDescription))
            }
            backupTask = nil
            backupCancelFlag = nil
        }
    }

    private func sanitizedBackupName(for device: iPodDevice) -> String {
        let raw = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        let base = cleaned.isEmpty ? "iPod" : cleaned
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "\(base)-\(stamp).\(iPodVolumeBackup.fileExtension)"
    }

    func revealSelectedTracksInFinder() {
        let urls = tracks.compactMap { track -> URL? in
            guard selection.contains(track.id) else { return nil }
            return track.resolvedPath
        }.filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !urls.isEmpty else {
            setStatus(.failure(L10n.t("status.file_not_on_device")))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func load(device: iPodDevice) async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Cache hit: fingerprint dei DB sul volume = snapshot Mac → UI istantanea.
            if !device.isSimulated,
               let fingerprint = try? LibraryCacheStore.fingerprint(for: device),
               var cached = LibraryCacheStore.loadIfMatching(device: device, fingerprint: fingerprint) {
                setStatus(.working(L10n.t("status.loading_cache")))
                sync.adoptSession(cached.session)
                let playMerge = sync.absorbPlayCounts(into: &cached.tracks, device: device)
                if device.firmwareMode == .stock, playMerge.changed {
                    // Ricalcola smart solo ora: abbiamo gli ascolti freschi dall’iPod.
                    sync.reevaluateSmartPlaylists(&cached.playlists, tracks: cached.tracks)
                    try sync.persistLibrary(
                        tracks: cached.tracks,
                        playlists: cached.playlists,
                        dbVersion: cached.dbVersion,
                        device: device,
                        reevaluateSmart: false
                    )
                    if playMerge.canRemoveFile {
                        PlayCountsFile.remove(from: device)
                    }
                }
                connectedDevice = device
                artwork.clear()
                LibraryCacheStore.warmArtwork(deviceID: device.id, into: artwork)
                clearBrowse()
                replaceTracks(cached.tracks)
                playlists = pruneOrphanPlaylistEntries(cached.playlists, tracks: cached.tracks)
                dbVersion = cached.dbVersion
                reloadPhotos(from: device)
                if selectedPlaylistID == nil {
                    selectedPlaylistID = sidebarPlaylists.first?.id
                }
                if selectedSection == .photos, connectedDevice?.supportsPhotos != true {
                    selectSection(.songs)
                }
                if selectedSection == .videos, connectedDevice?.supportsVideo != true {
                    selectSection(.songs)
                }
                if playMerge.changed {
                    refreshLibraryCache(for: device)
                } else {
                    LibraryCacheStore.writeFingerprintToDevice(fingerprint, device: device)
                }
                syncMasterPlaylistName(with: device)
                cleanupEmptyOnTheGoPlaylists(on: device)
                setStatus(.success(L10n.tf("status.loaded_cache", cached.tracks.count)))
                checkAutoSync()
                return
            }

            var result = try sync.loadLibrary(for: device)
            // Stelle/ascolti fatti sull’iPod vivono in "Play Counts", non nell’iTunesDB.
            let playMerge = sync.absorbPlayCounts(into: &result.tracks, device: device)
            let before = result.tracks
            // Solo tag/durata mancanti (file senza metadati): non riscandire tutta la libreria.
            // Le durate corrette per i tagli a fine brano si allineano in import (applyTechnicalMetadata).
            await sync.backfillFromFiles(&result.tracks)
            TrackTagStore.apply(TrackTagStore.load(from: device), to: &result.tracks)
            setStatus(.working(L10n.t("status.completing_metadata")))
            await sync.enrichMissingFromOnline(&result.tracks)
            if result.tracks != before {
                // Salva override metadati su disco; le stats le gestiamo sotto se fuse da Play Counts.
                let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
                var overrides = TrackTagStore.load(from: device)
                for track in result.tracks {
                    guard let old = beforeByID[track.id], old != track else { continue }
                    overrides[track.location] = TrackTagStore.override(from: track)
                }
                try? TrackTagStore.save(overrides, to: device)
            }
            // Dopo merge ascolti, riscrivi iTunesDB e allinea le smart playlist.
            if device.firmwareMode == .stock, playMerge.changed {
                setStatus(.working(L10n.t("status.saving_playcounts")))
                sync.reevaluateSmartPlaylists(&result.playlists, tracks: result.tracks)
                try sync.persistLibrary(
                    tracks: result.tracks,
                    playlists: result.playlists,
                    dbVersion: result.dbVersion,
                    device: device,
                    reevaluateSmart: false
                )
                if playMerge.canRemoveFile {
                    PlayCountsFile.remove(from: device)
                }
                var overrides = TrackTagStore.load(from: device)
                for track in result.tracks {
                    overrides[track.location] = TrackTagStore.override(from: track)
                }
                try? TrackTagStore.save(overrides, to: device)
            }
            if device.firmwareMode == .stock {
                setStatus(.working(L10n.t("status.verifying_covers")))
                if try await sync.repairArtworkIfNeeded(
                    tracks: &result.tracks,
                    playlists: result.playlists,
                    dbVersion: result.dbVersion,
                    device: device
                ) {
                    setStatus(.success(L10n.t("status.covers_rewritten")))
                }
                let missing = try await sync.pushMissingArtworkToDevice(
                    tracks: &result.tracks,
                    playlists: result.playlists,
                    dbVersion: result.dbVersion,
                    device: device
                )
                if missing > 0 {
                    setStatus(.success(L10n.tf("status.missing_covers_written", missing)))
                }
            }
            connectedDevice = device
            artwork.clear()
            clearBrowse()
            replaceTracks(result.tracks)
            playlists = pruneOrphanPlaylistEntries(result.playlists, tracks: result.tracks)
            dbVersion = result.dbVersion
            reloadPhotos(from: device)
            // Non auto-persist playlist prune sul device al load.
            prefetchArtwork()
            if selectedPlaylistID == nil {
                selectedPlaylistID = sidebarPlaylists.first?.id
            }
            if selectedSection == .photos, connectedDevice?.supportsPhotos != true {
                selectSection(.songs)
            }
            if selectedSection == .videos, connectedDevice?.supportsVideo != true {
                selectSection(.songs)
            }
            // Dopo prefetch, cattura cover + snapshot per il prossimo collegamento.
            refreshLibraryCache(for: device)
            // Cattura cover di nuovo dopo un breve delay: prefetch è async.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard self.connectedDevice?.id == device.id else { return }
                LibraryCacheStore.captureCovers(deviceID: device.id, tracks: self.tracks, artwork: self.artwork)
            }
            syncMasterPlaylistName(with: device)
            cleanupEmptyOnTheGoPlaylists(on: device)
            setStatus(.success(L10n.tf("status.loaded_tracks", result.tracks.count)))
            checkAutoSync()
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    /// Music.app usa il nome della playlist master; allinealo all’etichetta volume.
    private func syncMasterPlaylistName(with device: iPodDevice) {
        guard device.firmwareMode == .stock,
              let idx = playlists.firstIndex(where: \.isMaster),
              playlists[idx].name != device.name,
              !device.name.isEmpty else { return }
        playlists[idx].name = device.name
        do {
            try sync.savePlaylists(
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device
            )
            refreshLibraryCache(for: device)
        } catch {
            // Best-effort: il rename volume resta comunque valido in Finder.
        }
    }

    /// Rimuove On-The-Go vuote dall’iTunesDB e normalizza il nome a «On-The-Go».
    private func cleanupEmptyOnTheGoPlaylists(on device: iPodDevice) {
        guard device.firmwareMode == .stock else { return }

        let before = playlists
        playlists.removeAll { playlist in
            !playlist.isMaster
                && playlist.isOnTheGo
                && playlist.resolvedSongCount(using: tracks) == 0
        }
        var renamed = false
        for i in playlists.indices where playlists[i].isOnTheGo && playlists[i].name != "On-The-Go" {
            playlists[i].name = "On-The-Go"
            renamed = true
        }

        if let pid = selectedPlaylistID, !playlists.contains(where: { $0.id == pid }) {
            selectedPlaylistID = sidebarPlaylists.first?.id
            if selectedPlaylistID == nil, selectedSection == .playlists {
                selectSection(.songs)
            }
        }

        let removed = before.count != playlists.count
        guard removed || renamed else { return }

        do {
            try sync.savePlaylists(
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device
            )
            refreshLibraryCache(for: device)
            if removed {
                let n = before.count - playlists.count
                setStatus(.success(
                    n == 1
                        ? L10n.t("status.removed_empty_otg_one")
                        : L10n.tf("status.removed_empty_otg_many", n)
                ))
            }
        } catch {
            // Ripristina in memoria se la scrittura fallisce.
            playlists = before
        }
    }

    /// Aggiorna snapshot Mac + fingerprint sul volume (dopo load miss o mutazioni).
    private func refreshLibraryCache(for device: iPodDevice) {
        guard !device.isSimulated else { return }
        do {
            let fingerprint = try LibraryCacheStore.fingerprint(for: device)
            try LibraryCacheStore.save(
                device: device,
                fingerprint: fingerprint,
                tracks: tracks,
                playlists: playlists,
                dbVersion: dbVersion,
                session: sync.currentSession
            )
            LibraryCacheStore.captureCovers(deviceID: device.id, tracks: tracks, artwork: artwork)
        } catch {
            // Cache best-effort: non bloccare l’uso dell’iPod.
        }
    }

    private func clearPhotosState() {
        photos = []
        photoSelection.removeAll()
        photoAlbumName = L10n.t("photos.default_album")
    }

    private func reloadPhotos(from device: iPodDevice) {
        guard device.supportsPhotos else {
            clearPhotosState()
            return
        }
        do {
            guard let store = try PhotoDBStore.open(for: device) else {
                clearPhotosState()
                return
            }
            photoAlbumName = store.albumName
            photos = store.images.map { entry in
                DevicePhoto(
                    id: entry.id,
                    title: L10n.tf("photos.default_title", Int(entry.id)),
                    previewJPEG: store.previewJPEGData(for: entry.id)
                )
            }
            photoSelection = photoSelection.filter { id in photos.contains(where: { $0.id == id }) }
        } catch {
            clearPhotosState()
            setStatus(.failure(error.localizedDescription))
        }
    }

    func choosePhotosToImport() {
        guard let device = connectedDevice, device.supportsPhotos else {
            setStatus(.failure(L10n.t("status.photos_unavailable")))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = L10n.t("common.add")
        panel.message = L10n.t("panel.add_photos_message")
        guard panel.runModal() == .OK else { return }
        importPhotos(urls: panel.urls)
    }

    func importPhotos(urls: [URL]) {
        guard let device = connectedDevice, device.supportsPhotos else {
            setStatus(.failure(L10n.t("status.photos_unavailable")))
            return
        }
        Task { @MainActor in
            do {
                guard let store = try PhotoDBStore.open(for: device) else {
                    setStatus(.failure(L10n.t("status.photos_unsupported")))
                    return
                }
                var added = 0
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
                    setStatus(.working(L10n.tf("status.adding_photo", added + 1)))
                    _ = try store.addPhoto(imageData: data)
                    added += 1
                }
                reloadPhotos(from: device)
                if added > 0 {
                    setStatus(.success(added == 1 ? L10n.t("status.added_photo_one") : L10n.tf("status.added_photo_many", added)))
                } else {
                    setStatus(.failure(L10n.t("status.no_valid_image")))
                }
            } catch {
                setStatus(.failure(error.localizedDescription))
            }
        }
    }

    func deleteSelectedPhotos() {
        guard let device = connectedDevice, device.supportsPhotos, !photoSelection.isEmpty else { return }
        let ids = photoSelection
        do {
            guard let store = try PhotoDBStore.open(for: device) else { return }
            try store.deletePhotos(ids: ids)
            photoSelection.removeAll()
            reloadPhotos(from: device)
            setStatus(.success(ids.count == 1 ? L10n.t("status.deleted_photo_one") : L10n.tf("status.deleted_photo_many", ids.count)))
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

    func importDroppedVideos(_ urls: [URL]) {
        cancelImport(silent: true)
        importCancelled = false
        importTask = Task { @MainActor in
            await prepareVideoImport(urls)
        }
    }

    func chooseVideosToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsOtherFileTypes = true
        panel.prompt = L10n.t("common.import")
        panel.message = L10n.t("panel.import_videos_message")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")

        guard panel.runModal() == .OK else { return }
        importDroppedVideos(panel.urls)
    }

    func chooseFolderToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = L10n.t("common.import")
        panel.message = L10n.t("panel.import_folders_message")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")

        guard panel.runModal() == .OK else { return }
        importDroppedURLs(panel.urls)
    }

    /// Interrompe scan/conversione/import/backup in corso.
    func cancelImport(silent: Bool = false) {
        importCancelled = true
        importTask?.cancel()
        importTask = nil
        backupCancelFlag?.value = true
        backupTask?.cancel()
        backupTask = nil
        failPendingFlacAsk(with: CancellationError())
        releaseImportSecurityRoots()
        workingProgress = nil
        if !silent {
            setStatus(.success(L10n.t("status.operation_cancelled")))
            finishImportAndMaybeAutoSync()
        }
    }

    func answerFlacConversionAsk(format: FlacConversionFormat) {
        let applyAll = flacAskApplyToAll && (pendingFlacConversionAsk?.showsBatchScope == true)
        let decision = FlacConversionAskDecision(format: format, applyToAllRemaining: applyAll)
        pendingFlacConversionAsk = nil
        flacAskApplyToAll = false
        let cont = flacAskContinuation
        flacAskContinuation = nil
        cont?.resume(returning: decision)
    }

    func cancelFlacConversionAsk() {
        guard flacAskContinuation != nil else { return }
        importCancelled = true
        failPendingFlacAsk(with: CancellationError())
    }

    private func failPendingFlacAsk(with error: Error) {
        pendingFlacConversionAsk = nil
        flacAskApplyToAll = false
        let cont = flacAskContinuation
        flacAskContinuation = nil
        cont?.resume(throwing: error)
    }

    private func askFlacConversionFormat(
        fileName: String,
        displayTitle: String,
        index: Int,
        total: Int
    ) async throws -> FlacConversionAskDecision {
        try throwIfImportCancelled()
        flacAskApplyToAll = false
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FlacConversionAskDecision, Error>) in
            flacAskContinuation = cont
            pendingFlacConversionAsk = PendingFlacConversionAsk(
                fileName: fileName,
                displayTitle: displayTitle,
                index: index,
                total: total
            )
        }
    }

    /// Risolve il formato di conversione in base a Impostazioni (Sempre / Chiedi / No).
    private func resolveConversionFormat(
        for url: URL,
        displayTitle: String,
        index: Int,
        total: Int,
        batchOverride: inout FlacConversionFormat?
    ) async throws -> FlacConversionFormat {
        if let batchOverride { return batchOverride }

        let mode = appSettings?.flacConversionAskMode ?? .never
        let preferred = appSettings?.flacConversionFormat ?? .aac256
        let isFlac = url.pathExtension.lowercased() == "flac"

        switch mode {
        case .never, .always:
            return preferred
        case .ask:
            // Il dialogo è pensato per i FLAC; gli altri formati (anche M4A↔MP3) usano la preferenza senza chiedere.
            guard isFlac else { return preferred }
            let decision = try await askFlacConversionFormat(
                fileName: url.lastPathComponent,
                displayTitle: displayTitle,
                index: index,
                total: total
            )
            if decision.applyToAllRemaining {
                batchOverride = decision.format
            }
            return decision.format
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
            setStatus(.failure(L10n.t("status.connect_to_sync")))
            return
        }

        beginImportSecurityAccess(for: urls)
        setStatus(.working(L10n.t("status.searching_audio")))

        do {
            try throwIfImportCancelled()
            let files = AudioFileCollector.collectAudioFiles(from: urls)
            try throwIfImportCancelled()

            let readyNative = files.filter {
                AudioMetadataReader.isSupportedAudio($0) && !AudioConverter.needsConversion($0)
            }
            let convertible = files.filter(AudioConverter.needsConversion)

            // Con «Sempre» / «Chiedi»: anche M4A↔MP3 secondo la preferenza. Con «No»: solo i non nativi → AAC.
            let mode = appSettings?.flacConversionAskMode ?? .never
            let preferred = appSettings?.flacConversionFormat ?? .aac256
            let reformatTarget: FlacConversionFormat? = {
                switch mode {
                case .never: return nil
                case .always, .ask: return preferred
                }
            }()

            var ready: [URL] = []
            var toConvert = convertible
            if let target = reformatTarget {
                for url in readyNative {
                    if AudioConverter.needsReformat(url, to: target) {
                        toConvert.append(url)
                    } else {
                        ready.append(url)
                    }
                }
            } else {
                ready = readyNative
            }

            if files.isEmpty {
                setStatus(.failure(L10n.t("status.no_audio_found")))
                releaseImportSecurityRoots()
                return
            }

            setStatus(.working(L10n.tf("status.found_audio", files.count)))
            try throwIfImportCancelled()

            // FLAC/WAV/… (e M4A↔MP3 se impostato) → formato scelto. Il resto resta ready.
            await runImport(
                ready: ready,
                toConvert: toConvert,
                convert: !toConvert.isEmpty
            )
            releaseImportSecurityRoots()
        } catch is CancellationError {
            releaseImportSecurityRoots()
            if importCancelled {
                setStatus(.success(L10n.t("status.import_cancelled")))
            }
        } catch {
            releaseImportSecurityRoots()
            setStatus(.failure(error.localizedDescription))
        }
    }

    private func prepareVideoImport(_ urls: [URL]) async {
        guard let device = connectedDevice else {
            setStatus(.failure(L10n.t("status.connect_to_sync")))
            return
        }
        guard device.supportsVideo else {
            setStatus(.failure(L10n.t("status.video_unsupported_device")))
            return
        }
        if device.firmwareMode != .stock {
            setStatus(.failure(L10n.t("status.video_stock_only")))
            return
        }

        beginImportSecurityAccess(for: urls)
        setStatus(.working(L10n.t("status.searching_video")))

        do {
            try throwIfImportCancelled()
            let files = VideoFileCollector.collectVideoFiles(from: urls)
            try throwIfImportCancelled()

            if files.isEmpty {
                setStatus(.failure(L10n.t("status.no_video_found")))
                releaseImportSecurityRoots()
                return
            }

            setStatus(.working(L10n.tf("status.found_video", files.count)))
            await runVideoImport(files: files, device: device)
            releaseImportSecurityRoots()
        } catch is CancellationError {
            releaseImportSecurityRoots()
            if importCancelled {
                setStatus(.success(L10n.t("status.import_cancelled")))
            }
        } catch {
            releaseImportSecurityRoots()
            setStatus(.failure(error.localizedDescription))
        }
    }

    private func runVideoImport(files: [URL], device: iPodDevice) async {
        var accessed: [URL] = []
        for url in files {
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            }
        }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        var items: [ImportCandidate] = []
        var tempFiles: [URL] = []
        var skippedBeforeImport = 0
        let profile = iPodVideoEncodeProfile.detect(for: device)

        do {
            for (index, url) in files.enumerated() {
                try throwIfImportCancelled()
                setStatus(.working(L10n.tf("status.reading_file", index + 1, files.count, url.lastPathComponent)))
                var meta = await VideoMetadataReader.read(url: url)
                meta.contentHash = try? FileHasher.sha256(of: url)

                if let hash = meta.contentHash,
                   tracks.contains(where: { $0.contentHash == hash })
                    || tracks.contains(where: { $0.identityKey == meta.identityKey && !$0.title.isEmpty }) {
                    skippedBeforeImport += 1
                    continue
                }

                try throwIfImportCancelled()
                setStatus(.working(L10n.tf("status.converting_file", index + 1, files.count, url.lastPathComponent)), progress: 0)
                let durationSeconds = meta.durationMs > 0 ? Double(meta.durationMs) / 1000.0 : nil
                let m4v = try await VideoConverter.convertForiPod(
                    url,
                    profile: profile,
                    preferredName: meta.title,
                    durationSeconds: durationSeconds
                ) { fraction, message in
                    Task { @MainActor in
                        self.setStatus(.working(message), progress: fraction)
                    }
                }
                try throwIfImportCancelled()
                setStatus(.working(L10n.tf("status.conversion_done", index + 1, files.count)), progress: 1)

                var converted = await VideoMetadataReader.read(url: m4v)
                converted.title = meta.title
                converted.artist = meta.artist
                converted.album = meta.album
                converted.genre = meta.genre.isEmpty ? L10n.t("video.default_genre") : meta.genre
                converted.contentHash = meta.contentHash
                items.append(converted)
                tempFiles.append(m4v)
            }

            try throwIfImportCancelled()

            if items.isEmpty {
                if skippedBeforeImport > 0 {
                    setStatus(.success(L10n.tf("status.no_new_video", skippedBeforeImport)))
                } else {
                    setStatus(.failure(L10n.t("status.no_video_to_transfer")))
                }
                return
            }

            setStatus(.working(L10n.t("status.copying_video")), progress: nil)
            let result = try await sync.importVideoFiles(
                items,
                to: device,
                existingTracks: tracks,
                existingPlaylists: playlists,
                dbVersion: dbVersion
            ) { progress in
                Task { @MainActor in
                    self.setStatus(.working(progress.message), progress: progress.fraction)
                }
            }
            try throwIfImportCancelled()
            replaceTracks(result.tracks)
            playlists = result.playlists
            dbVersion = result.dbVersion

            let skipped = result.skippedDuplicates + skippedBeforeImport
            var parts: [String] = []
            if result.imported > 0 { parts.append(L10n.tf("status.added_videos", result.imported)) }
            if skipped > 0 { parts.append(L10n.tf("status.already_present", skipped)) }
            parts.append(L10n.tf("status.converted_to_m4v", tempFiles.count))
            setStatus(.success(parts.joined(separator: " · ")))
            selectSection(.videos)
            refreshLibraryCache(for: device)
        } catch is CancellationError {
            if importCancelled {
                setStatus(.success(L10n.t("status.import_cancelled")))
            }
        } catch {
            setStatus(.failure(error.localizedDescription))
        }

        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        finishImportAndMaybeAutoSync()
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
            setStatus(.failure(L10n.t("status.connect_to_sync")))
            return
        }

        var items: [ImportCandidate] = []
        var tempFiles: [URL] = []
        var skippedBeforeImport = 0

        do {
            for url in ready {
                try throwIfImportCancelled()
                setStatus(.working(L10n.tf("status.reading_one", url.lastPathComponent)))
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
                var batchFormatOverride: FlacConversionFormat?
                for (index, url) in toConvert.enumerated() {
                    try throwIfImportCancelled()
                    setStatus(.working(L10n.tf("status.reading_tags", index + 1, toConvert.count, url.lastPathComponent)))
                    var sourceMeta = await AudioMetadataReader.read(url: url)
                    sourceMeta = await MetadataLookup.enrich(sourceMeta)
                    sourceMeta.contentHash = try FileHasher.sha256(of: url)

                    if tracks.contains(where: { $0.contentHash == sourceMeta.contentHash })
                        || tracks.contains(where: { $0.identityKey == sourceMeta.identityKey }) {
                        skippedBeforeImport += 1
                        continue
                    }

                    try throwIfImportCancelled()
                    let niceNameParts = [sourceMeta.artist, sourceMeta.title].filter { !$0.isEmpty }
                    let niceName = niceNameParts.isEmpty
                        ? sourceMeta.title
                        : niceNameParts.joined(separator: " - ")
                    let displayTitle = niceName.isEmpty ? url.deletingPathExtension().lastPathComponent : niceName

                    let format = try await resolveConversionFormat(
                        for: url,
                        displayTitle: displayTitle,
                        index: index + 1,
                        total: toConvert.count,
                        batchOverride: &batchFormatOverride
                    )

                    try throwIfImportCancelled()
                    setStatus(.working(L10n.tf("status.converting_file", index + 1, toConvert.count, url.lastPathComponent)))
                    let converted = try await AudioConverter.convertForiPod(
                        url,
                        format: format,
                        preferredName: niceName,
                        artist: sourceMeta.artist,
                        album: sourceMeta.album
                    ) { message in
                        Task { @MainActor in self.setStatus(.working(message)) }
                    }
                    try throwIfImportCancelled()
                    // Durata/bitrate/sample rate dal file convertito reale, non dal FLAC/sorgente.
                    let merged = await AudioMetadataReader.withTechnicalMetadata(
                        AudioMetadataReader.remapped(sourceMeta, to: converted),
                        from: converted
                    )
                    let artData: Data?
                    if let embedded = await CoverArtService.loadEmbeddedData(from: url) {
                        artData = embedded
                    } else if let remote = await CoverArtService.fetchFromOnline(
                        artist: merged.artist,
                        album: merged.album,
                        title: merged.title
                    ) {
                        artData = remote
                    } else {
                        artData = CoverArtService.loadFromDisk(artist: merged.artist, album: merged.album)
                    }
                    if let artData {
                        let artistName = merged.artist.isEmpty ? L10n.t("track.unknown_artist") : merged.artist
                        let albumName = merged.album.isEmpty ? L10n.t("track.unknown_album") : merged.album
                        artwork.store(artist: artistName, album: albumName, data: artData)
                    }
                    items.append(merged)
                    tempFiles.append(converted)
                }
            }

            try throwIfImportCancelled()

            if items.isEmpty {
                removeLibraryDuplicates(silentIfNone: true)
                if skippedBeforeImport > 0 {
                    setStatus(.success(L10n.tf("status.no_new_track", skippedBeforeImport)))
                } else {
                    setStatus(.failure(L10n.t("status.no_file_to_transfer")))
                }
                return
            }

            setStatus(.working(L10n.t("status.preparing_import")))
            // Solo libreria/master: le playlist utente si aggiornano con «Aggiungi a playlist».
            let existingIDs = Set(tracks.map(\.id))
            let result = try await sync.importFiles(
                items,
                to: device,
                existingTracks: tracks,
                existingPlaylists: playlists,
                dbVersion: dbVersion,
                targetPlaylistID: nil
            ) { progress in
                Task { @MainActor in
                    self.setStatus(.working(progress.message))
                }
            }
            try throwIfImportCancelled()
            replaceTracks(result.tracks)
            playlists = result.playlists
            dbVersion = result.dbVersion
            let converted = tempFiles.count
            let skipped = result.skippedDuplicates + skippedBeforeImport
            var parts: [String] = []
            if result.imported > 0 { parts.append(L10n.tf("status.added_tracks", result.imported)) }
            if skipped > 0 { parts.append(L10n.tf("status.skipped_duplicates", skipped)) }
            if converted > 0 { parts.append(L10n.tf("status.converted_tracks", converted)) }
            setStatus(.success(parts.isEmpty ? L10n.t("status.nothing_to_add") : parts.joined(separator: " · ")))
            selectSection(.songs)
            prefetchArtwork()
            refreshLibraryCache(for: device)
            let newAudioIDs = result.tracks
                .filter { !existingIDs.contains($0.id) && !$0.isVideo }
                .map(\.id)
            if !newAudioIDs.isEmpty {
                downloadLyrics(for: newAudioIDs, replaceExisting: false)
            }
        } catch is CancellationError {
            if importCancelled {
                setStatus(.success(L10n.t("status.import_cancelled")))
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
                tracksListEpoch &+= 1
                if let playingID = playback.nowPlaying?.id,
                   !tracks.contains(where: { $0.id == playingID }) {
                    playback.stop()
                }
                refreshLibraryCache(for: device)
                setStatus(.success(L10n.tf("status.removed_duplicates", removed)))
            } else if !silentIfNone {
                setStatus(.success(L10n.t("status.no_duplicates")))
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

    func beginNewSmartPlaylist() {
        guard connectedDevice != nil else { return }
        smartPlaylistDraft = .fresh()
    }

    func beginEditingSmartPlaylist(_ id: UInt64) {
        guard let playlist = playlists.first(where: { $0.id == id && !$0.isMaster }),
              playlist.isSmart,
              let draft = SmartPlaylistEditDraft.editing(playlist) else { return }
        smartPlaylistDraft = draft
    }

    func duplicateSmartPlaylist(_ id: UInt64) {
        guard let device = connectedDevice,
              let source = playlists.first(where: { $0.id == id && !$0.isMaster }),
              source.isSmart,
              var def = SmartPlaylistDefinition.decode(from: source) else { return }
        def.preservedMhod51 = nil
        def.skippedUnsupportedRuleCount = 0
        var copy = sync.createPlaylist(
            name: L10n.tf("smart_playlist.copy_name", source.name),
            playlists: &playlists
        )
        SmartPlaylistDefinition.apply(def, to: &copy, tracks: tracks, rewriteRules: true)
        if let idx = playlists.firstIndex(where: { $0.id == copy.id }) {
            playlists[idx] = copy
        }
        selectedPlaylistID = copy.id
        selectSection(.playlists)
        persistPlaylists(device: device)
        setStatus(.success(L10n.t("status.smart_playlist_saved")))
    }

    func cancelSmartPlaylistEdit() {
        smartPlaylistDraft = nil
    }

    func saveSmartPlaylistEdit() {
        guard var draft = smartPlaylistDraft, let device = connectedDevice else {
            smartPlaylistDraft = nil
            return
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setStatus(.failure(L10n.t("error.smart_playlist.name_empty")))
            return
        }
        // Drop empty string rules
        draft.definition.rules.removeAll {
            $0.field.isString && $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Relative date rules need N ≥ 1
        for i in draft.definition.rules.indices where draft.definition.rules[i].intOp == .inTheLast {
            draft.definition.rules[i].intValue = max(1, draft.definition.rules[i].intValue)
        }
        draft.definition.preservedMhod51 = nil
        draft.definition.skippedUnsupportedRuleCount = 0
        draft.name = name

        if let pid = draft.playlistID,
           let idx = playlists.firstIndex(where: { $0.id == pid && !$0.isMaster }) {
            playlists[idx].name = name
            SmartPlaylistDefinition.apply(draft.definition, to: &playlists[idx], tracks: tracks, rewriteRules: true)
            selectedPlaylistID = pid
        } else {
            var playlist = sync.createPlaylist(name: name, playlists: &playlists)
            SmartPlaylistDefinition.apply(draft.definition, to: &playlist, tracks: tracks, rewriteRules: true)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[idx] = playlist
            }
            selectedPlaylistID = playlist.id
        }
        smartPlaylistDraft = nil
        selectSection(.playlists)
        persistPlaylists(device: device)
        setStatus(.success(L10n.t("status.smart_playlist_saved")))
    }

    /// Ricalcola membership di tutte le smart playlist decodificabili e salva.
    func reevaluateSmartPlaylists(persist: Bool = true) {
        sync.reevaluateSmartPlaylists(&playlists, tracks: tracks)
        guard persist, let device = connectedDevice else { return }
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
            selectedPlaylistID = sidebarPlaylists.first?.id
        }
        persistPlaylists(device: device)
    }

    func addSelectionToPlaylist(_ playlistID: UInt64) {
        guard let device = connectedDevice,
              let idx = playlists.firstIndex(where: { $0.id == playlistID && !$0.isMaster }),
              !playlists[idx].isSmart else { return }
        let ids = selection
        for id in ids where !playlists[idx].trackIDs.contains(id) {
            playlists[idx].trackIDs.append(id)
        }
        persistPlaylists(device: device)
        setStatus(.success(L10n.tf("status.added_to_playlist", ids.count)))
    }

    func removeSelectionFromCurrentPlaylist() {
        guard let device = connectedDevice,
              let pid = selectedPlaylistID,
              let idx = playlists.firstIndex(where: { $0.id == pid && !$0.isMaster }),
              !playlists[idx].isSmart else { return }
        let before = playlists[idx].trackIDs.count
        playlists[idx].trackIDs.removeAll { selection.contains($0) }
        let removed = before - playlists[idx].trackIDs.count
        selection.removeAll()
        persistPlaylists(device: device)
        if removed > 0 {
            setStatus(.success(removed == 1
                ? L10n.t("status.removed_from_playlist_one")
                : L10n.tf("status.removed_from_playlist_many", removed)))
        }
    }

    /// Chiede conferma prima di eliminare i brani selezionati dall’iPod.
    func requestDeleteSelectedTracks() {
        guard connectedDevice != nil, !selection.isEmpty else { return }
        pendingTrackDeleteCount = selection.count
    }

    func cancelPendingTrackDelete() {
        pendingTrackDeleteCount = nil
    }

    func confirmPendingTrackDelete() {
        pendingTrackDeleteCount = nil
        deleteSelectedTracks()
    }

    func deleteSelectedTracks() {
        guard let device = connectedDevice, !selection.isEmpty else { return }
        if let playingID = playback.nowPlaying?.id, selection.contains(playingID) {
            playback.stop()
        }
        let count = selection.count
        do {
            try sync.deleteTracks(
                ids: selection,
                tracks: &tracks,
                playlists: &playlists,
                dbVersion: dbVersion,
                device: device
            )
            tracksListEpoch &+= 1
            selection.removeAll()
            refreshLibraryCache(for: device)
            setStatus(.success(
                count == 1
                    ? L10n.t("status.deleted_song_one")
                    : L10n.tf("status.deleted_song_many", count)
            ))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    private func persistPlaylists(device: iPodDevice) {
        do {
            try sync.savePlaylists(tracks: &tracks, playlists: &playlists, dbVersion: dbVersion, device: device)
            refreshLibraryCache(for: device)
            setStatus(.success(L10n.t("status.playlists_saved")))
        } catch {
            setStatus(.failure(error.localizedDescription))
        }
    }

    /// Sostituisce la libreria in memoria e invalida la Table (non usare `tracks =` diretto per replace).
    private func replaceTracks(_ newTracks: [Track]) {
        tracks = newTracks
        tracksListEpoch &+= 1
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
        // Durante l’espulsione lo smontaggio arriva qui: non azzerare UI/status
        // (altrimenti sparisce “Espulsione in corso…” e resta solo grigio).
        if isEjecting { return }

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
                replaceTracks([])
                playlists = []
                clearPhotosState()
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

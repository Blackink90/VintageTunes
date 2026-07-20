import Foundation

enum SyncError: LocalizedError {
    case noDevice
    case unsupportedFormat(String)
    case copyFailed(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "Nessun iPod collegato."
        case .unsupportedFormat(let e): return "Formato non supportato: \(e)"
        case .copyFailed(let m): return "Copia fallita: \(m)"
        case .database(let m): return "Errore database: \(m)"
        }
    }
}

struct SyncProgress {
    var fraction: Double
    var message: String
}

final class SyncService {
    private let parser = iTunesDBParser()
    private let writer = iTunesDBWriter()
    /// Opaque iTunesDB sections preserved between load and persist (stock only).
    private var stockSession: iTunesDBSessionState?

    func loadLibrary(for device: iPodDevice) throws -> (tracks: [Track], playlists: [Playlist], dbVersion: UInt32) {
        let hashIndex = TrackHashIndex.load(from: device)
        switch device.firmwareMode {
        case .rockbox:
            stockSession = nil
            var result = try loadRockbox(device)
            for i in result.tracks.indices {
                result.tracks[i].contentHash = hashIndex.byLocation[result.tracks[i].location]
            }
            return result
        case .stock:
            if device.hasDatabase {
                var parsed = try parser.parse(at: device.databaseURL, volumeRoot: device.volumeURL)
                stockSession = parsed.session
                for i in parsed.tracks.indices {
                    parsed.tracks[i].contentHash = hashIndex.byLocation[parsed.tracks[i].location]
                }
                if PlayCountsFile.merge(into: &parsed.tracks, device: device) {
                    try? persist(
                        tracks: parsed.tracks,
                        playlists: parsed.playlists,
                        dbVersion: parsed.dbVersion,
                        device: device
                    )
                }
                return (parsed.tracks, parsed.playlists, parsed.dbVersion)
            }
            stockSession = iTunesDBSessionState.emptyNewDatabase
            return ([], [Playlist(id: 1, name: "Libreria", isMaster: true, trackIDs: [])], 0x14)
        }
    }

    func importFiles(
        _ items: [ImportCandidate],
        to device: iPodDevice,
        existingTracks: [Track],
        existingPlaylists: [Playlist],
        dbVersion: UInt32,
        targetPlaylistID: UInt64?,
        progress: @escaping (SyncProgress) -> Void
    ) async throws -> (tracks: [Track], playlists: [Playlist], dbVersion: UInt32, imported: Int, skippedDuplicates: Int) {
        var tracks = existingTracks
        var playlists = existingPlaylists
        var nextID = (tracks.map(\.id).max() ?? 1000) + 1
        var imported = 0
        var skippedDuplicates = 0

        await backfillMissingMetadata(&tracks)

        var hashIndex = TrackHashIndex.load(from: device)
        await ensureHashes(for: &tracks, index: &hashIndex, progress: progress)

        // Pulisci duplicati già presenti (es. import ripetuti prima del fix)
        let removedDupes = try removeDuplicateTracks(
            tracks: &tracks,
            playlists: &playlists,
            dbVersion: dbVersion,
            device: device,
            hashIndex: &hashIndex,
            persistNow: false
        )
        if removedDupes > 0 {
            progress(SyncProgress(fraction: 0, message: "Rimossi \(removedDupes) duplicati esistenti…"))
        }

        if playlists.isEmpty {
            playlists.append(Playlist(id: 1, name: "Libreria", isMaster: true, trackIDs: []))
        }
        if !playlists.contains(where: \.isMaster) {
            playlists.insert(Playlist(id: 1, name: "Libreria", isMaster: true, trackIDs: tracks.map(\.id)), at: 0)
        }

        let audioItems = items.filter { AudioMetadataReader.isSupportedAudio($0.url) }
        guard !audioItems.isEmpty else { throw SyncError.unsupportedFormat("nessun file audio") }

        ensureMusicFolders(on: device)

        let artworkStore = try? ArtworkDBStore.open(for: device)
        var nextDBID = max(tracks.map(\.dbid).filter { $0 > 0 }.max() ?? 0, 1)

        for (index, meta) in audioItems.enumerated() {
            try Task.checkCancellation()
            let step = Double(index) / Double(max(audioItems.count, 1))
            progress(SyncProgress(fraction: step, message: "Controllo \(meta.url.lastPathComponent)…"))

            // Preferisci hash del file ORIGINE (impostato prima della conversione).
            // Hashare il M4A convertito fallisce: ogni afconvert produce byte diversi.
            let fileHash: String
            if let known = meta.contentHash, !known.isEmpty {
                fileHash = known
            } else {
                do {
                    fileHash = try FileHasher.sha256(of: meta.url)
                } catch {
                    throw SyncError.copyFailed("Hash fallito: \(error.localizedDescription)")
                }
            }

            let identity = meta.identityKey
            let isDuplicate =
                hashIndex.contains(hash: fileHash)
                || tracks.contains(where: { $0.contentHash == fileHash })
                || tracks.contains(where: { $0.identityKey == identity && !identity.hasPrefix("|") && !$0.title.isEmpty })

            if isDuplicate {
                skippedDuplicates += 1
                continue
            }

            progress(SyncProgress(fraction: step, message: "Importo \(meta.url.lastPathComponent)…"))

            let trackID = nextID
            nextID += 1
            nextDBID += 1
            let dbid = nextDBID

            let location: String
            switch device.firmwareMode {
            case .stock:
                location = try copyStock(file: meta.url, device: device, trackID: trackID)
            case .rockbox:
                location = try copyRockbox(file: meta.url, meta: meta, device: device)
            }

            hashIndex.set(location: location, hash: fileHash)

            var track = Track(
                id: trackID,
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                genre: meta.genre,
                location: location,
                durationMs: meta.durationMs,
                sizeBytes: meta.sizeBytes,
                trackNumber: meta.trackNumber,
                year: meta.year,
                bitrate: meta.bitrate,
                sampleRate: meta.sampleRate,
                mediaType: 1,
                dbid: dbid,
                hasArtwork: 2,
                artworkCount: 0,
                mhiiLink: 0,
                contentHash: fileHash,
                resolvedPath: resolveLocation(location, device: device)
            )

            if device.firmwareMode == .stock, let store = artworkStore {
                let artURL = track.resolvedPath ?? meta.url
                if let artData = await CoverArtService.resolveArtworkData(
                    artist: track.artist,
                    album: track.album,
                    fileURL: artURL
                ) {
                    do {
                        let mhii = try store.addArtwork(imageData: artData, songDBID: dbid)
                        track.hasArtwork = 1
                        track.artworkCount = 1
                        track.mhiiLink = mhii
                    } catch {
                        // Cover sul device opzionale: l'import audio non fallisce.
                    }
                }
            }

            tracks.append(track)
            imported += 1

            if let masterIndex = playlists.firstIndex(where: \.isMaster) {
                playlists[masterIndex].trackIDs.append(trackID)
            }
            if let playlistID = targetPlaylistID,
               let idx = playlists.firstIndex(where: { $0.id == playlistID && !$0.isMaster }) {
                playlists[idx].trackIDs.append(trackID)
            }
        }

        if let store = artworkStore {
            try? store.save()
        }

        progress(SyncProgress(fraction: 0.95, message: "Aggiorno database…"))
        try persist(tracks: tracks, playlists: playlists, dbVersion: dbVersion, device: device)
        try hashIndex.save(to: device)
        progress(SyncProgress(fraction: 1, message: "Sincronizzazione completata"))
        return (tracks, playlists, dbVersion == 0 ? 0x14 : dbVersion, imported, skippedDuplicates)
    }

    private func ensureHashes(
        for tracks: inout [Track],
        index: inout TrackHashIndex,
        progress: @escaping (SyncProgress) -> Void
    ) async {
        for i in tracks.indices {
            if let existing = tracks[i].contentHash, !existing.isEmpty {
                index.set(location: tracks[i].location, hash: existing)
                continue
            }
            if let known = index.byLocation[tracks[i].location] {
                tracks[i].contentHash = known
                continue
            }
            guard let path = tracks[i].resolvedPath,
                  FileManager.default.fileExists(atPath: path.path) else { continue }
            progress(SyncProgress(fraction: 0, message: "Indicizzo \(tracks[i].displayTitle)…"))
            if let hash = try? FileHasher.sha256(of: path) {
                tracks[i].contentHash = hash
                index.set(location: tracks[i].location, hash: hash)
            }
        }
    }

    func backfillMissingMetadata(_ tracks: inout [Track]) async {
        await backfillFromFiles(&tracks)
        await enrichMissingFromOnline(&tracks)
    }

    /// Completa solo da tag presenti nel file audio.
    func backfillFromFiles(_ tracks: inout [Track]) async {
        for i in tracks.indices {
            let needsDuration = tracks[i].durationMs == 0
            let needsTags = tracks[i].artist.isEmpty
                || tracks[i].album.isEmpty
                || tracks[i].genre.isEmpty
                || tracks[i].year == 0
                || tracks[i].title.isEmpty
            guard needsDuration || needsTags else { continue }
            guard let path = tracks[i].resolvedPath,
                  FileManager.default.fileExists(atPath: path.path) else { continue }

            let meta = await AudioMetadataReader.read(url: path)
            if needsDuration, meta.durationMs > 0 {
                tracks[i].durationMs = meta.durationMs
            }
            if tracks[i].artist.isEmpty, !meta.artist.isEmpty {
                tracks[i].artist = meta.artist
            }
            if tracks[i].album.isEmpty, !meta.album.isEmpty {
                tracks[i].album = meta.album
            }
            if tracks[i].genre.isEmpty, !meta.genre.isEmpty {
                tracks[i].genre = meta.genre
            }
            if tracks[i].year == 0, meta.year > 0 {
                tracks[i].year = meta.year
            }
            if tracks[i].trackNumber == 0, meta.trackNumber > 0 {
                tracks[i].trackNumber = meta.trackNumber
            }
            if tracks[i].title.isEmpty || tracks[i].title == path.deletingPathExtension().lastPathComponent {
                if !meta.title.isEmpty { tracks[i].title = meta.title }
            }
            if tracks[i].sampleRate == 0, meta.sampleRate > 0 {
                tracks[i].sampleRate = meta.sampleRate
            }
            if tracks[i].bitrate == 0, meta.bitrate > 0 {
                tracks[i].bitrate = meta.bitrate
            }
        }
    }

    /// Scarica da iTunes solo i campi ancora vuoti.
    func enrichMissingFromOnline(_ tracks: inout [Track]) async {
        for i in tracks.indices {
            _ = await MetadataLookup.fillMissing(on: &tracks[i])
        }
    }

    func createPlaylist(name: String, playlists: inout [Playlist]) -> Playlist {
        let playlist = Playlist(
            id: UInt64(Date().timeIntervalSince1970 * 1000),
            name: name,
            isMaster: false,
            trackIDs: []
        )
        playlists.append(playlist)
        return playlist
    }

    func savePlaylists(
        tracks: [Track],
        playlists: [Playlist],
        dbVersion: UInt32,
        device: iPodDevice
    ) throws {
        try persist(tracks: tracks, playlists: playlists, dbVersion: dbVersion, device: device)
    }

    /// Rimuove tracce duplicate per hash o per artista+titolo+durata. Tiene la prima occorrenza.
    @discardableResult
    func removeDuplicateTracks(
        tracks: inout [Track],
        playlists: inout [Playlist],
        dbVersion: UInt32,
        device: iPodDevice,
        hashIndex: inout TrackHashIndex,
        persistNow: Bool
    ) throws -> Int {
        var seenHashes = Set<String>()
        var seenIdentities = Set<String>()
        var removeIDs = Set<UInt32>()

        for track in tracks {
            let identity = track.identityKey
            let hasUsefulIdentity = !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if let hash = track.contentHash, !hash.isEmpty {
                if seenHashes.contains(hash) {
                    removeIDs.insert(track.id)
                    continue
                }
                seenHashes.insert(hash)
            }

            if hasUsefulIdentity {
                if seenIdentities.contains(identity) {
                    removeIDs.insert(track.id)
                    continue
                }
                seenIdentities.insert(identity)
            }
        }

        guard !removeIDs.isEmpty else { return 0 }

        let removed = tracks.filter { removeIDs.contains($0.id) }
        tracks.removeAll { removeIDs.contains($0.id) }
        for i in playlists.indices {
            playlists[i].trackIDs.removeAll { removeIDs.contains($0) }
        }
        for track in removed {
            hashIndex.remove(location: track.location)
            if let path = track.resolvedPath ?? resolveLocation(track.location, device: device) {
                try? FileManager.default.removeItem(at: path)
            }
        }

        if persistNow {
            try persist(tracks: tracks, playlists: playlists, dbVersion: dbVersion, device: device)
            try hashIndex.save(to: device)
            var tags = TrackTagStore.load(from: device)
            let removedLocs = Set(removed.map(\.location))
            tags = tags.filter { !removedLocs.contains($0.key) }
            try TrackTagStore.save(tags, to: device)
        }
        return removed.count
    }

    func deleteTracks(
        ids: Set<UInt32>,
        tracks: inout [Track],
        playlists: inout [Playlist],
        dbVersion: UInt32,
        device: iPodDevice
    ) throws {
        let removed = tracks.filter { ids.contains($0.id) }
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices {
            playlists[i].trackIDs.removeAll { ids.contains($0) }
        }

        var hashIndex = TrackHashIndex.load(from: device)
        var tagOverrides = TrackTagStore.load(from: device)
        for track in removed {
            hashIndex.remove(location: track.location)
            tagOverrides.removeValue(forKey: track.location)
            if let path = track.resolvedPath ?? resolveLocation(track.location, device: device) {
                try? FileManager.default.removeItem(at: path)
            }
        }

        try persist(tracks: tracks, playlists: playlists, dbVersion: dbVersion, device: device)
        try hashIndex.save(to: device)
        try TrackTagStore.save(tagOverrides, to: device)
    }

    // MARK: - Persistence

    private func persist(
        tracks: [Track],
        playlists: [Playlist],
        dbVersion: UInt32,
        device: iPodDevice
    ) throws {
        switch device.firmwareMode {
        case .stock:
            let drafts = tracks.map {
                iTunesDBWriter.TrackDraft(
                    id: $0.id,
                    title: $0.title,
                    artist: $0.artist,
                    album: $0.album,
                    genre: $0.genre,
                    location: $0.location.hasPrefix(":") ? $0.location : ":\($0.location.replacingOccurrences(of: "/", with: ":"))",
                    durationMs: $0.durationMs,
                    sizeBytes: $0.sizeBytes,
                    trackNumber: $0.trackNumber,
                    year: $0.year,
                    bitrate: $0.bitrate,
                    sampleRate: $0.sampleRate,
                    mediaType: $0.mediaType == 0 ? 1 : $0.mediaType,
                    filetype: filetypeLabel(for: $0.location),
                    rating: $0.rating,
                    playCount: $0.playCount,
                    lastPlayedMacTime: $0.lastPlayedMacTime,
                    dbid: $0.dbid,
                    hasArtwork: $0.hasArtwork,
                    artworkCount: $0.artworkCount,
                    mhiiLink: $0.mhiiLink,
                    dbBlob: $0.dbBlob
                )
            }
            var plistDrafts = playlists.map {
                iTunesDBWriter.PlaylistDraft(
                    id: $0.id,
                    name: $0.name,
                    isMaster: $0.isMaster,
                    trackIDs: $0.trackIDs,
                    dbBlob: $0.dbBlob
                )
            }
            // Ensure master first
            plistDrafts.sort { a, b in
                if a.isMaster != b.isMaster { return a.isMaster && !b.isMaster }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            try writer.write(
                tracks: drafts,
                playlists: plistDrafts,
                dbVersion: dbVersion == 0 ? 0x14 : dbVersion,
                session: stockSession,
                to: device.databaseURL
            )
        case .rockbox:
            try writeRockboxPlaylists(playlists, tracks: tracks, device: device)
        }
    }

    // MARK: - Stock copy

    private func ensureMusicFolders(on device: iPodDevice) {
        let fm = FileManager.default
        try? fm.createDirectory(at: device.musicURL, withIntermediateDirectories: true)
        for i in 0..<50 {
            let folder = device.musicURL.appendingPathComponent(String(format: "F%02d", i), isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try? fm.createDirectory(at: device.iTunesURL, withIntermediateDirectories: true)
    }

    private func copyStock(file: URL, device: iPodDevice, trackID: UInt32) throws -> String {
        let ext = file.pathExtension.lowercased()
        guard !ext.isEmpty else { throw SyncError.unsupportedFormat(file.lastPathComponent) }

        let folderIndex = Int(trackID % 50)
        let folderName = String(format: "F%02d", folderIndex)
        let filename = String(format: "VT%08X.\(ext)", trackID)
        let dest = device.musicURL
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: file, to: dest)
        } catch {
            throw SyncError.copyFailed(error.localizedDescription)
        }

        return ":iPod_Control:Music:\(folderName):\(filename)"
    }

    private func copyRockbox(file: URL, meta: ImportCandidate, device: iPodDevice) throws -> String {
        let musicRoot = device.volumeURL.appendingPathComponent("Music", isDirectory: true)
        let artist = sanitize(meta.artist.isEmpty ? "Unknown Artist" : meta.artist)
        let album = sanitize(meta.album.isEmpty ? "Unknown Album" : meta.album)
        let title = sanitize(meta.title)
        let folder = musicRoot.appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(album, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let filename = "\(title).\(file.pathExtension.lowercased())"
        let dest = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: file, to: dest)

        // Relative path from volume root for m3u
        return "Music/\(artist)/\(album)/\(filename)"
    }

    // MARK: - Rockbox

    private func loadRockbox(_ device: iPodDevice) throws -> (tracks: [Track], playlists: [Playlist], dbVersion: UInt32) {
        let musicRoot = device.volumeURL.appendingPathComponent("Music", isDirectory: true)
        var tracks: [Track] = []
        var nextID: UInt32 = 1

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: musicRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [Playlist(id: 1, name: "Libreria", isMaster: true, trackIDs: [])], 0)
        }

        for case let fileURL as URL in enumerator {
            guard AudioMetadataReader.isSupportedAudio(fileURL) else { continue }
            let relative = fileURL.path.replacingOccurrences(of: device.volumeURL.path + "/", with: "")
            let name = fileURL.deletingPathExtension().lastPathComponent
            let album = fileURL.deletingLastPathComponent().lastPathComponent
            let artist = fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt32.init) ?? 0

            tracks.append(
                Track(
                    id: nextID,
                    title: name,
                    artist: artist == "Music" ? "" : artist,
                    album: album,
                    genre: "",
                    location: relative,
                    durationMs: 0,
                    sizeBytes: size,
                    trackNumber: 0,
                    year: 0,
                    bitrate: 0,
                    sampleRate: 44100,
                    mediaType: 1,
                    resolvedPath: fileURL
                )
            )
            nextID += 1
        }

        var playlists = [Playlist(id: 1, name: "Libreria", isMaster: true, trackIDs: tracks.map(\.id))]
        playlists.append(contentsOf: loadRockboxM3U(device: device, tracks: tracks))
        return (tracks, playlists, 0)
    }

    private func loadRockboxM3U(device: iPodDevice, tracks: [Track]) -> [Playlist] {
        let playlistsDir = device.volumeURL.appendingPathComponent("Playlists", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: playlistsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var result: [Playlist] = []
        let byPath = Dictionary(uniqueKeysWithValues: tracks.map { ($0.location.lowercased(), $0.id) })

        for file in files where file.pathExtension.lowercased() == "m3u" || file.pathExtension.lowercased() == "m3u8" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var ids: [UInt32] = []
            for line in content.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let key = trimmed.replacingOccurrences(of: "\\", with: "/").lowercased()
                if let id = byPath[key] {
                    ids.append(id)
                }
            }
            result.append(
                Playlist(
                    id: UInt64(abs(file.lastPathComponent.hashValue)),
                    name: file.deletingPathExtension().lastPathComponent,
                    isMaster: false,
                    trackIDs: ids
                )
            )
        }
        return result
    }

    private func writeRockboxPlaylists(_ playlists: [Playlist], tracks: [Track], device: iPodDevice) throws {
        let dir = device.volumeURL.appendingPathComponent("Playlists", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        for playlist in playlists where !playlist.isMaster {
            let url = dir.appendingPathComponent("\(sanitize(playlist.name)).m3u")
            var body = "#EXTM3U\n"
            for id in playlist.trackIDs {
                guard let track = byID[id] else { continue }
                body += "\(track.location)\n"
            }
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func resolveLocation(_ location: String, device: iPodDevice) -> URL? {
        if location.contains(":") {
            let relative = location
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .replacingOccurrences(of: ":", with: "/")
            return device.volumeURL.appendingPathComponent(relative)
        }
        return device.volumeURL.appendingPathComponent(location)
    }

    private func filetypeLabel(for location: String) -> String {
        let ext = (location as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "MPEG audio file"
        case "m4a", "aac": return "AAC audio file"
        case "wav": return "WAV audio file"
        case "aiff", "aif": return "AIFF audio file"
        default: return "Audio file"
        }
    }

    private func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : cleaned
    }
}

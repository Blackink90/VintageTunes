import AppKit
import Foundation

/// Cache locale della libreria (metadati + cover) per riconnessioni rapide.
/// Fingerprint = hash dei DB sul volume: se qualcosa cambia (anche da altro Mac), miss.
enum LibraryCacheStore {
    private static let fpFileName = "VintageTunes-library-fp"
    private static let snapshotName = "snapshot.json"
    private static let coversFolderName = "covers"

    // MARK: - Paths

    private static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("LibraryCache", isDirectory: true)
    }

    static func deviceCacheURL(for deviceID: String) -> URL {
        rootURL.appendingPathComponent(safeDeviceKey(deviceID), isDirectory: true)
    }

    private static func coversURL(for deviceID: String) -> URL {
        deviceCacheURL(for: deviceID).appendingPathComponent(coversFolderName, isDirectory: true)
    }

    private static func safeDeviceKey(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }

    // MARK: - Fingerprint

    /// Codice univoco dello stato libreria sul volume (iTunesDB + ArtworkDB + hash index).
    static func fingerprint(for device: iPodDevice) throws -> String {
        var parts: [String] = []
        parts.append(try fileFingerprint(device.databaseURL))
        let artworkDB = device.controlURL
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("ArtworkDB")
        parts.append(try fileFingerprint(artworkDB))
        let hashes = device.iTunesURL.appendingPathComponent("VintageTunes-hashes.json")
        parts.append(try fileFingerprint(hashes))
        return parts.joined(separator: "|")
    }

    private static func fileFingerprint(_ url: URL) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return "missing" }
        // iTunesDB è piccolo: hash completo. ArtworkDB può essere grande: size+mtime.
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > 0, size <= 2_000_000 {
            return try FileHasher.sha256(of: url)
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(String(format: "%.3f", mtime))"
    }

    static func fingerprintFileURL(on device: iPodDevice) -> URL {
        device.iTunesURL.appendingPathComponent(fpFileName)
    }

    static func writeFingerprintToDevice(_ fingerprint: String, device: iPodDevice) {
        guard !device.isSimulated else { return }
        try? FileManager.default.createDirectory(at: device.iTunesURL, withIntermediateDirectories: true)
        try? fingerprint.write(to: fingerprintFileURL(on: device), atomically: true, encoding: .utf8)
    }

    // MARK: - Load / save snapshot

    struct Snapshot {
        var fingerprint: String
        var dbVersion: UInt32
        var tracks: [Track]
        var playlists: [Playlist]
        var session: iTunesDBSessionState?
    }

    static func loadIfMatching(device: iPodDevice, fingerprint: String) -> Snapshot? {
        guard !device.isSimulated else { return nil }
        let dir = deviceCacheURL(for: device.id)
        let url = dir.appendingPathComponent(snapshotName)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.fingerprint == fingerprint else {
            return nil
        }
        let tracks = payload.tracks.map { $0.makeTrack(volumeRoot: device.volumeURL) }
        let playlists = payload.playlists.map { $0.makePlaylist() }
        return Snapshot(
            fingerprint: payload.fingerprint,
            dbVersion: payload.dbVersion,
            tracks: tracks,
            playlists: playlists,
            session: payload.session?.makeSession()
        )
    }

    static func save(
        device: iPodDevice,
        fingerprint: String,
        tracks: [Track],
        playlists: [Playlist],
        dbVersion: UInt32,
        session: iTunesDBSessionState?
    ) throws {
        guard !device.isSimulated else { return }
        let dir = deviceCacheURL(for: device.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = CachePayload(
            fingerprint: fingerprint,
            dbVersion: dbVersion,
            tracks: tracks.map(CachedTrack.init(track:)),
            playlists: playlists.map(CachedPlaylist.init(playlist:)),
            session: session.map(CachedSession.init(session:))
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: dir.appendingPathComponent(snapshotName), options: .atomic)
        writeFingerprintToDevice(fingerprint, device: device)
    }

    static func remove(for deviceID: String) {
        try? FileManager.default.removeItem(at: deviceCacheURL(for: deviceID))
    }

    // MARK: - Covers

    /// Copia le cover già in memoria / su disco Artwork nella cache del device.
    @MainActor
    static func captureCovers(deviceID: String, tracks: [Track], artwork: ArtworkCache) {
        let dir = coversURL(for: deviceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var seen = Set<String>()
        for track in tracks {
            let album = track.displayAlbum
            guard album != "Album sconosciuto" else { continue }
            let key = CoverArtService.cacheKey(artist: track.displayArtist, album: album)
            guard seen.insert(key).inserted else { continue }

            let dest = dir.appendingPathComponent("\(key).jpg")
            if let image = artwork.image(artist: track.displayArtist, album: album),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? jpeg.write(to: dest, options: .atomic)
                continue
            }
            if let data = CoverArtService.loadManualFromDisk(artist: track.displayArtist, album: album)
                ?? CoverArtService.loadFromDisk(artist: track.displayArtist, album: album) {
                try? data.write(to: dest, options: .atomic)
            }
        }

        // Rimuovi cover orfane (album non più in libreria).
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let keep = Set(seen.map { "\($0).jpg" })
            for url in files where url.pathExtension.lowercased() == "jpg" {
                if !keep.contains(url.lastPathComponent) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Carica le cover dalla cache device nella cache UI in memoria (senza toccare l’iPod).
    @MainActor
    static func warmArtwork(deviceID: String, into artwork: ArtworkCache) {
        let dir = coversURL(for: deviceID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in files where url.pathExtension.lowercased() == "jpg" {
            guard let data = try? Data(contentsOf: url) else { continue }
            // La chiave è nel nome file; ArtworkCache.store richiede artist/album —
            // usiamo una API dedicata che inserisce per chiave.
            artwork.storeCachedJPEG(data: data, cacheFileName: url.deletingPathExtension().lastPathComponent)
        }
    }
}

// MARK: - Codable payload

private struct CachePayload: Codable {
    var fingerprint: String
    var dbVersion: UInt32
    var tracks: [CachedTrack]
    var playlists: [CachedPlaylist]
    var session: CachedSession?
}

private struct CachedTrack: Codable {
    var id: UInt32
    var title: String
    var artist: String
    var album: String
    var genre: String
    var location: String
    var durationMs: UInt32
    var sizeBytes: UInt32
    var trackNumber: UInt32
    var year: UInt32
    var bitrate: UInt32
    var sampleRate: UInt32
    var mediaType: UInt32
    var rating: UInt8
    var playCount: UInt32
    var lastPlayedMacTime: UInt32
    var dbid: UInt64
    var hasArtwork: UInt8
    var artworkCount: UInt16
    var mhiiLink: UInt32
    var contentHash: String?
    var lyrics: String?
    var blobHeader: Data?
    var blobExtra: [Data]

    init(track: Track) {
        id = track.id
        title = track.title
        artist = track.artist
        album = track.album
        genre = track.genre
        location = track.location
        durationMs = track.durationMs
        sizeBytes = track.sizeBytes
        trackNumber = track.trackNumber
        year = track.year
        bitrate = track.bitrate
        sampleRate = track.sampleRate
        mediaType = track.mediaType
        rating = track.rating
        playCount = track.playCount
        lastPlayedMacTime = track.lastPlayedMacTime
        dbid = track.dbid
        hasArtwork = track.hasArtwork
        artworkCount = track.artworkCount
        mhiiLink = track.mhiiLink
        contentHash = track.contentHash
        lyrics = track.lyrics
        blobHeader = track.dbBlob?.header
        blobExtra = track.dbBlob?.extraMhods ?? []
    }

    func makeTrack(volumeRoot: URL) -> Track {
        var resolved: URL?
        if !location.isEmpty {
            let relative = location
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .replacingOccurrences(of: ":", with: "/")
            resolved = volumeRoot.appendingPathComponent(relative)
        }
        let blob: TrackDBBlob? = blobHeader.map { TrackDBBlob(header: $0, extraMhods: blobExtra) }
        return Track(
            id: id,
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            location: location,
            durationMs: durationMs,
            sizeBytes: sizeBytes,
            trackNumber: trackNumber,
            year: year,
            bitrate: bitrate,
            sampleRate: sampleRate,
            mediaType: mediaType,
            rating: rating,
            playCount: playCount,
            lastPlayedMacTime: lastPlayedMacTime,
            dbid: dbid,
            hasArtwork: hasArtwork,
            artworkCount: artworkCount,
            mhiiLink: mhiiLink,
            contentHash: contentHash,
            lyrics: lyrics,
            dbBlob: blob,
            resolvedPath: resolved
        )
    }
}

private struct CachedPlaylist: Codable {
    var id: UInt64
    var name: String
    var isMaster: Bool
    var trackIDs: [UInt32]
    var blobHeader: Data?
    var blobExtra: [Data]

    init(playlist: Playlist) {
        id = playlist.id
        name = playlist.name
        isMaster = playlist.isMaster
        trackIDs = playlist.trackIDs
        blobHeader = playlist.dbBlob?.header
        blobExtra = playlist.dbBlob?.extraMhods ?? []
    }

    func makePlaylist() -> Playlist {
        let blob: PlaylistDBBlob? = blobHeader.map { PlaylistDBBlob(header: $0, extraMhods: blobExtra) }
        return Playlist(id: id, name: name, isMaster: isMaster, trackIDs: trackIDs, dbBlob: blob)
    }
}

private struct CachedSession: Codable {
    var mhbdHeader: Data
    var slots: [CachedSlot]

    init(session: iTunesDBSessionState) {
        mhbdHeader = session.mhbdHeader
        slots = session.mhsdLayout.map(CachedSlot.init(slot:))
    }

    func makeSession() -> iTunesDBSessionState {
        iTunesDBSessionState(mhbdHeader: mhbdHeader, mhsdLayout: slots.map(\.slot))
    }
}

private struct CachedSlot: Codable {
    enum Kind: String, Codable {
        case tracks, playlists, podcastPlaylists, specialPlaylists, preserved
    }

    var kind: Kind
    var preserved: Data?

    init(slot: iTunesDBMHSDSlot) {
        switch slot {
        case .tracks:
            kind = .tracks
            preserved = nil
        case .playlists:
            kind = .playlists
            preserved = nil
        case .podcastPlaylists:
            kind = .podcastPlaylists
            preserved = nil
        case .specialPlaylists:
            kind = .specialPlaylists
            preserved = nil
        case .preserved(let data):
            kind = .preserved
            preserved = data
        }
    }

    var slot: iTunesDBMHSDSlot {
        switch kind {
        case .tracks: return .tracks
        case .playlists: return .playlists
        case .podcastPlaylists: return .podcastPlaylists
        case .specialPlaylists: return .specialPlaylists
        case .preserved: return .preserved(preserved ?? Data())
        }
    }
}

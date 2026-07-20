import Foundation

/// Override metadati per location (utile su Rockbox e come backup oltre iTunesDB).
struct TrackTagOverride: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: UInt32
    var year: UInt32
    var rating: UInt8 = 0
    var playCount: UInt32 = 0
    var lastPlayedMacTime: UInt32 = 0
}

enum TrackTagStore {
    private static let fileName = "VintageTunes-tags.json"

    static func url(on device: iPodDevice) -> URL {
        device.iTunesURL.appendingPathComponent(fileName)
    }

    static func load(from device: iPodDevice) -> [String: TrackTagOverride] {
        let url = url(on: device)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: TrackTagOverride].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func save(_ map: [String: TrackTagOverride], to device: iPodDevice) throws {
        try FileManager.default.createDirectory(at: device.iTunesURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(map)
        try data.write(to: url(on: device), options: .atomic)
    }

    static func apply(_ map: [String: TrackTagOverride], to tracks: inout [Track]) {
        guard !map.isEmpty else { return }
        for i in tracks.indices {
            guard let patch = map[tracks[i].location] else { continue }
            tracks[i].title = patch.title
            tracks[i].artist = patch.artist
            tracks[i].album = patch.album
            tracks[i].genre = patch.genre
            tracks[i].trackNumber = patch.trackNumber
            tracks[i].year = patch.year
            tracks[i].rating = patch.rating
            tracks[i].playCount = patch.playCount
            tracks[i].lastPlayedMacTime = patch.lastPlayedMacTime
        }
    }
}

struct TrackEditDraft: Equatable {
    var trackIDs: [UInt32]
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: String
    var year: String
    /// Stelle 0…5 (0 = nessuna).
    var starRating: Int
    /// true se in multi-edit le stelle erano diverse (non mostrare un valore unico).
    var mixedRating: Bool

    /// true se i brani selezionati avevano valori diversi (campo lasciato vuoto in UI).
    var mixedArtist: Bool
    var mixedAlbum: Bool
    var mixedGenre: Bool
    var mixedTrackNumber: Bool
    var mixedYear: Bool

    var isMulti: Bool { trackIDs.count > 1 }

    init(tracks: [Track]) {
        precondition(!tracks.isEmpty)
        trackIDs = tracks.map(\.id)

        if tracks.count == 1 {
            let track = tracks[0]
            title = track.title
            artist = track.artist
            album = track.album
            genre = track.genre
            trackNumber = track.trackNumber == 0 ? "" : "\(track.trackNumber)"
            year = track.year == 0 ? "" : "\(track.year)"
            starRating = track.starRating
            mixedRating = false
            mixedArtist = false
            mixedAlbum = false
            mixedGenre = false
            mixedTrackNumber = false
            mixedYear = false
            return
        }

        title = ""
        let artists = tracks.map(\.artist)
        let albums = tracks.map(\.album)
        let genres = tracks.map(\.genre)
        let numbers = tracks.map(\.trackNumber)
        let years = tracks.map(\.year)
        let ratings = tracks.map(\.starRating)

        mixedArtist = !Self.valuesAreEqual(artists)
        mixedAlbum = !Self.valuesAreEqual(albums)
        mixedGenre = !Self.valuesAreEqual(genres)
        mixedTrackNumber = !Self.valuesAreEqual(numbers)
        mixedYear = !Self.valuesAreEqual(years)
        mixedRating = !Self.valuesAreEqual(ratings)

        artist = mixedArtist ? "" : (artists.first ?? "")
        album = mixedAlbum ? "" : (albums.first ?? "")
        genre = mixedGenre ? "" : (genres.first ?? "")
        trackNumber = mixedTrackNumber ? "" : (numbers.first == 0 ? "" : "\(numbers.first!)")
        year = mixedYear ? "" : (years.first == 0 ? "" : "\(years.first!)")
        starRating = mixedRating ? 0 : (ratings.first ?? 0)
    }

    private static func valuesAreEqual<T: Equatable>(_ values: [T]) -> Bool {
        guard let first = values.first else { return true }
        return values.allSatisfy { $0 == first }
    }
}

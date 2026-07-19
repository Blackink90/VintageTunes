import Foundation

/// Override metadati per location (utile su Rockbox e come backup oltre iTunesDB).
struct TrackTagOverride: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: UInt32
    var year: UInt32
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
        }
    }
}

struct TrackEditDraft: Equatable {
    var trackID: UInt32
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: String
    var year: String

    init(track: Track) {
        trackID = track.id
        title = track.title
        artist = track.artist
        album = track.album
        genre = track.genre
        trackNumber = track.trackNumber == 0 ? "" : "\(track.trackNumber)"
        year = track.year == 0 ? "" : "\(track.year)"
    }
}

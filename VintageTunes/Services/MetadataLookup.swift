import Foundation

struct OnlineTrackMeta: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: UInt32?
    var trackNumber: UInt32?
}

/// Completa metadati mancanti via iTunes Search API (senza API key).
enum MetadataLookup {
    private static var memoryCache: [String: OnlineTrackMeta] = [:]
    private static let cacheQueue = DispatchQueue(label: "vintagetunes.metadataLookup")

    static func enrich(_ candidate: ImportCandidate) async -> ImportCandidate {
        var result = candidate
        let needsGenre = result.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsYear = result.year == 0
        let needsAlbum = result.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsArtist = result.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsTrack = result.trackNumber == 0
        guard needsGenre || needsYear || needsAlbum || needsArtist || needsTitle || needsTrack else {
            return result
        }

        guard let online = await lookup(
            artist: result.artist,
            title: result.title,
            album: result.album
        ) else { return result }

        if needsTitle, let title = online.title, !title.isEmpty { result.title = title }
        if needsArtist, let artist = online.artist, !artist.isEmpty { result.artist = artist }
        if needsAlbum, let album = online.album, !album.isEmpty { result.album = album }
        if needsGenre, let genre = online.genre, !genre.isEmpty { result.genre = genre }
        if needsYear, let year = online.year, year > 0 { result.year = year }
        if needsTrack, let tn = online.trackNumber, tn > 0 { result.trackNumber = tn }
        return result
    }

    static func fillMissing(on track: inout Track) async -> Bool {
        let needsGenre = track.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsYear = track.year == 0
        let needsAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsTrack = track.trackNumber == 0
        guard needsGenre || needsYear || needsAlbum || needsArtist || needsTitle || needsTrack else {
            return false
        }

        guard let online = await lookup(
            artist: track.artist,
            title: track.title,
            album: track.album
        ) else { return false }

        var changed = false
        if needsTitle, let title = online.title, !title.isEmpty {
            track.title = title
            changed = true
        }
        if needsArtist, let artist = online.artist, !artist.isEmpty {
            track.artist = artist
            changed = true
        }
        if needsAlbum, let album = online.album, !album.isEmpty {
            track.album = album
            changed = true
        }
        if needsGenre, let genre = online.genre, !genre.isEmpty {
            track.genre = genre
            changed = true
        }
        if needsYear, let year = online.year, year > 0 {
            track.year = year
            changed = true
        }
        if needsTrack, let tn = online.trackNumber, tn > 0 {
            track.trackNumber = tn
            changed = true
        }
        return changed
    }

    static func lookup(artist: String, title: String, album: String) async -> OnlineTrackMeta? {
        let primaryArtist = CoverArtService.primaryArtistName(artist)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primaryArtist.isEmpty || !cleanTitle.isEmpty || !cleanAlbum.isEmpty else { return nil }

        let cacheKey = "\(primaryArtist.lowercased())|\(cleanTitle.lowercased())|\(cleanAlbum.lowercased())"
        if let cached = cached(cacheKey) { return cached }

        var terms: [String] = []
        if !primaryArtist.isEmpty, !cleanTitle.isEmpty {
            terms.append("\(primaryArtist) \(cleanTitle)")
        }
        if !primaryArtist.isEmpty, !cleanAlbum.isEmpty {
            terms.append("\(primaryArtist) \(cleanAlbum)")
        }
        if !cleanTitle.isEmpty, !cleanAlbum.isEmpty {
            terms.append("\(cleanTitle) \(cleanAlbum)")
        }
        if !cleanTitle.isEmpty {
            terms.append(cleanTitle)
        }

        var seen = Set<String>()
        terms = terms.filter { seen.insert($0.lowercased()).inserted }

        for term in terms {
            if let meta = await searchSong(term: term, artist: primaryArtist, title: cleanTitle, album: cleanAlbum) {
                store(cacheKey, meta)
                return meta
            }
        }

        // Fallback album-level (genere/anno anche senza match esatto sul brano)
        if !primaryArtist.isEmpty || !cleanAlbum.isEmpty {
            let albumTerm = [primaryArtist, cleanAlbum].filter { !$0.isEmpty }.joined(separator: " ")
            if let meta = await searchAlbum(term: albumTerm, artist: primaryArtist, album: cleanAlbum) {
                store(cacheKey, meta)
                return meta
            }
        }

        return nil
    }

    private static func searchSong(
        term: String,
        artist: String,
        title: String,
        album: String
    ) async -> OnlineTrackMeta? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  !results.isEmpty else { return nil }

            guard let row = bestSongMatch(results: results, artist: artist, title: title, album: album) else {
                return nil
            }
            return meta(from: row)
        } catch {
            return nil
        }
    }

    private static func searchAlbum(term: String, artist: String, album: String) async -> OnlineTrackMeta? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  !results.isEmpty else { return nil }

            let albumL = album.lowercased()
            let artistL = artist.lowercased()
            let row = results.first { r in
                let ra = (r["artistName"] as? String ?? "").lowercased()
                let rl = (r["collectionName"] as? String ?? "").lowercased()
                let albumOK = albumL.isEmpty || rl.contains(albumL) || albumL.contains(rl)
                let artistOK = artistL.isEmpty || ra.contains(artistL) || artistL.contains(ra)
                return albumOK && artistOK
            } ?? results.first

            guard let row else { return nil }
            return OnlineTrackMeta(
                title: nil,
                artist: row["artistName"] as? String,
                album: row["collectionName"] as? String,
                genre: row["primaryGenreName"] as? String,
                year: year(from: row["releaseDate"] as? String),
                trackNumber: nil
            )
        } catch {
            return nil
        }
    }

    private static func bestSongMatch(
        results: [[String: Any]],
        artist: String,
        title: String,
        album: String
    ) -> [String: Any]? {
        let artistL = artist.lowercased()
        let titleL = title.lowercased()
        let albumL = album.lowercased()

        if let exact = results.first(where: { row in
            let ra = (row["artistName"] as? String ?? "").lowercased()
            let rt = (row["trackName"] as? String ?? "").lowercased()
            let rl = (row["collectionName"] as? String ?? "").lowercased()
            let titleOK = titleL.isEmpty || rt == titleL || rt.contains(titleL) || titleL.contains(rt)
            let artistOK = artistL.isEmpty || ra.contains(artistL) || artistL.contains(ra)
            let albumOK = albumL.isEmpty || rl.contains(albumL) || albumL.contains(rl)
            return titleOK && artistOK && (albumL.isEmpty || albumOK)
        }) {
            return exact
        }

        if let loose = results.first(where: { row in
            let ra = (row["artistName"] as? String ?? "").lowercased()
            let rt = (row["trackName"] as? String ?? "").lowercased()
            let titleOK = titleL.isEmpty || rt.contains(titleL) || titleL.contains(rt)
            let artistOK = artistL.isEmpty || ra.contains(artistL) || artistL.contains(ra)
            return titleOK && artistOK
        }) {
            return loose
        }

        return results.first
    }

    private static func meta(from row: [String: Any]) -> OnlineTrackMeta {
        OnlineTrackMeta(
            title: row["trackName"] as? String,
            artist: row["artistName"] as? String,
            album: row["collectionName"] as? String,
            genre: row["primaryGenreName"] as? String,
            year: year(from: row["releaseDate"] as? String),
            trackNumber: (row["trackNumber"] as? NSNumber)?.uint32Value
                ?? UInt32(row["trackNumber"] as? Int ?? 0)
        )
    }

    private static func year(from releaseDate: String?) -> UInt32? {
        guard let releaseDate, releaseDate.count >= 4,
              let y = UInt32(releaseDate.prefix(4)), y > 0 else { return nil }
        return y
    }

    private static func cached(_ key: String) -> OnlineTrackMeta? {
        cacheQueue.sync { memoryCache[key] }
    }

    private static func store(_ key: String, _ value: OnlineTrackMeta) {
        cacheQueue.sync { memoryCache[key] = value }
    }
}

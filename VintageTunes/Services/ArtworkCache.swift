import AppKit
import AVFoundation
import Foundation

/// Cache cover art: file → disco → iTunes Search API.
@MainActor
final class ArtworkCache: ObservableObject {
    static let shared = ArtworkCache()

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight = Set<String>()
    private var failed = Set<String>()

    func key(artist: String, album: String) -> String {
        CoverArtService.cacheKey(artist: artist, album: album)
    }

    func image(artist: String, album: String) -> NSImage? {
        images[key(artist: artist, album: album)]
    }

    func request(artist: String, album: String, fileURL: URL?, title: String? = nil) {
        let k = key(artist: artist, album: album)
        guard images[k] == nil, !failed.contains(k), !inFlight.contains(k) else { return }
        inFlight.insert(k)
        Task {
            let data = await CoverArtService.resolveArtworkData(
                artist: artist,
                album: album,
                fileURL: fileURL,
                title: title
            )
            inFlight.remove(k)
            if let data, let image = NSImage(data: data) {
                images[k] = image.resized(maxPixel: 256)
            } else {
                failed.insert(k)
            }
        }
    }

    /// Ricarica dalla rete (ignora embedded/cache disco), utile se la cover è stata avvelenata.
    /// Non sostituisce una copertina caricata manualmente.
    func refresh(artist: String, album: String, fileURL: URL? = nil, title: String? = nil) {
        let k = key(artist: artist, album: album)
        images.removeValue(forKey: k)
        failed.remove(k)
        inFlight.remove(k)

        if let manual = CoverArtService.loadManualFromDisk(artist: artist, album: album),
           let image = NSImage(data: manual) {
            images[k] = image.resized(maxPixel: 256)
            return
        }

        CoverArtService.removeFromDisk(artist: artist, album: album)
        inFlight.insert(k)
        Task {
            let data = await CoverArtService.resolveArtworkData(
                artist: artist,
                album: album,
                fileURL: fileURL,
                policy: .preferRemote,
                title: title
            )
            inFlight.remove(k)
            if let data, let image = NSImage(data: data) {
                images[k] = image.resized(maxPixel: 256)
                // Non scrivere cover dentro file sull’iPod: spezza l’ottimizzazione M4A.
                if let fileURL, !fileURL.path.contains("/iPod_Control/") {
                    try? await CoverArtService.embedArtwork(into: fileURL, imageData: data)
                }
            } else {
                failed.insert(k)
            }
        }
    }

    /// Forza il salvataggio in cache UI di una cover già nota (es. dopo import).
    func store(artist: String, album: String, data: Data) {
        let k = key(artist: artist, album: album)
        failed.remove(k)
        if let image = NSImage(data: data) {
            images[k] = image.resized(maxPixel: 256)
            CoverArtService.saveToDisk(data: data, artist: artist, album: album)
        }
    }

    func invalidate(artist: String, album: String) {
        let k = key(artist: artist, album: album)
        images.removeValue(forKey: k)
        failed.remove(k)
        inFlight.remove(k)
        CoverArtService.removeFromDisk(artist: artist, album: album)
        CoverArtService.removeManualFromDisk(artist: artist, album: album)
    }

    func clear() {
        images.removeAll()
        inFlight.removeAll()
        failed.removeAll()
    }
}

enum ArtworkResolvePolicy {
    /// Embedded → iTunes → cache disco (default sicuro: la rete batte una cache eventualmente avvelenata).
    case standard
    /// Solo iTunes (poi salva su disco); per “Ricarica copertina”.
    case preferRemote
}

/// Risolve cover: **manuale** → file audio → iTunes Search API → cache disco.
enum CoverArtService {
    private static var diskCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    private static var manualCacheURL: URL {
        diskCacheURL.appendingPathComponent("Manual", isDirectory: true)
    }

    static func cacheKey(artist: String, album: String) -> String {
        let a = primaryArtistName(artist).lowercased()
        let al = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let raw = "\(a)|||\(al)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
    }

    /// JPEG/PNG data della cover, se trovata.
    static func resolveArtworkData(
        artist: String,
        album: String,
        fileURL: URL?,
        policy: ArtworkResolvePolicy = .standard,
        title: String? = nil
    ) async -> Data? {
        // Copertina scelta dall’utente: priorità assoluta su embedded/rete/cache.
        if let manual = loadManualFromDisk(artist: artist, album: album) {
            return manual
        }

        switch policy {
        case .preferRemote:
            if let remote = await fetchFromOnline(artist: artist, album: album, title: title) {
                saveToDisk(data: remote, artist: artist, album: album)
                return remote
            }
            if let fileURL, let embedded = await loadEmbeddedData(from: fileURL) {
                saveToDisk(data: embedded, artist: artist, album: album)
                return embedded
            }
            return loadFromDisk(artist: artist, album: album)

        case .standard:
            if let fileURL, let embedded = await loadEmbeddedData(from: fileURL) {
                saveToDisk(data: embedded, artist: artist, album: album)
                return embedded
            }
            // Rete prima della cache disco: evita di ripropinare cover sbagliate dopo un delete/reimport.
            if let remote = await fetchFromOnline(artist: artist, album: album, title: title) {
                saveToDisk(data: remote, artist: artist, album: album)
                return remote
            }
            return loadFromDisk(artist: artist, album: album)
        }
    }

    /// iTunes Search (album + eventuale brano), poi MusicBrainz / Cover Art Archive.
    static func fetchFromOnline(artist: String, album: String, title: String? = nil) async -> Data? {
        if let data = await fetchFromiTunes(artist: artist, album: album, title: title) {
            return data
        }
        return await fetchFromMusicBrainz(artist: artist, album: album)
    }

    static func loadEmbeddedData(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        do {
            let meta = try await asset.load(.commonMetadata)
            for item in meta where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    return data
                }
            }
        } catch {}
        return nil
    }

    static func loadFromDisk(artist: String, album: String) -> Data? {
        let url = diskCacheURL.appendingPathComponent("\(cacheKey(artist: artist, album: album)).jpg")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        return data
    }

    static func saveToDisk(data: Data, artist: String, album: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        let url = diskCacheURL.appendingPathComponent("\(cacheKey(artist: artist, album: album)).jpg")
        let jpeg = jpegData(from: data) ?? data
        try? jpeg.write(to: url, options: .atomic)
    }

    static func removeFromDisk(artist: String, album: String) {
        let url = diskCacheURL.appendingPathComponent("\(cacheKey(artist: artist, album: album)).jpg")
        try? FileManager.default.removeItem(at: url)
    }

    static func hasManualArtwork(artist: String, album: String) -> Bool {
        loadManualFromDisk(artist: artist, album: album) != nil
    }

    static func loadManualFromDisk(artist: String, album: String) -> Data? {
        let url = manualCacheURL.appendingPathComponent("\(cacheKey(artist: artist, album: album)).jpg")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        return data
    }

    /// Salva una copertina scelta dall’utente (priorità su ogni altra fonte).
    static func saveManualToDisk(data: Data, artist: String, album: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: manualCacheURL, withIntermediateDirectories: true)
        let jpeg = jpegData(from: data) ?? data
        let url = manualCacheURL.appendingPathComponent("\(cacheKey(artist: artist, album: album)).jpg")
        try? jpeg.write(to: url, options: .atomic)
        // Allinea anche la cache “auto” così le viste che leggono solo quella restano coerenti.
        saveToDisk(data: jpeg, artist: artist, album: album)
    }

    static func removeManualFromDisk(artist: String, album: String) {
        let url = manualCacheURL.appendingPathComponent("\(cacheKey(artist: artist, album: album)).jpg")
        try? FileManager.default.removeItem(at: url)
    }

    /// Sposta l’override manuale quando cambiano artista/album.
    static func migrateManualArtwork(fromArtist: String, fromAlbum: String, toArtist: String, toAlbum: String) {
        guard let data = loadManualFromDisk(artist: fromArtist, album: fromAlbum) else { return }
        saveManualToDisk(data: data, artist: toArtist, album: toAlbum)
        if cacheKey(artist: fromArtist, album: fromAlbum) != cacheKey(artist: toArtist, album: toAlbum) {
            removeManualFromDisk(artist: fromArtist, album: fromAlbum)
        }
    }

    /// Cerca su iTunes Search API (nessuna API key).
    /// Prova artista+album (anche senza suffissi Edition), poi artista+titolo brano.
    static func fetchFromiTunes(artist: String, album: String, title: String? = nil) async -> Data? {
        let cleanedArtist = primaryArtistName(artist)
        let cleanedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let strippedAlbum = stripEditionAnnotations(cleanedAlbum)
        guard !cleanedArtist.isEmpty || !cleanedAlbum.isEmpty else { return nil }

        var terms: [String] = []
        if !cleanedArtist.isEmpty, !cleanedAlbum.isEmpty {
            terms.append("\(cleanedArtist) \(cleanedAlbum)")
            if strippedAlbum != cleanedAlbum, !strippedAlbum.isEmpty {
                terms.append("\(cleanedArtist) \(strippedAlbum)")
            }
        } else if !cleanedAlbum.isEmpty {
            terms.append(cleanedAlbum)
            if strippedAlbum != cleanedAlbum, !strippedAlbum.isEmpty {
                terms.append(strippedAlbum)
            }
        } else if !cleanedArtist.isEmpty {
            terms.append(cleanedArtist)
        }

        var seen = Set<String>()
        terms = terms.filter { seen.insert($0.lowercased()).inserted }

        for term in terms {
            if let data = await searchiTunesAlbum(term: term, artist: cleanedArtist, album: cleanedAlbum) {
                return data
            }
        }

        // Fallback: molti album “Anniversary/Bonus/Special Edition” non escono come entity=album,
        // ma la ricerca per brano restituisce subito artworkUrl (es. Slipknot, Maroon 5, Linkin Park).
        let cleanedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedArtist.isEmpty, !cleanedTitle.isEmpty {
            if let data = await searchiTunesSong(artist: cleanedArtist, title: cleanedTitle, album: cleanedAlbum) {
                return data
            }
        }
        return nil
    }

    // MARK: - MusicBrainz / Cover Art Archive

    private static let musicBrainzUserAgent =
        "VintageTunes/1.0 (https://github.com/Blackink90/VintageTunes)"

    /// Fallback per album assenti da iTunes (es. edizioni regionali come 4ever Hilary Duff).
    static func fetchFromMusicBrainz(artist: String, album: String) async -> Data? {
        let cleanedArtist = primaryArtistName(artist)
        let cleanedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAlbum.isEmpty else { return nil }

        let albumVariants = Array(Set([cleanedAlbum, stripEditionAnnotations(cleanedAlbum)].filter { !$0.isEmpty }))
        for albumVariant in albumVariants {
            let mbids = await searchMusicBrainzReleaseIDs(artist: cleanedArtist, album: albumVariant)
            for mbid in mbids {
                if let data = await downloadCoverArtArchive(releaseID: mbid) {
                    return data
                }
            }

            let groupIDs = await searchMusicBrainzReleaseGroupIDs(artist: cleanedArtist, album: albumVariant)
            for gid in groupIDs {
                if let data = await downloadCoverArtArchive(releaseGroupID: gid) {
                    return data
                }
            }
        }
        return nil
    }

    private static func searchMusicBrainzReleaseIDs(artist: String, album: String) async -> [String] {
        var queries: [String] = []
        if !artist.isEmpty {
            queries.append("release:\"\(escapeLucene(album))\" AND artist:\"\(escapeLucene(artist))\"")
        }
        queries.append("release:\"\(escapeLucene(album))\"")
        queries.append("\(escapeLucene(album)) \(escapeLucene(artist))".trimmingCharacters(in: .whitespaces))

        var ids: [String] = []
        var seen = Set<String>()
        for query in queries {
            let rows = await musicBrainzSearch(path: "release", query: query)
            let ranked = rows.compactMap { row -> (score: Int, id: String)? in
                guard let id = row["id"] as? String else { return nil }
                let title = row["title"] as? String ?? ""
                let credit = artistCreditName(from: row)
                guard albumsMatch(
                    query: normalizeAlbumTitle(album),
                    candidate: normalizeAlbumTitle(title),
                    artist: normalizeAlbumTitle(artist)
                ) else { return nil }
                if !artist.isEmpty {
                    let a = normalizeAlbumTitle(credit)
                    let q = normalizeAlbumTitle(artist)
                    guard a == q || a.contains(q) || q.contains(a) else { return nil }
                }
                // Preferisci CD ufficiali senza disambiguazione DVD.
                let disamb = (row["disambiguation"] as? String ?? "").lowercased()
                var score = (row["score"] as? Int) ?? 0
                if (row["status"] as? String)?.lowercased() == "official" { score += 20 }
                if disamb.contains("dvd") || disamb.contains("video") { score -= 40 }
                return (score, id)
            }
            .sorted { $0.score > $1.score }

            for item in ranked where seen.insert(item.id).inserted {
                ids.append(item.id)
            }
            if !ids.isEmpty { break }
        }
        return ids
    }

    private static func searchMusicBrainzReleaseGroupIDs(artist: String, album: String) async -> [String] {
        var queries: [String] = []
        if !artist.isEmpty {
            queries.append("releasegroup:\"\(escapeLucene(album))\" AND artist:\"\(escapeLucene(artist))\"")
        }
        queries.append("releasegroup:\"\(escapeLucene(album))\"")

        var ids: [String] = []
        var seen = Set<String>()
        for query in queries {
            let rows = await musicBrainzSearch(path: "release-group", query: query)
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                let title = row["title"] as? String ?? ""
                guard albumsMatch(
                    query: normalizeAlbumTitle(album),
                    candidate: normalizeAlbumTitle(title),
                    artist: normalizeAlbumTitle(artist)
                ) else { continue }
                if !artist.isEmpty {
                    let credit = artistCreditName(from: row)
                    let a = normalizeAlbumTitle(credit)
                    let q = normalizeAlbumTitle(artist)
                    guard a == q || a.contains(q) || q.contains(a) else { continue }
                }
                if seen.insert(id).inserted {
                    ids.append(id)
                }
            }
            if !ids.isEmpty { break }
        }
        return ids
    }

    private static func musicBrainzSearch(path: String, query: String) async -> [[String: Any]] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components?.url else { return [] }
        do {
            let (data, response) = try await musicBrainzData(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            let key = path == "release-group" ? "release-groups" : "releases"
            return json[key] as? [[String: Any]] ?? []
        } catch {
            return []
        }
    }

    private static func downloadCoverArtArchive(releaseID: String) async -> Data? {
        await downloadCoverArt(urlString: "https://coverartarchive.org/release/\(releaseID)/front-500")
    }

    private static func downloadCoverArtArchive(releaseGroupID: String) async -> Data? {
        await downloadCoverArt(urlString: "https://coverartarchive.org/release-group/\(releaseGroupID)/front-500")
    }

    private static func downloadCoverArt(urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue(musicBrainzUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/*,*/*", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 25
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func musicBrainzData(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue(musicBrainzUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return try await URLSession.shared.data(for: request)
    }

    private static func artistCreditName(from row: [String: Any]) -> String {
        guard let credits = row["artist-credit"] as? [[String: Any]] else { return "" }
        return credits.map { part in
            let name = part["name"] as? String ?? ""
            let join = part["joinphrase"] as? String ?? ""
            return name + join
        }.joined()
    }

    private static func escapeLucene(_ value: String) -> String {
        let specials = CharacterSet(charactersIn: #"+\-&|!(){}[]^"~*?:\"#)
        return value.unicodeScalars.map { specials.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    /// Prende il primo artista (prima di virgole / feat. / &).
    static func primaryArtistName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [",", ";", " feat.", " feat ", " ft.", " ft ", " featuring ", " vs.", " vs ", " x ", " / ", " & "]
        let lower = value.lowercased()
        var cut = value.count
        for sep in separators {
            if let range = lower.range(of: sep) {
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                cut = min(cut, idx)
            }
        }
        if cut < value.count {
            let end = value.index(value.startIndex, offsetBy: cut)
            value = String(value[..<end])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizza titoli album per confronto/ricerca (4ever → forever, ecc.).
    private static func normalizeAlbumTitle(_ raw: String) -> String {
        var s = raw.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        let replacements: [(String, String)] = [
            ("4ever", "forever"),
            ("4 ever", "forever"),
            ("2gether", "together"),
            ("&", " and ")
        ]
        for (from, to) in replacements {
            s = s.replacingOccurrences(of: from, with: to)
        }
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rimuove suffissi tipo (Bonus Edition), [Deluxe Edition], ": 10th Anniversary Edition".
    private static func stripEditionAnnotations(_ raw: String) -> String {
        var s = raw
        let patterns = [
            #"\s*[\(\[][^\)\]]*\b(edition|version|deluxe|bonus|expanded|remaster(?:ed)?|anniversary|explicit|clean|special)\b[^\)\]]*[\)\]]"#,
            #"\s*[:\-–—]\s*\d{1,2}(st|nd|rd|th)?\s+anniversary(\s+edition)?\s*$"#,
            #"\s+[\(\[]\s*(deluxe|bonus|expanded|special)\s*[\)\]]\s*$"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "-:")))
    }

    /// Confronto “morbido”: ignora punteggiatura e annotazioni edizione.
    private static func canonicalizeForMatch(_ raw: String) -> String {
        var s = normalizeAlbumTitle(stripEditionAnnotations(raw))
        // Togli parentesi residue tipo "vol. 3: (the subliminal verses)"
        if let regex = try? NSRegularExpression(pattern: #"[\(\)\[\]\{\}:.,;/\\'"]+"#, options: []) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
        }
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchiTunesAlbum(term: String, artist: String, album: String) async -> Data? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "12")
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

            guard let pick = bestMatch(results: results, artist: artist, album: album, titleKey: "collectionName") else {
                return nil
            }
            return await downloadiTunesArtwork(from: pick)
        } catch {
            return nil
        }
    }

    private static func searchiTunesSong(artist: String, title: String, album: String) async -> Data? {
        let term = "\(artist) \(title)"
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "12")
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

            let artistN = canonicalizeForMatch(artist)
            let titleN = canonicalizeForMatch(title)
            let albumN = canonicalizeForMatch(album)

            let ranked = results.compactMap { row -> (score: Int, row: [String: Any])? in
                let ra = canonicalizeForMatch(row["artistName"] as? String ?? "")
                let rt = canonicalizeForMatch(row["trackName"] as? String ?? "")
                let rl = canonicalizeForMatch(row["collectionName"] as? String ?? "")
                let artistOK = artistN.isEmpty
                    || ra == artistN
                    || ra.contains(artistN)
                    || artistN.contains(ra)
                guard artistOK else { return nil }
                let titleOK = rt == titleN || rt.contains(titleN) || titleN.contains(rt)
                guard titleOK else { return nil }
                var score = 0
                if rt == titleN { score += 50 }
                if !albumN.isEmpty, albumsMatch(query: albumN, candidate: rl, artist: artistN) {
                    score += 40
                }
                if ra == artistN { score += 10 }
                return (score, row)
            }
            .sorted { $0.score > $1.score }

            guard let pick = ranked.first?.row else { return nil }
            return await downloadiTunesArtwork(from: pick)
        } catch {
            return nil
        }
    }

    private static func downloadiTunesArtwork(from pick: [String: Any]) async -> Data? {
        guard var artURLString = pick["artworkUrl100"] as? String else { return nil }
        artURLString = artURLString
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "100x100", with: "600x600")
        guard let artURL = URL(string: artURLString) else { return nil }
        do {
            let (imageData, imageResponse) = try await URLSession.shared.data(from: artURL)
            guard let imageHTTP = imageResponse as? HTTPURLResponse,
                  (200...299).contains(imageHTTP.statusCode),
                  !imageData.isEmpty else { return nil }
            return imageData
        } catch {
            return nil
        }
    }

    private static func bestMatch(results: [[String: Any]], artist: String, album: String, titleKey: String) -> [String: Any]? {
        let artistN = canonicalizeForMatch(artist)
        let albumN = canonicalizeForMatch(album)

        // Match album + artista (obbligatorio se entrambi noti). Niente fallback “primo risultato”.
        if let hit = results.first(where: { row in
            let ra = canonicalizeForMatch(row["artistName"] as? String ?? "")
            let rl = canonicalizeForMatch(row[titleKey] as? String ?? "")
            let albumOK = albumsMatch(query: albumN, candidate: rl, artist: artistN)
            let artistOK = artistN.isEmpty
                || ra == artistN
                || ra.contains(artistN)
                || artistN.contains(ra)
            return albumOK && artistOK
        }) {
            return hit
        }

        // Solo se manca l’artista: match esatto sul titolo album
        if artistN.isEmpty, !albumN.isEmpty,
           let hit = results.first(where: { row in
               canonicalizeForMatch(row[titleKey] as? String ?? "") == albumN
           }) {
            return hit
        }

        return nil
    }

    /// Confronto album rigoroso: evita che "4ever Hilary Duff" matchi l’album omonimo "Hilary Duff".
    private static func albumsMatch(query: String, candidate: String, artist: String) -> Bool {
        let q = canonicalizeForMatch(query)
        let c = canonicalizeForMatch(candidate)
        let a = canonicalizeForMatch(artist)
        if q.isEmpty { return true }
        if c.isEmpty { return false }
        if q == c { return true }

        // Il candidato contiene l’intero titolo cercato (es. "Album (Deluxe)" ⊃ "Album").
        if c.contains(q) { return true }

        // Il titolo cercato contiene il candidato solo se non è “solo il nome artista”
        // e copre una parte sostanziale del titolo.
        if q.contains(c) {
            if !a.isEmpty {
                if c == a { return false }
                if a.contains(c), c.count <= a.count {
                    return false
                }
            }
            let ratio = Double(c.count) / Double(max(q.count, 1))
            if ratio >= 0.55 { return true }
        }

        // Token distintivi (escludi parole dell’artista): devono comparire nel candidato.
        let artistTokens = Set(a.split(separator: " ").map(String.init).filter { $0.count > 1 })
        let queryTokens = q.split(separator: " ").map(String.init)
            .filter { $0.count > 1 && !artistTokens.contains($0) }
        if !queryTokens.isEmpty {
            let candidateTokens = Set(c.split(separator: " ").map(String.init))
            let hits = queryTokens.filter { candidateTokens.contains($0) || c.contains($0) }
            if hits.count == queryTokens.count { return true }
            // Maggioranza dei token (edizioni con Vol./Pt. leggermente diversi).
            if queryTokens.count >= 3, hits.count * 2 >= queryTokens.count * 2 - 1 {
                return true
            }
        }

        return false
    }

    private static func jpegData(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return data }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return data }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Incorpora cover in un M4A già convertito.
    static func embedArtwork(into m4aURL: URL, imageData: Data) async throws {
        let jpeg = jpegData(from: imageData) ?? imageData
        let asset = AVURLAsset(url: m4aURL)

        let artworkItem = AVMutableMetadataItem()
        artworkItem.identifier = .commonIdentifierArtwork
        artworkItem.dataType = kCMMetadataBaseDataType_JPEG as String
        artworkItem.value = jpeg as NSData

        var metadata: [AVMetadataItem] = [artworkItem]
        if let existing = try? await asset.load(.metadata) {
            for item in existing where item.commonKey != .commonKeyArtwork {
                metadata.append(item)
            }
        }

        let fm = FileManager.default
        let temp = m4aURL.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString)-art.m4a")
        try? fm.removeItem(at: temp)

        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.outputURL = temp
            session.outputFileType = .m4a
            session.metadata = metadata

            let box = ExportSessionBox(session)
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                box.session.exportAsynchronously {
                    continuation.resume(returning: box.session.status == .completed)
                }
            }

            if ok, fm.fileExists(atPath: temp.path) {
                try fm.removeItem(at: m4aURL)
                try fm.moveItem(at: temp, to: m4aURL)
                return
            }
            try? fm.removeItem(at: temp)
        }

        throw CoverArtError.embedFailed("export session non riuscita")
    }
}

/// Wrapper per chiudere AVAssetExportSession in closure @Sendable senza warning.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

enum CoverArtError: LocalizedError {
    case embedFailed(String)

    var errorDescription: String? {
        switch self {
        case .embedFailed(let m): return "Embed cover fallito: \(m)"
        }
    }
}

private extension NSImage {
    func resized(maxPixel: CGFloat) -> NSImage {
        let longest = max(size.width, size.height)
        guard longest > maxPixel, longest > 0 else { return self }
        let scale = maxPixel / longest
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

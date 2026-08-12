import Foundation

/// Scarica testi da LRCLIB (nessuna API key). Preferisce `plainLyrics` per iPod stock (MHOD 27).
enum LyricsLookup {
    private static let baseURL = URL(string: "https://lrclib.net")!
    private static let userAgent = "VintageTunes/1.8 (https://github.com/Blackink90/VintageTunes)"
    private static let interRequestDelayNs: UInt64 = 350_000_000

    static func fetch(
        artist: String,
        title: String,
        album: String,
        durationMs: UInt32
    ) async -> String? {
        let primaryArtist = CoverArtService.primaryArtistName(artist)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primaryArtist.isEmpty, !cleanTitle.isEmpty else { return nil }

        if let text = await getExact(
            artist: primaryArtist,
            title: cleanTitle,
            album: cleanAlbum,
            durationMs: durationMs
        ) {
            return text
        }

        return await searchBest(
            artist: primaryArtist,
            title: cleanTitle,
            album: cleanAlbum,
            durationMs: durationMs
        )
    }

    /// Pausa tra richieste batch (rate limit LRCLIB).
    static func throttle() async {
        try? await Task.sleep(nanoseconds: interRequestDelayNs)
    }

    // MARK: - Exact get

    private static func getExact(
        artist: String,
        title: String,
        album: String,
        durationMs: UInt32
    ) async -> String? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        let seconds = Int((Double(durationMs) / 1000.0).rounded())
        if seconds >= 1, seconds <= 3600 {
            items.append(URLQueryItem(name: "duration", value: "\(seconds)"))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        return await plainLyrics(from: url)
    }

    // MARK: - Search fallback

    private static func searchBest(
        artist: String,
        title: String,
        album: String,
        durationMs: UInt32
    ) async -> String? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if !album.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else {
                return nil
            }

            let targetSec = Double(durationMs) / 1000.0
            let ranked = rows.sorted { a, b in
                let da = abs((a["duration"] as? Double ?? 0) - targetSec)
                let db = abs((b["duration"] as? Double ?? 0) - targetSec)
                return da < db
            }

            for row in ranked.prefix(5) {
                if let text = extractPlainLyrics(from: row) {
                    return text
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - HTTP

    private static func plainLyrics(from url: URL) async -> String? {
        do {
            let (data, response) = try await data(from: url)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 { return nil }
                if http.statusCode == 429 {
                    let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 2
                    try? await Task.sleep(nanoseconds: UInt64(retry * 1_000_000_000))
                    return await plainLyrics(from: url)
                }
                guard http.statusCode == 200 else { return nil }
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return extractPlainLyrics(from: json)
        } catch {
            return nil
        }
    }

    private static func extractPlainLyrics(from json: [String: Any]) -> String? {
        if json["instrumental"] as? Bool == true { return nil }
        if let plain = json["plainLyrics"] as? String {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // Fallback: togli i timestamp dai synced lyrics.
        if let synced = json["syncedLyrics"] as? String {
            let lines = synced.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                var s = String(line)
                if let close = s.firstIndex(of: "]") {
                    s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func data(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return try await URLSession.shared.data(for: request)
    }
}

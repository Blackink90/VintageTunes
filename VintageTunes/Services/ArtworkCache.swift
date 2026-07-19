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

    func request(artist: String, album: String, fileURL: URL?) {
        let k = key(artist: artist, album: album)
        guard images[k] == nil, !failed.contains(k), !inFlight.contains(k) else { return }
        inFlight.insert(k)
        Task {
            let data = await CoverArtService.resolveArtworkData(
                artist: artist,
                album: album,
                fileURL: fileURL
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
    func refresh(artist: String, album: String, fileURL: URL? = nil) {
        let k = key(artist: artist, album: album)
        images.removeValue(forKey: k)
        failed.remove(k)
        inFlight.remove(k)
        CoverArtService.removeFromDisk(artist: artist, album: album)
        inFlight.insert(k)
        Task {
            let data = await CoverArtService.resolveArtworkData(
                artist: artist,
                album: album,
                fileURL: fileURL,
                policy: .preferRemote
            )
            inFlight.remove(k)
            if let data, let image = NSImage(data: data) {
                images[k] = image.resized(maxPixel: 256)
                if let fileURL {
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

/// Risolve cover: file audio → iTunes Search API → cache disco.
enum CoverArtService {
    private static var diskCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
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
        policy: ArtworkResolvePolicy = .standard
    ) async -> Data? {
        switch policy {
        case .preferRemote:
            if let remote = await fetchFromiTunes(artist: artist, album: album) {
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
            if let remote = await fetchFromiTunes(artist: artist, album: album) {
                saveToDisk(data: remote, artist: artist, album: album)
                return remote
            }
            return loadFromDisk(artist: artist, album: album)
        }
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

    /// Cerca su iTunes Search API (nessuna API key).
    /// Prova artista+album; solo album solo se manca l’artista.
    static func fetchFromiTunes(artist: String, album: String) async -> Data? {
        let cleanedArtist = primaryArtistName(artist)
        let cleanedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedArtist.isEmpty || !cleanedAlbum.isEmpty else { return nil }

        var terms: [String] = []
        if !cleanedArtist.isEmpty, !cleanedAlbum.isEmpty {
            terms.append("\(cleanedArtist) \(cleanedAlbum)")
        } else if !cleanedAlbum.isEmpty {
            terms.append(cleanedAlbum)
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
        return nil
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

            guard let pick = bestMatch(results: results, artist: artist, album: album) else {
                return nil
            }
            guard var artURLString = pick["artworkUrl100"] as? String else { return nil }
            artURLString = artURLString
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
                .replacingOccurrences(of: "100x100", with: "600x600")
            guard let artURL = URL(string: artURLString) else { return nil }

            let (imageData, imageResponse) = try await URLSession.shared.data(from: artURL)
            guard let imageHTTP = imageResponse as? HTTPURLResponse,
                  (200...299).contains(imageHTTP.statusCode),
                  !imageData.isEmpty else { return nil }
            return imageData
        } catch {
            return nil
        }
    }

    private static func bestMatch(results: [[String: Any]], artist: String, album: String) -> [String: Any]? {
        let artistL = artist.lowercased()
        let albumL = album.lowercased()
            .replacingOccurrences(of: "’", with: "'")

        func norm(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Match album + artista (obbligatorio se entrambi noti). Niente fallback “primo risultato”.
        if let hit = results.first(where: { row in
            let ra = norm(row["artistName"] as? String ?? "")
            let rl = norm(row["collectionName"] as? String ?? "")
            let albumOK = albumL.isEmpty
                || rl == albumL
                || rl.contains(albumL)
                || albumL.contains(rl)
            let artistOK = artistL.isEmpty
                || ra == artistL
                || ra.contains(artistL)
                || artistL.contains(ra)
            return albumOK && artistOK
        }) {
            return hit
        }

        // Solo se manca l’artista: match esatto sul titolo album
        if artistL.isEmpty, !albumL.isEmpty,
           let hit = results.first(where: { row in
               norm(row["collectionName"] as? String ?? "") == albumL
           }) {
            return hit
        }

        return nil
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

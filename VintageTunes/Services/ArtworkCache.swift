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
        "\(artist.lowercased())|||\(album.lowercased())"
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

    /// Forza il salvataggio in cache UI di una cover già nota (es. dopo import).
    func store(artist: String, album: String, data: Data) {
        let k = key(artist: artist, album: album)
        failed.remove(k)
        if let image = NSImage(data: data) {
            images[k] = image.resized(maxPixel: 256)
            CoverArtService.saveToDisk(data: data, artist: artist, album: album)
        }
    }

    func clear() {
        images.removeAll()
        inFlight.removeAll()
        failed.removeAll()
    }
}

/// Risolve cover: file audio → cache disco → iTunes Search API.
enum CoverArtService {
    private static var diskCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    static func cacheKey(artist: String, album: String) -> String {
        let raw = "\(artist.lowercased())|||\(album.lowercased())"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
    }

    /// JPEG/PNG data della cover, se trovata.
    static func resolveArtworkData(artist: String, album: String, fileURL: URL?) async -> Data? {
        if let fileURL, let embedded = await loadEmbeddedData(from: fileURL) {
            saveToDisk(data: embedded, artist: artist, album: album)
            return embedded
        }
        if let disk = loadFromDisk(artist: artist, album: album) {
            return disk
        }
        if let remote = await fetchFromiTunes(artist: artist, album: album) {
            saveToDisk(data: remote, artist: artist, album: album)
            return remote
        }
        return nil
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

    /// Cerca su iTunes Search API (nessuna API key). Preferisce match artista+album.
    static func fetchFromiTunes(artist: String, album: String) async -> Data? {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let al = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty || !al.isEmpty else { return nil }

        let term = [a, al].filter { !$0.isEmpty }.joined(separator: " ")
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

            let pick = bestMatch(results: results, artist: a, album: al) ?? results[0]
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
        return results.first { row in
            let ra = (row["artistName"] as? String ?? "").lowercased()
            let rl = (row["collectionName"] as? String ?? "").lowercased()
            let artistOK = artistL.isEmpty || ra.contains(artistL) || artistL.contains(ra)
            let albumOK = albumL.isEmpty || rl.contains(albumL) || albumL.contains(rl)
            return artistOK && albumOK
        }
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

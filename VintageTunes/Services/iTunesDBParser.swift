import Foundation

enum iTunesDBError: LocalizedError {
    case missingFile
    case invalidHeader(String)
    case truncated
    case unsupported

    var errorDescription: String? {
        switch self {
        case .missingFile: return "iTunesDB non trovato."
        case .invalidHeader(let s): return "Header iTunesDB non valido: \(s)"
        case .truncated: return "iTunesDB troncato o corrotto."
        case .unsupported: return "Formato iTunesDB non supportato in scrittura."
        }
    }
}

struct ParsedLibrary {
    var tracks: [Track]
    var playlists: [Playlist]
    var dbVersion: UInt32
    var rawData: Data
    var session: iTunesDBSessionState
}

final class iTunesDBParser {
    /// MHOD string types managed by VintageTunes (rebuilt on write).
    private static let managedMhodTypes: Set<UInt32> = [1, 2, 3, 4, 5, 6]

    func parse(at url: URL, volumeRoot: URL) throws -> ParsedLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw iTunesDBError.missingFile
        }
        let data = try Data(contentsOf: url)
        guard data.count >= 12 else { throw iTunesDBError.truncated }

        let magic = String(bytes: data[0..<4], encoding: .ascii) ?? ""
        guard magic == "mhbd" else { throw iTunesDBError.invalidHeader(magic) }

        let mhbdHeaderLen = Int(readU32(data, 4))
        guard mhbdHeaderLen >= 12, mhbdHeaderLen <= data.count else { throw iTunesDBError.truncated }
        let mhbdHeader = Data(data[0..<mhbdHeaderLen])

        let dbVersion = readU32(data, 16)
        var tracks: [Track] = []
        var playlists: [Playlist] = []
        var mhsdLayout: [iTunesDBMHSDSlot] = []
        var hasPlaylistSlot = false

        var offset = mhbdHeaderLen
        let total = Int(readU32(data, 8))
        let end = min(total, data.count)

        while offset + 12 <= end {
            let chunk = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let headerLen = Int(readU32(data, offset + 4))
            let totalLen = Int(readU32(data, offset + 8))
            guard headerLen >= 12, totalLen >= headerLen, offset + totalLen <= data.count else { break }

            if chunk == "mhsd" {
                let type = readU32(data, offset + 12)
                let bodyStart = offset + headerLen
                let bodyEnd = offset + totalLen
                let preservedChunk = Data(data[offset..<(offset + totalLen)])

                switch type {
                case 1:
                    tracks = parseTrackList(data, start: bodyStart, end: bodyEnd, volumeRoot: volumeRoot)
                    mhsdLayout.append(.tracks)
                case 2:
                    let parsed = parsePlaylistList(data, start: bodyStart, end: bodyEnd)
                    playlists.append(contentsOf: parsed)
                    if !hasPlaylistSlot {
                        mhsdLayout.append(.playlists)
                        hasPlaylistSlot = true
                    } else {
                        mhsdLayout.append(.preserved(preservedChunk))
                    }
                case 3, 5:
                    if !hasPlaylistSlot {
                        let parsed = parsePlaylistList(data, start: bodyStart, end: bodyEnd)
                        playlists.append(contentsOf: parsed)
                        mhsdLayout.append(.playlists)
                        hasPlaylistSlot = true
                    } else {
                        mhsdLayout.append(.preserved(preservedChunk))
                    }
                default:
                    mhsdLayout.append(.preserved(preservedChunk))
                }
            }

            offset += totalLen
        }

        if !mhsdLayout.contains(where: { if case .tracks = $0 { return true }; return false }) {
            mhsdLayout.insert(.tracks, at: 0)
        }
        if !hasPlaylistSlot {
            mhsdLayout.append(.playlists)
        }

        // Deduplicate playlists by id while preferring fuller lists (keep their blob).
        var unique: [UInt64: Playlist] = [:]
        for p in playlists {
            if let existing = unique[p.id] {
                if p.trackIDs.count > existing.trackIDs.count {
                    unique[p.id] = p
                }
            } else {
                unique[p.id] = p
            }
        }

        return ParsedLibrary(
            tracks: tracks,
            playlists: Array(unique.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            dbVersion: dbVersion,
            rawData: data,
            session: iTunesDBSessionState(mhbdHeader: mhbdHeader, mhsdLayout: mhsdLayout)
        )
    }

    private func parseTrackList(_ data: Data, start: Int, end: Int, volumeRoot: URL) -> [Track] {
        guard start + 12 <= end else { return [] }
        let magic = String(bytes: data[start..<(start + 4)], encoding: .ascii) ?? ""
        guard magic == "mhlt" else { return [] }

        let headerLen = Int(readU32(data, start + 4))
        var offset = start + headerLen
        var tracks: [Track] = []

        while offset + 12 <= end {
            let chunk = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            guard chunk == "mhit" else { break }
            let headerLen = Int(readU32(data, offset + 4))
            let totalLen = Int(readU32(data, offset + 8))
            guard headerLen >= 0x9c, totalLen >= headerLen, offset + totalLen <= data.count else { break }

            let headerBytes = Data(data[offset..<(offset + headerLen)])

            let trackID = readU32(data, offset + 16)
            let sizeBytes = headerLen > 36 ? readU32(data, offset + 36) : 0
            let durationMs = headerLen > 40 ? readU32(data, offset + 40) : 0
            let trackNumber = headerLen > 44 ? readU32(data, offset + 44) : 0
            let year = headerLen > 52 ? readU32(data, offset + 52) : 0
            let bitrate = headerLen > 56 ? readU32(data, offset + 56) : 0
            // Stored as sampleRate << 16 on device
            let rawRate = headerLen > 60 ? readU32(data, offset + 60) : 0
            let sampleRate = rawRate > 0x10000 ? rawRate >> 16 : rawRate
            let mediaType = headerLen > 208 ? readU32(data, offset + 208) : 1
            let rating: UInt8 = headerLen > 31 ? data[offset + 31] : 0
            let playCount = headerLen > 80 ? readU32(data, offset + 80) : 0
            let lastPlayedMacTime = headerLen > 88 ? readU32(data, offset + 88) : 0

            var title = ""
            var artist = ""
            var album = ""
            var genre = ""
            var location = ""
            var extraMhods: [Data] = []

            var child = offset + headerLen
            let childEnd = offset + totalLen
            while child + 16 <= childEnd {
                let cmagic = String(bytes: data[child..<(child + 4)], encoding: .ascii) ?? ""
                guard cmagic == "mhod" else { break }
                let cHeader = Int(readU32(data, child + 4))
                let cTotal = Int(readU32(data, child + 8))
                let type = readU32(data, child + 12)
                guard cTotal >= cHeader, child + cTotal <= data.count else { break }

                if Self.managedMhodTypes.contains(type) {
                    if let str = readMhodString(data, at: child) {
                        switch type {
                        case 1: title = str
                        case 2: location = str
                        case 3: album = str
                        case 4: artist = str
                        case 5: genre = str
                        default: break // type 6 filetype — regenerated on write
                        }
                    }
                } else {
                    extraMhods.append(Data(data[child..<(child + cTotal)]))
                }
                child += cTotal
            }

            var resolved: URL?
            if !location.isEmpty {
                let relative = location
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    .replacingOccurrences(of: ":", with: "/")
                resolved = volumeRoot.appendingPathComponent(relative)
            }

            tracks.append(
                Track(
                    id: trackID,
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
                    dbBlob: TrackDBBlob(header: headerBytes, extraMhods: extraMhods),
                    resolvedPath: resolved
                )
            )

            offset += totalLen
        }

        return tracks
    }

    private func parsePlaylistList(_ data: Data, start: Int, end: Int) -> [Playlist] {
        guard start + 12 <= end else { return [] }
        let magic = String(bytes: data[start..<(start + 4)], encoding: .ascii) ?? ""
        guard magic == "mhlp" else { return [] }

        let headerLen = Int(readU32(data, start + 4))
        var offset = start + headerLen
        var playlists: [Playlist] = []

        while offset + 12 <= end {
            let chunk = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            guard chunk == "mhyp" else { break }
            let headerLen = Int(readU32(data, offset + 4))
            let totalLen = Int(readU32(data, offset + 8))
            guard totalLen >= headerLen, offset + totalLen <= data.count else { break }

            let headerBytes = Data(data[offset..<(offset + headerLen)])
            let isMaster = headerLen > 20 ? readU32(data, offset + 20) == 1 : false
            let timestamp = headerLen > 28 ? readU64(data, offset + 28) : UInt64(offset)

            var name = isMaster ? "Libreria" : "Playlist"
            var trackIDs: [UInt32] = []
            var extraMhods: [Data] = []

            var child = offset + headerLen
            let childEnd = offset + totalLen
            while child + 12 <= childEnd {
                let cmagic = String(bytes: data[child..<(child + 4)], encoding: .ascii) ?? ""
                let cHeader = Int(readU32(data, child + 4))
                let cTotal = Int(readU32(data, child + 8))
                guard cTotal >= 12, child + cTotal <= data.count else { break }

                if cmagic == "mhod" {
                    let type = readU32(data, child + 12)
                    if type == 1, let str = readMhodString(data, at: child), !str.isEmpty {
                        name = str
                    } else {
                        extraMhods.append(Data(data[child..<(child + cTotal)]))
                    }
                } else if cmagic == "mhip" {
                    // track id typically at offset 24 in mhip
                    if cHeader > 24 || cTotal > 24 {
                        let tid = readU32(data, child + 24)
                        if tid != 0 { trackIDs.append(tid) }
                    }
                }

                child += cTotal
            }

            playlists.append(
                Playlist(
                    id: timestamp == 0 ? UInt64(offset) : timestamp,
                    name: name,
                    isMaster: isMaster,
                    trackIDs: trackIDs,
                    dbBlob: PlaylistDBBlob(header: headerBytes, extraMhods: extraMhods)
                )
            )

            offset += totalLen
        }

        return playlists
    }

    private func readMhodString(_ data: Data, at offset: Int) -> String? {
        let total = Int(readU32(data, offset + 8))
        let header = Int(readU32(data, offset + 4))
        guard total > 12, offset + total <= data.count else { return nil }

        // Standard iTunesDB string MHOD: fields through 36, UTF-16LE at 40, length at 28.
        if total >= 40, offset + 40 <= data.count {
            let length = Int(readU32(data, offset + 28))
            let stringOffset = offset + 40
            if length > 0, stringOffset + length <= offset + total {
                return decodeUTF16LE(data[stringOffset..<(stringOffset + length)])
            }
            // Some DBs leave length 0 but still have payload until total
            let fallbackLen = (offset + total) - stringOffset
            if fallbackLen >= 2 {
                return decodeUTF16LE(data[stringOffset..<(stringOffset + fallbackLen)])
            }
        }

        // Legacy / podcast-style: string starts right after declared header
        let start = offset + max(header, 24)
        let len = max(0, (offset + total) - start)
        guard len >= 2 else { return nil }
        return decodeUTF16LE(data[start..<(start + len)])
    }

    private func decodeUTF16LE(_ slice: Data.SubSequence) -> String {
        var bytes = Array(slice)
        if bytes.count % 2 == 1 { bytes.removeLast() }
        // Strip trailing UTF-16 null if present
        while bytes.count >= 2, bytes[bytes.count - 2] == 0, bytes[bytes.count - 1] == 0 {
            bytes.removeLast(2)
        }
        guard !bytes.isEmpty else { return "" }
        return String(bytes: bytes, encoding: .utf16LittleEndian)?
            .trimmingCharacters(in: .controlCharacters) ?? ""
    }
}

func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

func readU64(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset + 8 <= data.count else { return 0 }
    var value: UInt64 = 0
    for i in 0..<8 {
        value |= UInt64(data[offset + i]) << (8 * i)
    }
    return value
}

func appendU16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

func appendU32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

func appendU64(_ data: inout Data, _ value: UInt64) {
    for i in 0..<8 {
        data.append(UInt8((value >> (8 * i)) & 0xff))
    }
}

func appendFourCC(_ data: inout Data, _ value: String) {
    let chars = Array(value.utf8.prefix(4))
    data.append(contentsOf: chars)
    if chars.count < 4 {
        data.append(contentsOf: repeatElement(UInt8(0), count: 4 - chars.count))
    }
}

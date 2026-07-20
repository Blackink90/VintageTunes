import Foundation

@main
struct VerifyiTunesDBPreserve {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vt-itunesdb-preserve-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("iTunesDB")

        let drafts = [
            iTunesDBWriter.TrackDraft(
                id: 1001,
                title: "Alpha",
                artist: "Artist",
                album: "Album",
                genre: "Rock",
                location: ":iPod_Control:Music:F01:VT00001001.mp3",
                durationMs: 180_000,
                sizeBytes: 3_000_000,
                trackNumber: 1,
                year: 2005,
                bitrate: 256,
                sampleRate: 44100,
                mediaType: 1,
                filetype: "MPEG audio file",
                rating: 60,
                playCount: 3,
                lastPlayedMacTime: 3_800_000_000
            )
        ]
        let playlists = [
            iTunesDBWriter.PlaylistDraft(id: 1, name: "Libreria", isMaster: true, trackIDs: [1001])
        ]
        try iTunesDBWriter().write(tracks: drafts, playlists: playlists, dbVersion: 0x14, to: dbURL)

        var data = try Data(contentsOf: dbURL)
        guard let mhitRange = findChunk(data, magic: "mhit") else {
            fputs("FAIL: no mhit\n", stderr)
            exit(1)
        }
        let headerLen = Int(readU32(data, mhitRange.location + 4))
        let markerOffset = mhitRange.location + 120
        guard markerOffset < mhitRange.location + headerLen else {
            fputs("FAIL: header too short for marker\n", stderr)
            exit(1)
        }
        data[markerOffset] = 0xCD

        let composer = buildStringMhod(type: 12, string: "Hidden Composer")
        let mhitTotal = Int(readU32(data, mhitRange.location + 8))
        let insertAt = mhitRange.location + mhitTotal
        var patched = data
        patched.insert(contentsOf: composer, at: insertAt)
        writeU32Local(&patched, at: mhitRange.location + 8, UInt32(mhitTotal + composer.count))
        let oldMhodCount = readU32(patched, mhitRange.location + 12)
        writeU32Local(&patched, at: mhitRange.location + 12, oldMhodCount + 1)

        // Parent mhsd (tracks) must grow with the inserted MHOD.
        guard let mhsdTracks = findChunk(patched, magic: "mhsd") else {
            fputs("FAIL: no mhsd after patch\n", stderr)
            exit(1)
        }
        // findChunk returns first mhsd; confirm type 1
        let mhsdType = readU32(patched, mhsdTracks.location + 12)
        guard mhsdType == 1 else {
            fputs("FAIL: expected tracks mhsd first, got \(mhsdType)\n", stderr)
            exit(1)
        }
        let oldMHSDTotal = Int(readU32(patched, mhsdTracks.location + 8))
        writeU32Local(&patched, at: mhsdTracks.location + 8, UInt32(oldMHSDTotal + composer.count))
        let oldFileSizeBeforeAlbum = Int(readU32(patched, 8))
        writeU32Local(&patched, at: 8, UInt32(oldFileSizeBeforeAlbum + composer.count))

        let albumStub = makeEmptyMHSD(type: 4)
        let oldFileSize = Int(readU32(patched, 8))
        patched.append(albumStub)
        writeU32Local(&patched, at: 8, UInt32(oldFileSize + albumStub.count))
        if patched.count > 24 {
            let ds = readU32(patched, 20)
            writeU32Local(&patched, at: 20, ds + 1)
        }

        try patched.write(to: dbURL, options: .atomic)

        let parser = iTunesDBParser()
        let parsed = try parser.parse(at: dbURL, volumeRoot: root)
        guard let track = parsed.tracks.first, let blob = track.dbBlob else {
            fputs("FAIL: missing track blob\n", stderr)
            exit(1)
        }
        guard blob.header.count > 120, blob.header[120] == 0xCD else {
            fputs("FAIL: opaque header byte not preserved in parse\n", stderr)
            exit(1)
        }
        guard blob.extraMhods.contains(where: { readU32($0, 12) == 12 }) else {
            fputs("FAIL: extra MHOD not captured\n", stderr)
            exit(1)
        }
        guard parsed.session.mhsdLayout.contains(where: {
            if case .preserved(let chunk) = $0 { return readU32(chunk, 12) == 4 }
            return false
        }) else {
            fputs("FAIL: type-4 mhsd not in session layout\n", stderr)
            exit(1)
        }

        var edited = track
        edited.rating = 100
        edited.title = "Alpha Edited"
        let outURL = root.appendingPathComponent("iTunesDB-out")
        try iTunesDBWriter().write(
            tracks: [
                iTunesDBWriter.TrackDraft(
                    id: edited.id,
                    title: edited.title,
                    artist: edited.artist,
                    album: edited.album,
                    genre: edited.genre,
                    location: edited.location,
                    durationMs: edited.durationMs,
                    sizeBytes: edited.sizeBytes,
                    trackNumber: edited.trackNumber,
                    year: edited.year,
                    bitrate: edited.bitrate,
                    sampleRate: edited.sampleRate,
                    mediaType: edited.mediaType,
                    filetype: "MPEG audio file",
                    rating: edited.rating,
                    playCount: edited.playCount,
                    lastPlayedMacTime: edited.lastPlayedMacTime,
                    dbBlob: edited.dbBlob
                )
            ],
            playlists: playlists.map {
                iTunesDBWriter.PlaylistDraft(
                    id: $0.id,
                    name: $0.name,
                    isMaster: $0.isMaster,
                    trackIDs: $0.trackIDs,
                    dbBlob: parsed.playlists.first?.dbBlob
                )
            },
            dbVersion: parsed.dbVersion,
            session: parsed.session,
            to: outURL
        )

        let round = try parser.parse(at: outURL, volumeRoot: root)
        guard let t2 = round.tracks.first, let b2 = t2.dbBlob else {
            fputs("FAIL: missing track after write\n", stderr)
            exit(1)
        }
        guard b2.header.count > 120, b2.header[120] == 0xCD else {
            fputs("FAIL: opaque header byte lost on write\n", stderr)
            exit(1)
        }
        guard b2.extraMhods.contains(where: { readU32($0, 12) == 12 }) else {
            fputs("FAIL: extra MHOD lost on write\n", stderr)
            exit(1)
        }
        guard t2.rating == 100, t2.title == "Alpha Edited" else {
            fputs("FAIL: managed fields not updated\n", stderr)
            exit(1)
        }
        guard round.session.mhsdLayout.contains(where: {
            if case .preserved(let chunk) = $0 { return readU32(chunk, 12) == 4 }
            return false
        }) else {
            fputs("FAIL: type-4 mhsd lost on write\n", stderr)
            exit(1)
        }

        print("OK: preserve-and-patch round-trip verified")
    }
}

func findChunk(_ data: Data, magic: String) -> NSRange? {
    var offset = Int(readU32(data, 4))
    let end = min(Int(readU32(data, 8)), data.count)
    while offset + 12 <= end {
        let m = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
        let total = Int(readU32(data, offset + 8))
        if m == magic { return NSRange(location: offset, length: total) }
        if m == "mhsd" {
            let h = Int(readU32(data, offset + 4))
            var child = offset + h
            let childEnd = offset + total
            while child + 12 <= childEnd {
                let cm = String(bytes: data[child..<(child + 4)], encoding: .ascii) ?? ""
                let ch = Int(readU32(data, child + 4))
                if cm == magic {
                    let ct = Int(readU32(data, child + 8))
                    return NSRange(location: child, length: ct)
                }
                // mhlt/mhlp store a count at +8, not total length — walk until mhsd end.
                if cm == "mhlt" || cm == "mhlp" {
                    var item = child + ch
                    while item + 12 <= childEnd {
                        let im = String(bytes: data[item..<(item + 4)], encoding: .ascii) ?? ""
                        let it = Int(readU32(data, item + 8))
                        if im == magic { return NSRange(location: item, length: it) }
                        guard it >= 12 else { break }
                        item += it
                    }
                    break
                }
                let ct = Int(readU32(data, child + 8))
                guard ct >= 12 else { break }
                child += ct
            }
        }
        guard total >= 12 else { break }
        offset += total
    }
    return nil
}

func makeEmptyMHSD(type: UInt32) -> Data {
    var d = Data()
    appendFourCC(&d, "mhsd")
    appendU32(&d, 0x10)
    appendU32(&d, 0x10)
    appendU32(&d, type)
    return d
}

func buildStringMhod(type: UInt32, string: String) -> Data {
    var stringBytes = Data()
    for unit in string.utf16 {
        appendU16(&stringBytes, unit)
    }
    let total = 40 + stringBytes.count
    var data = Data(count: total)
    writeFourCCLocal(&data, at: 0, "mhod")
    writeU32Local(&data, at: 4, 0x18)
    writeU32Local(&data, at: 8, UInt32(total))
    writeU32Local(&data, at: 12, type)
    writeU32Local(&data, at: 20, 1)
    writeU32Local(&data, at: 28, UInt32(stringBytes.count))
    data.replaceSubrange(40..<(40 + stringBytes.count), with: stringBytes)
    return data
}

func writeFourCCLocal(_ data: inout Data, at offset: Int, _ value: String) {
    let chars = Array(value.utf8.prefix(4))
    for (i, b) in chars.enumerated() { data[offset + i] = b }
}

func writeU32Local(_ data: inout Data, at offset: Int, _ value: UInt32) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
}

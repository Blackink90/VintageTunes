import Foundation

/// Rebuilds a compatible iTunesDB for iPod Video 5G / 5.5G style databases.
struct iTunesDBWriter {
    struct TrackDraft {
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
        var filetype: String
        var rating: UInt8 = 0
    }

    struct PlaylistDraft {
        var id: UInt64
        var name: String
        var isMaster: Bool
        var trackIDs: [UInt32]
    }

    func write(
        tracks: [TrackDraft],
        playlists: [PlaylistDraft],
        dbVersion: UInt32,
        to url: URL
    ) throws {
        let version = dbVersion == 0 ? 0x14 : dbVersion
        let trackMHITHeader: Int = version >= 0x14 ? 0x184 : (version >= 0x12 ? 0x148 : 0xf4)
        let mhbdHeader: Int = version >= 0x17 ? 0xBC : 0x68

        let trackList = buildTrackList(tracks, mhitHeader: trackMHITHeader)
        let playlistList = buildPlaylistList(playlists)

        let trackDataset = wrapDataset(type: 1, child: trackList)
        let playlistDataset = wrapDataset(type: 2, child: playlistList)

        var body = Data()
        body.append(trackDataset)
        body.append(playlistDataset)

        var file = Data()
        appendFourCC(&file, "mhbd")
        appendU32(&file, UInt32(mhbdHeader))
        appendU32(&file, 0) // patched later
        appendU32(&file, 1)
        appendU32(&file, version)
        appendU32(&file, 2)
        appendU64(&file, UInt64.random(in: 1...UInt64.max))
        appendU16(&file, 2)
        while file.count < mhbdHeader {
            file.append(0)
        }
        if mhbdHeader > 72 {
            file[70] = 0x65
            file[71] = 0x6e
        }

        file.append(body)
        writeU32(&file, at: 8, UInt32(file.count))

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path) {
            let backup = dir.appendingPathComponent("iTunesDB.vintagebackup")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: url, to: backup)
        }

        try file.write(to: url, options: .atomic)
    }

    private func wrapDataset(type: UInt32, child: Data) -> Data {
        let headerLen = 0x10
        var data = Data()
        appendFourCC(&data, "mhsd")
        appendU32(&data, UInt32(headerLen))
        appendU32(&data, UInt32(headerLen + child.count))
        appendU32(&data, type)
        data.append(child)
        return data
    }

    private func buildTrackList(_ tracks: [TrackDraft], mhitHeader: Int) -> Data {
        var children = Data()
        for track in tracks {
            children.append(buildTrack(track, headerLen: mhitHeader))
        }

        let headerLen = 0x5c
        var data = Data()
        appendFourCC(&data, "mhlt")
        appendU32(&data, UInt32(headerLen))
        appendU32(&data, UInt32(tracks.count))
        while data.count < headerLen { data.append(0) }
        data.append(children)
        return data
    }

    private func buildTrack(_ track: TrackDraft, headerLen: Int) -> Data {
        var mhods = Data()
        mhods.append(buildStringMhod(type: 1, string: track.title))
        mhods.append(buildStringMhod(type: 2, string: track.location))
        mhods.append(buildStringMhod(type: 3, string: track.album))
        mhods.append(buildStringMhod(type: 4, string: track.artist))
        if !track.genre.isEmpty {
            mhods.append(buildStringMhod(type: 5, string: track.genre))
        }
        if !track.filetype.isEmpty {
            mhods.append(buildStringMhod(type: 6, string: track.filetype))
        }

        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhit")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + mhods.count))

        let mhodCount: UInt32 = 4
            + (track.genre.isEmpty ? 0 : 1)
            + (track.filetype.isEmpty ? 0 : 1)
        writeU32(&header, at: 12, mhodCount)
        writeU32(&header, at: 16, track.id)
        writeU32(&header, at: 20, 1) // visible
        writeU32(&header, at: 24, filetypeCode(track.filetype))
        // 28-31: type1/type2/compilation/rating
        header[28] = 0
        header[29] = 1
        header[30] = 0
        header[31] = min(track.rating, 100)
        writeU32(&header, at: 32, macTimestamp()) // last modified
        writeU32(&header, at: 36, track.sizeBytes)
        writeU32(&header, at: 40, track.durationMs)
        writeU32(&header, at: 44, track.trackNumber)
        writeU32(&header, at: 48, 0) // total tracks
        writeU32(&header, at: 52, track.year)
        writeU32(&header, at: 56, track.bitrate)
        // iPod expects sample rate << 16
        let rate = track.sampleRate == 0 ? 44100 : track.sampleRate
        writeU32(&header, at: 60, rate << 16)
        writeU32(&header, at: 104, macTimestamp()) // date added

        if headerLen > 212 {
            writeU32(&header, at: 208, track.mediaType == 0 ? 1 : track.mediaType)
        }

        header.append(mhods)
        return header
    }

    private func buildPlaylistList(_ playlists: [PlaylistDraft]) -> Data {
        var children = Data()
        for playlist in playlists {
            children.append(buildPlaylist(playlist))
        }

        let headerLen = 0x5c
        var data = Data()
        appendFourCC(&data, "mhlp")
        appendU32(&data, UInt32(headerLen))
        appendU32(&data, UInt32(playlists.count))
        while data.count < headerLen { data.append(0) }
        data.append(children)
        return data
    }

    private func buildPlaylist(_ playlist: PlaylistDraft) -> Data {
        var children = Data()
        children.append(buildStringMhod(type: 1, string: playlist.name))

        for (index, trackID) in playlist.trackIDs.enumerated() {
            children.append(buildPlaylistItem(trackID: trackID, timestamp: UInt32(index + 1)))
        }

        let headerLen = 0x6c
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhyp")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + children.count))
        writeU32(&header, at: 12, 1) // string mhod count
        writeU32(&header, at: 16, UInt32(playlist.trackIDs.count))
        header[20] = playlist.isMaster ? 1 : 0
        writeU32(&header, at: 24, macTimestamp())
        writeU64(&header, at: 28, playlist.id == 0 ? UInt64.random(in: 1...UInt64.max) : playlist.id)
        writeU16(&header, at: 40, 1) // string mhod count

        header.append(children)
        return header
    }

    private func buildPlaylistItem(trackID: UInt32, timestamp: UInt32) -> Data {
        var mhod = Data(count: 0x18)
        writeFourCC(&mhod, at: 0, "mhod")
        writeU32(&mhod, at: 4, 0x18)
        writeU32(&mhod, at: 8, 0x18)
        writeU32(&mhod, at: 12, 100)

        var data = Data(count: 0x24)
        writeFourCC(&data, at: 0, "mhip")
        writeU32(&data, at: 4, 0x24)
        writeU32(&data, at: 8, UInt32(0x24 + mhod.count))
        writeU32(&data, at: 24, trackID)
        writeU32(&data, at: 28, timestamp)
        data.append(mhod)
        return data
    }

    /// String MHOD: header declares 0x18, but UTF-16LE payload starts at offset 40 (ipodlinux).
    private func buildStringMhod(type: UInt32, string: String) -> Data {
        var stringBytes = Data()
        for unit in string.utf16 {
            appendU16(&stringBytes, unit)
        }
        // iTunesDB string mhods are NOT null-terminated

        let total = 40 + stringBytes.count
        var data = Data(count: total)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, 0x18)
        writeU32(&data, at: 8, UInt32(total))
        writeU32(&data, at: 12, type)
        writeU32(&data, at: 16, 0) // unk1
        writeU32(&data, at: 20, 1) // unk2
        writeU32(&data, at: 24, 0) // position
        writeU32(&data, at: 28, UInt32(stringBytes.count)) // length in bytes
        writeU32(&data, at: 32, 0)
        writeU32(&data, at: 36, 0)
        data.replaceSubrange(40..<(40 + stringBytes.count), with: stringBytes)
        return data
    }

    private func filetypeCode(_ filetype: String) -> UInt32 {
        let ext = filetype.lowercased()
        if ext.contains("mpeg") || ext.contains("mp3") { return 0x4d503320 } // 'MP3 '
        if ext.contains("aac") || ext.contains("m4a") { return 0x4d344120 } // 'M4A '
        if ext.contains("wav") { return 0x57415645 } // 'WAVE'
        if ext.contains("aiff") || ext.contains("aif") { return 0x41494646 } // 'AIFF'
        return 0x4d503320
    }

    /// Mac epoch: seconds since 1904-01-01
    private func macTimestamp() -> UInt32 {
        UInt32(Date().timeIntervalSince1970 + 2_082_844_800)
    }

    private func writeFourCC(_ data: inout Data, at offset: Int, _ value: String) {
        let chars = Array(value.utf8.prefix(4))
        for (i, b) in chars.enumerated() {
            data[offset + i] = b
        }
    }

    private func writeU16(_ data: inout Data, at offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private func writeU32(_ data: inout Data, at offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func writeU64(_ data: inout Data, at offset: Int, _ value: UInt64) {
        for i in 0..<8 {
            data[offset + i] = UInt8((value >> (8 * i)) & 0xff)
        }
    }
}

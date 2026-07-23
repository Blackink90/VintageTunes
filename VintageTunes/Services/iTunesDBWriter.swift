import Foundation

/// Rebuilds iTunesDB matching Music.app format for iPod Video 5.5G (HFS+).
/// Reference: `backup-ipod/official-*/critical/iTunesDB` + `OfficialDBFormat`.
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
        var playCount: UInt32 = 0
        var lastPlayedMacTime: UInt32 = 0
        var dbid: UInt64 = 0
        var hasArtwork: UInt8 = 2
        var artworkCount: UInt16 = 0
        var mhiiLink: UInt32 = 0
        var dbBlob: TrackDBBlob? = nil
    }

    struct PlaylistDraft {
        var id: UInt64
        var name: String
        var isMaster: Bool
        var trackIDs: [UInt32]
        var dbBlob: PlaylistDBBlob? = nil
    }

    func write(
        tracks: [TrackDraft],
        playlists: [PlaylistDraft],
        dbVersion: UInt32,
        session: iTunesDBSessionState? = nil,
        to url: URL
    ) throws {
        let version = dbVersion >= 0x14 ? dbVersion : OfficialDBFormat.preferredVersion

        let trackList = buildTrackList(tracks)
        let playlistList = buildPlaylistList(playlists)
        let specialList = buildSpecialPlaylistList()

        let trackDataset = wrapDataset(type: 1, child: trackList)
        let playlistDataset = wrapDataset(type: 2, child: playlistList)
        let type3Mirror = wrapDataset(type: 3, child: playlistList) // Music.app mirrors playlists here
        let specialDataset = wrapDataset(type: 5, child: specialList)

        let layout: [iTunesDBMHSDSlot]
        if let session, !session.mhsdLayout.isEmpty {
            layout = session.mhsdLayout
        } else {
            // Official order: albums(4) → tracks → type3 → playlists → special → type9
            layout = [.tracks, .podcastPlaylists, .playlists, .specialPlaylists]
        }

        var body = Data()
        var emittedTracks = false
        var emittedPlaylists = false
        var emittedSpecial = false
        var emittedType3 = false
        var datasetCount = 0

        for slot in layout {
            switch slot {
            case .tracks:
                body.append(trackDataset)
                emittedTracks = true
                datasetCount += 1
            case .playlists:
                body.append(playlistDataset)
                emittedPlaylists = true
                datasetCount += 1
            case .podcastPlaylists:
                body.append(type3Mirror)
                emittedType3 = true
                datasetCount += 1
            case .specialPlaylists:
                body.append(specialDataset)
                emittedSpecial = true
                datasetCount += 1
            case .preserved(let chunk):
                guard chunk.count >= 16 else { continue }
                let type = readU32(chunk, 12)
                // Never re-emit sections we regenerate.
                if type == 1 || type == 2 || type == 3 || type == 5 { continue }
                body.append(chunk)
                datasetCount += 1
            }
        }
        if !emittedTracks {
            body.insert(contentsOf: trackDataset, at: 0)
            datasetCount += 1
        }
        if !emittedType3 {
            // Keep type-3 mirror before type-2 when inserting late.
            body.append(type3Mirror)
            datasetCount += 1
        }
        if !emittedPlaylists {
            body.append(playlistDataset)
            datasetCount += 1
        }
        if !emittedSpecial {
            body.append(specialDataset)
            datasetCount += 1
        }

        var file = Data()
        if let preserved = session?.mhbdHeader, preserved.count >= OfficialDBFormat.mhbdHeaderLength,
           String(bytes: preserved[0..<4], encoding: .ascii) == "mhbd" {
            file = Data(preserved.prefix(OfficialDBFormat.mhbdHeaderLength))
            while file.count < OfficialDBFormat.mhbdHeaderLength { file.append(0) }
            writeU32(&file, at: 16, version)
            writeU32(&file, at: 20, UInt32(datasetCount))
        } else {
            appendFourCC(&file, "mhbd")
            appendU32(&file, UInt32(OfficialDBFormat.mhbdHeaderLength))
            appendU32(&file, 0)
            appendU32(&file, 1)
            appendU32(&file, version)
            appendU32(&file, UInt32(datasetCount))
            appendU64(&file, UInt64.random(in: 1...UInt64.max))
            appendU16(&file, 1) // Mac platform
            while file.count < OfficialDBFormat.mhbdHeaderLength { file.append(0) }
            file[0x46] = 0x69 // i
            file[0x47] = 0x74 // t
        }

        file.append(body)
        writeU32(&file, at: 8, UInt32(file.count))
        writeU32(&file, at: 20, UInt32(datasetCount))

        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let lockURL = dir.appendingPathComponent("iTunesLock")
        try? fm.removeItem(at: lockURL)

        if fm.fileExists(atPath: url.path) {
            let backup = dir.appendingPathComponent("iTunesDB.vintagebackup")
            try? fm.removeItem(at: backup)
            try performFileOpWithBusyRetry {
                try fm.copyItem(at: url, to: backup)
            }
        }

        try performFileOpWithBusyRetry {
            try file.write(to: url, options: .atomic)
        }
        try? fm.removeItem(at: lockURL)
    }

    private func performFileOpWithBusyRetry(_ body: () throws -> Void) throws {
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                try body()
                return
            } catch {
                lastError = error
                guard isFileBusy(error), attempt < 4 else { break }
                Thread.sleep(forTimeInterval: 0.25 * Double(attempt + 1))
            }
        }
        if let lastError {
            if isFileBusy(lastError) {
                throw SyncError.database(
                    "File iTunesDB occupato (OSStatus -47). Chiudi Musica/iTunes e riprova."
                )
            }
            throw lastError
        }
    }

    private func isFileBusy(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain, ns.code == -47 { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EBUSY) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isFileBusy(underlying)
        }
        let text = ns.localizedDescription.lowercased()
        return text.contains("-47") || text.contains("occupat") || text.contains("busy")
    }

    private func wrapDataset(type: UInt32, child: Data) -> Data {
        let headerLength = OfficialDBFormat.mhsdHeaderLength
        var data = Data()
        appendFourCC(&data, "mhsd")
        appendU32(&data, UInt32(headerLength))
        appendU32(&data, UInt32(headerLength + child.count))
        appendU32(&data, type)
        while data.count < headerLength { data.append(0) }
        data.append(child)
        return data
    }

    private func buildSpecialPlaylistList() -> Data {
        var children = Data()
        for (index, spec) in OfficialDBFormat.categorySpecs.enumerated() {
            children.append(
                buildCategoryPlaylist(
                    name: spec.name,
                    mhsd5: spec.mhsd5,
                    mhsd5b: spec.mhsd5b,
                    playlistID: UInt64(index + 200)
                )
            )
        }
        return wrapList(magic: "mhlp", count: OfficialDBFormat.categorySpecs.count, children: children)
    }

    private func buildCategoryPlaylist(name: String, mhsd5: UInt16, mhsd5b: UInt16, playlistID: UInt64) -> Data {
        var children = Data()
        children.append(buildStringMhod(type: 1, string: name))
        children.append(OfficialDBFormat.mhod100)
        children.append(OfficialDBFormat.mhod102)
        children.append(OfficialDBFormat.mhod50)
        children.append(OfficialDBFormat.mhod51)

        let headerLen = OfficialDBFormat.mhypHeaderLength
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhyp")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + children.count))
        writeU32(&header, at: 12, 5) // name + 100 + 102 + 50 + 51
        writeU32(&header, at: 16, 0) // empty membership
        header[20] = 0
        writeU32(&header, at: 24, macTimestamp())
        writeU64(&header, at: 28, playlistID)
        writeU16(&header, at: 40, 1)
        writeU16(&header, at: 42, 0)
        writeU32(&header, at: 44, 1)
        writeU16(&header, at: 0x50, mhsd5)
        writeU16(&header, at: 0x52, mhsd5b)
        writeU32(&header, at: 0x54, 0)
        header.append(children)
        return header
    }

    private func buildTrackList(_ tracks: [TrackDraft]) -> Data {
        var children = Data()
        for track in tracks {
            children.append(buildTrack(track))
        }
        return wrapList(magic: "mhlt", count: tracks.count, children: children)
    }

    private func wrapList(magic: String, count: Int, children: Data) -> Data {
        let headerLen = magic == "mhlt" ? OfficialDBFormat.mhltHeaderLength : OfficialDBFormat.mhlpHeaderLength
        var data = Data()
        appendFourCC(&data, magic)
        appendU32(&data, UInt32(headerLen))
        appendU32(&data, UInt32(count))
        while data.count < headerLen { data.append(0) }
        data.append(children)
        return data
    }

    private func buildTrack(_ track: TrackDraft) -> Data {
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
        if let blob = track.dbBlob {
            for extra in blob.extraMhods {
                mhods.append(extra)
            }
        }

        let managedCount: UInt32 = 4
            + (track.genre.isEmpty ? 0 : 1)
            + (track.filetype.isEmpty ? 0 : 1)
        let mhodCount = managedCount + UInt32(track.dbBlob?.extraMhods.count ?? 0)

        let fourCC = OfficialDBFormat.filetypeFourCC(for: track.filetype)
        let flags = OfficialDBFormat.codecFlags(for: fourCC)

        var header: Data
        if let blob = track.dbBlob, blob.header.count >= 0x9c {
            header = blob.header
            if header.count < OfficialDBFormat.mhitHeaderLength {
                header.append(Data(count: OfficialDBFormat.mhitHeaderLength - header.count))
            }
        } else {
            header = OfficialDBFormat.mhitHeaderTemplate
        }

        let headerLen = header.count
        writeFourCC(&header, at: 0, "mhit")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + mhods.count))
        writeU32(&header, at: 12, mhodCount)
        writeU32(&header, at: 16, track.id)
        writeU32(&header, at: 20, 1)
        OfficialDBFormat.writeFiletypeMarker(&header, at: 24, fourCC: fourCC)
        header[28] = flags.0
        header[29] = flags.1
        header[30] = 0
        header[31] = min(track.rating, 100)
        writeU32(&header, at: 32, macTimestamp())
        writeU32(&header, at: 36, track.sizeBytes)
        writeU32(&header, at: 40, track.durationMs)
        writeU32(&header, at: 44, track.trackNumber)
        writeU32(&header, at: 52, track.year)
        writeU32(&header, at: 56, track.bitrate)
        let rate = track.sampleRate == 0 ? 44100 : track.sampleRate
        writeU32(&header, at: 60, rate << 16)
        writeU32(&header, at: 80, track.playCount)
        if headerLen > 84 {
            writeU32(&header, at: 84, track.playCount)
        }
        writeU32(&header, at: 88, track.lastPlayedMacTime)
        if header.count > 108, readU32(header, 104) == 0 {
            writeU32(&header, at: 104, macTimestamp())
        }
        let dbid = track.dbid == 0
            ? (UInt64(track.id) | (UInt64.random(in: 1...UInt64(UInt32.max)) << 32))
            : track.dbid
        if headerLen > 120 {
            writeU64(&header, at: 112, dbid)
        }
        if headerLen > 126 {
            writeU16(&header, at: 124, track.artworkCount)
        }
        if headerLen > 164 {
            header[164] = track.hasArtwork == 1 ? 1 : 2
        }
        if headerLen > 176 {
            writeU64(&header, at: 168, dbid) // dbid2
        }
        if headerLen > 178 {
            header[178] = 2 // mark_unplayed style seen in official DB
        }
        // Gapless: niente residui del template Music.app (sample count di un’altra traccia
        // faceva tagliare il brano sull’iPod). Sample count allineato a durata × rate;
        // flag gapless a 0 → il firmware usa soprattutto durationMs.
        if headerLen > 204 {
            writeU32(&header, at: 184, 0) // pregap
            let sampleCount: UInt64
            if track.durationMs > 0 {
                sampleCount = UInt64(track.durationMs) * UInt64(rate) / 1000
            } else {
                sampleCount = 0
            }
            writeU64(&header, at: 188, sampleCount)
            writeU32(&header, at: 196, 0) // unk25
            writeU32(&header, at: 200, 0) // postgap
        }
        if headerLen > 212 {
            writeU32(&header, at: 208, track.mediaType == 0 ? 1 : track.mediaType)
        }
        if headerLen > 260 {
            writeU32(&header, at: 248, 0) // gaplessData
            writeU16(&header, at: 256, 0) // gaplessTrackFlag
            writeU16(&header, at: 258, 0) // gaplessAlbumFlag
        }
        if headerLen > 356 {
            writeU32(&header, at: 352, track.mhiiLink)
        }

        header.append(mhods)
        return header
    }

    private func buildPlaylistList(_ playlists: [PlaylistDraft]) -> Data {
        var children = Data()
        for playlist in playlists {
            children.append(buildPlaylist(playlist))
        }
        return wrapList(magic: "mhlp", count: playlists.count, children: children)
    }

    private func buildPlaylist(_ playlist: PlaylistDraft) -> Data {
        var children = Data()
        children.append(buildStringMhod(type: 1, string: playlist.name))

        // Official user/master always include MHOD 100 + 102.
        var extras = playlist.dbBlob?.extraMhods ?? []
        let has100 = extras.contains { $0.count >= 16 && readU32($0, 12) == 100 }
        let has102 = extras.contains { $0.count >= 16 && readU32($0, 12) == 102 }
        if !has100 { children.append(OfficialDBFormat.mhod100) }
        if !has102 { children.append(OfficialDBFormat.mhod102) }
        for extra in extras {
            children.append(extra)
        }

        for trackID in playlist.trackIDs {
            children.append(buildPlaylistItem(trackID: trackID, timestamp: macTimestamp()))
        }

        let stringishCount = 1 + (has100 ? 0 : 1) + (has102 ? 0 : 1) + extras.count

        let headerLen = OfficialDBFormat.mhypHeaderLength
        var header: Data
        if let blob = playlist.dbBlob, blob.header.count >= 0x6c {
            header = blob.header
            if header.count < headerLen {
                header.append(Data(count: headerLen - header.count))
            }
        } else {
            header = Data(count: headerLen)
        }

        writeFourCC(&header, at: 0, "mhyp")
        writeU32(&header, at: 4, UInt32(header.count))
        writeU32(&header, at: 8, UInt32(header.count + children.count))
        writeU32(&header, at: 12, UInt32(stringishCount))
        writeU32(&header, at: 16, UInt32(playlist.trackIDs.count))
        header[20] = playlist.isMaster ? 1 : 0
        writeU32(&header, at: 24, macTimestamp())
        writeU64(&header, at: 28, playlist.id == 0 ? UInt64.random(in: 1...UInt64.max) : playlist.id)
        writeU16(&header, at: 40, 1)
        writeU16(&header, at: 42, 0)
        writeU32(&header, at: 44, 1)

        header.append(children)
        return header
    }

    /// Official mhip: header 76 + child MHOD type 100 (total 120).
    private func buildPlaylistItem(trackID: UInt32, timestamp: UInt32) -> Data {
        var mhod = Data(count: 0x2c)
        writeFourCC(&mhod, at: 0, "mhod")
        writeU32(&mhod, at: 4, 0x18)
        writeU32(&mhod, at: 8, 0x2c)
        writeU32(&mhod, at: 12, 100)
        // position field in type-100 child often mirrors track id on modern DBs
        writeU32(&mhod, at: 24, trackID)

        var data = Data(count: OfficialDBFormat.mhipHeaderLength)
        writeFourCC(&data, at: 0, "mhip")
        writeU32(&data, at: 4, UInt32(OfficialDBFormat.mhipHeaderLength))
        writeU32(&data, at: 8, UInt32(OfficialDBFormat.mhipHeaderLength + mhod.count))
        writeU32(&data, at: 12, 1)
        writeU32(&data, at: 16, 0)
        writeU32(&data, at: 20, 0)
        writeU32(&data, at: 24, trackID)
        writeU32(&data, at: 28, timestamp)
        data.append(mhod)
        return data
    }

    /// String MHOD matching Music.app: unk1=0, unk2=0, pos=1, len, unk32=1, unk36=0.
    private func buildStringMhod(type: UInt32, string: String) -> Data {
        var stringBytes = Data()
        for unit in string.utf16 {
            appendU16(&stringBytes, unit)
        }
        let total = 40 + stringBytes.count
        var data = Data(count: total)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, 0x18)
        writeU32(&data, at: 8, UInt32(total))
        writeU32(&data, at: 12, type)
        writeU32(&data, at: 16, 0)
        writeU32(&data, at: 20, 0)
        writeU32(&data, at: 24, 1)
        writeU32(&data, at: 28, UInt32(stringBytes.count))
        writeU32(&data, at: 32, 1)
        writeU32(&data, at: 36, 0)
        data.replaceSubrange(40..<(40 + stringBytes.count), with: stringBytes)
        return data
    }

    private func macTimestamp() -> UInt32 {
        UInt32(Date().timeIntervalSince1970 + 2_082_844_800)
    }

    private func writeFourCC(_ data: inout Data, at offset: Int, _ value: String) {
        let chars = Array(value.utf8.prefix(4))
        for (i, b) in chars.enumerated() {
            data[offset + i] = b
        }
    }

    private func appendFourCC(_ data: inout Data, _ value: String) {
        var chars = Array(value.utf8.prefix(4))
        while chars.count < 4 { chars.append(0x20) }
        data.append(contentsOf: chars)
    }

    private func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func appendU64(_ data: inout Data, _ value: UInt64) {
        for i in 0..<8 {
            data.append(UInt8((value >> (8 * i)) & 0xff))
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

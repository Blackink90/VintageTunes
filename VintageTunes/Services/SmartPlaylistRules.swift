import Foundation

/// Smart playlists: MHOD 50/51 encode/decode + evaluation on Mac.
/// Spec: wikiPodLinux iTunesDB (bytes after `SLst` are big-endian).

struct SmartPlaylistDefinition: Equatable {
    var matchAll: Bool = true
    var rules: [SmartRule] = []
    var limitEnabled: Bool = false
    var limitType: LimitType = .songs
    var limitCount: UInt32 = 25
    var limitSort: LimitSort = .mostPlayed
    var liveUpdate: Bool = true
    /// Rules from iTunes we could not map; kept so reevaluate does not rewrite MHOD 51.
    var skippedUnsupportedRuleCount: Int = 0
    var preservedMhod51: Data? = nil

    enum LimitType: String, CaseIterable, Equatable {
        case songs, minutes, hours, megabytes

        var mhodValue: UInt8 {
            switch self {
            case .minutes: return 1
            case .megabytes: return 2
            case .songs: return 3
            case .hours: return 4
            }
        }

        static func from(mhod: UInt8) -> LimitType {
            switch mhod {
            case 1: return .minutes
            case 2: return .megabytes
            case 4: return .hours
            default: return .songs
            }
        }
    }

    enum LimitSort: String, CaseIterable, Equatable {
        case mostPlayed
        case leastPlayed
        case recentlyPlayed
        case highestRating
        case recentlyAdded
        case oldestAdded

        var mhodValue: UInt8 {
            switch self {
            case .mostPlayed, .leastPlayed: return 0x14
            case .recentlyPlayed: return 0x15
            case .highestRating: return 0x17
            case .recentlyAdded, .oldestAdded: return 0x10
            }
        }

        var reverse: Bool {
            switch self {
            case .leastPlayed, .oldestAdded: return true
            default: return false
            }
        }

        static func from(mhod: UInt8, reverse: Bool) -> LimitSort {
            switch mhod {
            case 0x15: return .recentlyPlayed
            case 0x17: return .highestRating
            case 0x10: return reverse ? .oldestAdded : .recentlyAdded
            case 0x14: return reverse ? .leastPlayed : .mostPlayed
            default: return reverse ? .leastPlayed : .mostPlayed
            }
        }
    }

    static func isSmartPlaylist(_ playlist: Playlist) -> Bool {
        guard let extras = playlist.dbBlob?.extraMhods else { return false }
        return extras.contains { splMhodType($0) == 50 }
    }

    static func decode(from playlist: Playlist) -> SmartPlaylistDefinition? {
        guard let extras = playlist.dbBlob?.extraMhods,
              let m50 = extras.first(where: { splMhodType($0) == 50 }),
              let m51 = extras.first(where: { splMhodType($0) == 51 }) else {
            return nil
        }
        return decode(mhod50: m50, mhod51: m51)
    }

    static func apply(
        _ definition: SmartPlaylistDefinition,
        to playlist: inout Playlist,
        tracks: [Track],
        rewriteRules: Bool = true
    ) {
        let eligible = tracks.filter { !$0.isVideo }
        playlist.trackIDs = definition.matchingTrackIDs(in: eligible)
        var extras = playlist.dbBlob?.extraMhods ?? []
        extras.removeAll {
            let t = splMhodType($0)
            return t == 50 || t == 51
        }
        extras.append(definition.encodeMHOD50())
        if rewriteRules || definition.preservedMhod51 == nil {
            extras.append(definition.encodeMHOD51())
        } else if let preserved = definition.preservedMhod51 {
            extras.append(preserved)
        } else {
            extras.append(definition.encodeMHOD51())
        }
        playlist.dbBlob = PlaylistDBBlob(
            header: playlist.dbBlob?.header ?? Data(),
            extraMhods: extras
        )
    }

    func matchingTrackIDs(in tracks: [Track], now: Date = Date()) -> [UInt32] {
        let evaluable = rules.filter { !$0.isOpaqueSkip }
        var matched: [Track]
        if evaluable.isEmpty {
            matched = tracks
        } else if matchAll {
            matched = tracks.filter { track in evaluable.allSatisfy { $0.matches(track, now: now) } }
        } else {
            matched = tracks.filter { track in evaluable.contains { $0.matches(track, now: now) } }
        }

        guard limitEnabled, limitCount > 0 else {
            return matched.map(\.id)
        }

        sortForLimit(&matched)
        return takeLimit(matched).map(\.id)
    }

    private func sortForLimit(_ matched: inout [Track]) {
        switch limitSort {
        case .mostPlayed, .leastPlayed:
            matched.sort {
                if $0.playCount != $1.playCount {
                    return limitSort == .mostPlayed
                        ? $0.playCount > $1.playCount
                        : $0.playCount < $1.playCount
                }
                return $0.id < $1.id
            }
        case .recentlyPlayed:
            matched.sort {
                if $0.lastPlayedMacTime != $1.lastPlayedMacTime {
                    return $0.lastPlayedMacTime > $1.lastPlayedMacTime
                }
                return $0.id < $1.id
            }
        case .highestRating:
            matched.sort {
                if $0.rating != $1.rating { return $0.rating > $1.rating }
                return $0.id < $1.id
            }
        case .recentlyAdded, .oldestAdded:
            matched.sort {
                if $0.dateAddedMacTime != $1.dateAddedMacTime {
                    return limitSort == .recentlyAdded
                        ? $0.dateAddedMacTime > $1.dateAddedMacTime
                        : $0.dateAddedMacTime < $1.dateAddedMacTime
                }
                return $0.id < $1.id
            }
        }
    }

    private func takeLimit(_ matched: [Track]) -> [Track] {
        switch limitType {
        case .songs:
            return Array(matched.prefix(Int(limitCount)))
        case .minutes:
            let budget = UInt64(limitCount) * 60_000
            return accumulate(matched, budget: budget) { UInt64($0.durationMs) }
        case .hours:
            let budget = UInt64(limitCount) * 3_600_000
            return accumulate(matched, budget: budget) { UInt64($0.durationMs) }
        case .megabytes:
            let budget = UInt64(limitCount) * 1_048_576
            return accumulate(matched, budget: budget) { UInt64($0.sizeBytes) }
        }
    }

    private func accumulate(_ matched: [Track], budget: UInt64, weight: (Track) -> UInt64) -> [Track] {
        var used: UInt64 = 0
        var out: [Track] = []
        for track in matched {
            let w = weight(track)
            if !out.isEmpty, used + w > budget { break }
            out.append(track)
            used += w
            if used >= budget { break }
        }
        return out
    }

    func encodeMHOD50() -> Data {
        var data = Data(count: 0x60)
        splWriteFourCC(&data, at: 0, "mhod")
        splWriteU32LE(&data, at: 4, 0x18)
        splWriteU32LE(&data, at: 8, 0x60)
        splWriteU32LE(&data, at: 12, 50)
        data[24] = liveUpdate ? 1 : 0
        data[25] = 1
        data[26] = limitEnabled ? 1 : 0
        data[27] = limitType.mhodValue
        data[28] = limitSort.mhodValue
        splWriteU32LE(&data, at: 32, limitEnabled ? limitCount : 0)
        data[36] = 0
        data[37] = limitSort.reverse ? 1 : 0
        return data
    }

    func encodeMHOD51() -> Data {
        let writable = rules.filter { !$0.isOpaqueSkip }
        var rulesBlob = Data()
        for rule in writable {
            rulesBlob.append(rule.encode())
        }
        let total = 160 + rulesBlob.count
        var data = Data(count: total)
        splWriteFourCC(&data, at: 0, "mhod")
        splWriteU32LE(&data, at: 4, 0x18)
        splWriteU32LE(&data, at: 8, UInt32(total))
        splWriteU32LE(&data, at: 12, 51)
        data[24] = 0x53; data[25] = 0x4C; data[26] = 0x73; data[27] = 0x74
        splWriteU32BE(&data, at: 28, 0x0001_0001)
        splWriteU32BE(&data, at: 32, UInt32(writable.count))
        splWriteU32BE(&data, at: 36, matchAll ? 0 : 1)
        if !rulesBlob.isEmpty {
            data.replaceSubrange(160..<(160 + rulesBlob.count), with: rulesBlob)
        }
        return data
    }

    static func decode(mhod50: Data, mhod51: Data) -> SmartPlaylistDefinition? {
        guard mhod50.count >= 38, splMhodType(mhod50) == 50 else { return nil }
        guard mhod51.count >= 160, splMhodType(mhod51) == 51 else { return nil }
        guard mhod51[24] == 0x53, mhod51[25] == 0x4C,
              mhod51[26] == 0x73, mhod51[27] == 0x74 else { return nil }

        var def = SmartPlaylistDefinition()
        def.liveUpdate = mhod50[24] != 0
        def.limitEnabled = mhod50[26] != 0
        def.limitType = .from(mhod: mhod50[27])
        let reverse = mhod50.count > 37 && mhod50[37] != 0
        def.limitSort = .from(mhod: mhod50[28], reverse: reverse)
        def.limitCount = splReadU32LE(mhod50, 32)
        if def.limitCount == 0 { def.limitCount = 25 }

        let ruleCount = Int(splReadU32BE(mhod51, 32))
        def.matchAll = splReadU32BE(mhod51, 36) == 0

        var offset = 160
        var parsed: [SmartRule] = []
        var skipped = 0
        for _ in 0..<ruleCount {
            if let (rule, consumed) = SmartRule.decode(from: mhod51, at: offset) {
                parsed.append(rule)
                offset += consumed
            } else if let consumed = SmartRule.skipEncodedRule(from: mhod51, at: offset) {
                skipped += 1
                offset += consumed
            } else {
                // Truncated — keep what we have
                break
            }
        }
        def.rules = parsed
        def.skippedUnsupportedRuleCount = skipped
        if skipped > 0 {
            def.preservedMhod51 = mhod51
        }
        return def
    }
}

struct SmartRule: Equatable, Identifiable {
    var id = UUID()
    var field: Field = .artist
    var stringOp: StringOp = .contains
    var intOp: IntOp = .equals
    var stringValue: String = ""
    /// Stars 0…5 for rating; seconds for duration UI; N for inTheLast; raw otherwise.
    var intValue: Int = 0
    var timeUnit: TimeUnit = .weeks
    /// Placeholder for skipped iTunes rules (never matches / never encoded).
    var isOpaqueSkip: Bool = false

    enum TimeUnit: String, CaseIterable, Equatable {
        case days, weeks

        var seconds: UInt64 {
            switch self {
            case .days: return 86_400
            case .weeks: return 604_800
            }
        }

        static func from(seconds: UInt64) -> TimeUnit {
            if seconds == 86_400 { return .days }
            if seconds == 604_800 { return .weeks }
            // Prefer weeks when evenly divisible
            if seconds > 0, seconds % 604_800 == 0 { return .weeks }
            return .days
        }
    }

    enum Field: String, CaseIterable, Equatable {
        case title, artist, album, albumArtist, genre, comment
        case rating, playCount, year, duration, bitrate
        case lastPlayed, dateAdded

        var isString: Bool {
            switch self {
            case .title, .artist, .album, .albumArtist, .genre, .comment: return true
            default: return false
            }
        }

        var isRelativeDate: Bool {
            self == .lastPlayed || self == .dateAdded
        }

        var mhodField: UInt32 {
            switch self {
            case .title: return 0x02
            case .album: return 0x03
            case .artist: return 0x04
            case .bitrate: return 0x05
            case .year: return 0x07
            case .genre: return 0x08
            case .comment: return 0x0e
            case .dateAdded: return 0x10
            case .duration: return 0x0d
            case .playCount: return 0x16
            case .lastPlayed: return 0x17
            case .rating: return 0x19
            case .albumArtist: return 0x47
            }
        }

        static func from(mhod: UInt32) -> Field? {
            switch mhod {
            case 0x02: return .title
            case 0x03: return .album
            case 0x04: return .artist
            case 0x05: return .bitrate
            case 0x07: return .year
            case 0x08: return .genre
            case 0x0d: return .duration
            case 0x0e: return .comment
            case 0x10: return .dateAdded
            case 0x16: return .playCount
            case 0x17: return .lastPlayed
            case 0x19: return .rating
            case 0x47: return .albumArtist
            default: return nil
            }
        }
    }

    enum StringOp: String, CaseIterable, Equatable {
        case contains, equals, startsWith

        var action: UInt32 {
            switch self {
            case .equals: return 0x0100_0001
            case .contains: return 0x0100_0002
            case .startsWith: return 0x0100_0004
            }
        }

        static func from(action: UInt32) -> StringOp? {
            switch action {
            case 0x0100_0001: return .equals
            case 0x0100_0002: return .contains
            case 0x0100_0004: return .startsWith
            default: return nil
            }
        }
    }

    enum IntOp: String, CaseIterable, Equatable {
        case equals, greater, greaterOrEqual, less, lessOrEqual, inTheLast

        var action: UInt32 {
            switch self {
            case .equals: return 0x0000_0001
            case .greater: return 0x0000_0010
            case .greaterOrEqual: return 0x0000_0020
            case .less: return 0x0000_0040
            case .lessOrEqual: return 0x0000_0080
            case .inTheLast: return 0x0000_0200
            }
        }

        static func from(action: UInt32) -> IntOp? {
            switch action {
            case 0x0000_0001: return .equals
            case 0x0000_0010: return .greater
            case 0x0000_0020: return .greaterOrEqual
            case 0x0000_0040: return .less
            case 0x0000_0080: return .lessOrEqual
            case 0x0000_0200: return .inTheLast
            default: return nil
            }
        }

        static func ops(for field: Field) -> [IntOp] {
            if field.isRelativeDate {
                return [.inTheLast]
            }
            return [.equals, .greater, .greaterOrEqual, .less, .lessOrEqual]
        }
    }

    func matches(_ track: Track, now: Date = Date()) -> Bool {
        if isOpaqueSkip { return true }
        if field.isString {
            let haystack: String
            switch field {
            case .title: haystack = track.title
            case .artist: haystack = track.artist
            case .album: haystack = track.album
            case .albumArtist: haystack = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            case .genre: haystack = track.genre
            case .comment: haystack = track.comment
            default: return false
            }
            let needle = stringValue
            switch stringOp {
            case .contains:
                return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            case .equals:
                return haystack.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            case .startsWith:
                return haystack.lowercased().hasPrefix(needle.lowercased())
            }
        }

        if intOp == .inTheLast, field.isRelativeDate {
            let stamp: UInt32
            switch field {
            case .lastPlayed: stamp = track.lastPlayedMacTime
            case .dateAdded: stamp = track.dateAddedMacTime
            default: return false
            }
            guard stamp > 0, let date = Track.date(fromMacTimestamp: stamp) else { return false }
            let n = max(1, intValue)
            let window = TimeInterval(n) * TimeInterval(timeUnit.seconds)
            return date >= now.addingTimeInterval(-window)
        }

        let value: Int
        switch field {
        case .rating: value = track.starRating
        case .playCount: value = Int(track.playCount)
        case .year: value = Int(track.year)
        case .duration: value = Int(track.durationMs / 1000) // seconds in UI/eval
        case .bitrate: value = Int(track.bitrate)
        default: return false
        }
        switch intOp {
        case .equals: return value == intValue
        case .greater: return value > intValue
        case .greaterOrEqual: return value >= intValue
        case .less: return value < intValue
        case .lessOrEqual: return value <= intValue
        case .inTheLast: return false
        }
    }

    func encode() -> Data {
        if field.isString {
            let units = Array(stringValue.utf16)
            var strBytes = Data(count: units.count * 2)
            for (i, unit) in units.enumerated() {
                strBytes[i * 2] = UInt8((unit >> 8) & 0xff)
                strBytes[i * 2 + 1] = UInt8(unit & 0xff)
            }
            var data = Data(count: 56 + strBytes.count)
            splWriteU32BE(&data, at: 0, field.mhodField)
            splWriteU32BE(&data, at: 4, stringOp.action)
            splWriteU32BE(&data, at: 52, UInt32(strBytes.count))
            if !strBytes.isEmpty {
                data.replaceSubrange(56..<(56 + strBytes.count), with: strBytes)
            }
            return data
        }

        var data = Data(count: 124)
        splWriteU32BE(&data, at: 0, field.mhodField)
        splWriteU32BE(&data, at: 4, intOp.action)
        splWriteU32BE(&data, at: 52, 0x44)

        if intOp == .inTheLast {
            let sentinel: UInt64 = 0x2dae_2dae_2dae_2dae
            splWriteU64BE(&data, at: 56, sentinel)
            splWriteI64BE(&data, at: 64, Int64(-max(1, intValue)))
            splWriteU64BE(&data, at: 72, timeUnit.seconds)
            splWriteU64BE(&data, at: 80, sentinel)
            splWriteI64BE(&data, at: 88, 0)
            splWriteU64BE(&data, at: 96, 1)
            return data
        }

        let stored: UInt64
        switch field {
        case .rating:
            stored = UInt64(max(0, min(5, intValue)) * 20)
        case .duration:
            stored = UInt64(max(0, intValue)) * 1000 // seconds → ms
        default:
            stored = UInt64(max(0, intValue))
        }
        splWriteU64BE(&data, at: 56, stored)
        splWriteU64BE(&data, at: 64, 0)
        splWriteU64BE(&data, at: 72, 1)
        splWriteU64BE(&data, at: 80, stored)
        splWriteU64BE(&data, at: 88, 0)
        splWriteU64BE(&data, at: 96, 1)
        return data
    }

    static func decode(from data: Data, at offset: Int) -> (SmartRule, Int)? {
        guard offset + 56 <= data.count else { return nil }
        let fieldRaw = splReadU32BE(data, offset)
        let action = splReadU32BE(data, offset + 4)
        guard let field = Field.from(mhod: fieldRaw) else { return nil }
        let length = Int(splReadU32BE(data, offset + 52))

        if field.isString {
            guard let op = StringOp.from(action: action) else { return nil }
            guard offset + 56 + length <= data.count, length % 2 == 0 else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(length / 2)
            for i in stride(from: 0, to: length, by: 2) {
                let hi = UInt16(data[offset + 56 + i])
                let lo = UInt16(data[offset + 56 + i + 1])
                units.append((hi << 8) | lo)
            }
            let text = String(utf16CodeUnits: units, count: units.count)
            var rule = SmartRule(field: field, stringOp: op, stringValue: text)
            rule.id = UUID()
            return (rule, 56 + length)
        }

        guard length == 0x44, offset + 56 + 0x44 <= data.count else { return nil }

        if action == 0x0000_0200 {
            let fromDate = splReadI64BE(data, offset + 64)
            let fromUnits = splReadU64BE(data, offset + 72)
            var rule = SmartRule(
                field: field,
                intOp: .inTheLast,
                intValue: max(1, Int(-fromDate)),
                timeUnit: .from(seconds: fromUnits)
            )
            // If units were baked into date (units=1), convert seconds → days/weeks
            if fromUnits == 1 {
                let secs = UInt64(max(1, -fromDate))
                if secs % 604_800 == 0 {
                    rule.timeUnit = .weeks
                    rule.intValue = Int(secs / 604_800)
                } else {
                    rule.timeUnit = .days
                    rule.intValue = max(1, Int(secs / 86_400))
                }
            }
            rule.id = UUID()
            return (rule, 56 + 0x44)
        }

        guard let op = IntOp.from(action: action), op != .inTheLast else { return nil }
        let fromValue = splReadU64BE(data, offset + 56)
        var intValue = Int(fromValue)
        if field == .rating {
            intValue = Int(fromValue) / 20
        } else if field == .duration {
            intValue = Int(fromValue / 1000)
        }
        var rule = SmartRule(field: field, intOp: op, intValue: intValue)
        rule.id = UUID()
        return (rule, 56 + 0x44)
    }

    /// Skip an encoded rule we do not support (unknown field/action).
    static func skipEncodedRule(from data: Data, at offset: Int) -> Int? {
        guard offset + 56 <= data.count else { return nil }
        let length = Int(splReadU32BE(data, offset + 52))
        let total = 56 + length
        guard length >= 0, offset + total <= data.count else { return nil }
        return total
    }
}

struct SmartPlaylistEditDraft: Equatable {
    var playlistID: UInt64?
    var name: String
    var definition: SmartPlaylistDefinition

    static func fresh() -> SmartPlaylistEditDraft {
        SmartPlaylistEditDraft(
            playlistID: nil,
            name: "",
            definition: SmartPlaylistDefinition(
                matchAll: true,
                rules: [SmartRule(field: .artist, stringOp: .contains, stringValue: "")],
                limitEnabled: false,
                limitType: .songs,
                limitCount: 25,
                limitSort: .mostPlayed
            )
        )
    }

    static func editing(_ playlist: Playlist) -> SmartPlaylistEditDraft? {
        guard var def = SmartPlaylistDefinition.decode(from: playlist) else { return nil }
        // Editor works on supported rules only; saving rewrites MHOD 51.
        def.preservedMhod51 = nil
        if def.rules.isEmpty {
            def.rules = [SmartRule(field: .artist, stringOp: .contains, stringValue: "")]
        }
        return SmartPlaylistEditDraft(playlistID: playlist.id, name: playlist.name, definition: def)
    }
}

// MARK: - Binary helpers

private func splMhodType(_ data: Data) -> UInt32 {
    guard data.count >= 16 else { return 0 }
    return splReadU32LE(data, 12)
}

private func splWriteFourCC(_ data: inout Data, at offset: Int, _ value: String) {
    let bytes = Array(value.utf8.prefix(4))
    for i in 0..<4 {
        data[offset + i] = i < bytes.count ? bytes[i] : 0x20
    }
}

private func splWriteU32LE(_ data: inout Data, at offset: Int, _ value: UInt32) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
}

private func splWriteU32BE(_ data: inout Data, at offset: Int, _ value: UInt32) {
    data[offset] = UInt8((value >> 24) & 0xff)
    data[offset + 1] = UInt8((value >> 16) & 0xff)
    data[offset + 2] = UInt8((value >> 8) & 0xff)
    data[offset + 3] = UInt8(value & 0xff)
}

private func splWriteU64BE(_ data: inout Data, at offset: Int, _ value: UInt64) {
    for i in 0..<8 {
        data[offset + i] = UInt8((value >> (8 * (7 - i))) & 0xff)
    }
}

private func splWriteI64BE(_ data: inout Data, at offset: Int, _ value: Int64) {
    splWriteU64BE(&data, at: offset, UInt64(bitPattern: value))
}

private func splReadU32LE(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func splReadU32BE(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
}

private func splReadU64BE(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset + 8 <= data.count else { return 0 }
    var v: UInt64 = 0
    for i in 0..<8 {
        v = (v << 8) | UInt64(data[offset + i])
    }
    return v
}

private func splReadI64BE(_ data: Data, _ offset: Int) -> Int64 {
    Int64(bitPattern: splReadU64BE(data, offset))
}

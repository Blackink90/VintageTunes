import Foundation

/// Legge il file "Play Counts" scritto dall’iPod (delta dall’ultimo sync) e lo fonde nei brani.
enum PlayCountsFile {
    static func url(on device: iPodDevice) -> URL {
        device.iTunesURL.appendingPathComponent("Play Counts")
    }

    /// Applica i delta dell’iPod e, se ha modificato qualcosa, restituisce `true`.
    @discardableResult
    static func merge(into tracks: inout [Track], device: iPodDevice) -> Bool {
        let fileURL = url(on: device)
        guard let data = try? Data(contentsOf: fileURL), data.count >= 16 else { return false }

        let magic = String(bytes: data[0..<4], encoding: .ascii) ?? ""
        guard magic == "mhdp" else { return false }

        let entryLength = Int(readU32(data, 8))
        let entryCount = Int(readU32(data, 12))
        guard entryLength >= 12, entryCount > 0 else { return false }

        var changed = false
        let limit = min(entryCount, tracks.count)

        for i in 0..<limit {
            let offset = 0x60 + i * entryLength
            guard offset + entryLength <= data.count else { break }

            let deltaPlays = readU32(data, offset)
            let lastPlayed = entryLength >= 8 ? readU32(data, offset + 4) : 0
            let ratingRaw = entryLength >= 16 ? readU32(data, offset + 12) : 0

            if deltaPlays > 0 {
                tracks[i].playCount &+= deltaPlays
                changed = true
            }
            if lastPlayed > tracks[i].lastPlayedMacTime {
                tracks[i].lastPlayedMacTime = lastPlayed
                changed = true
            }
            if ratingRaw > 0, ratingRaw <= 100 {
                let rating = UInt8(ratingRaw)
                if tracks[i].rating != rating {
                    tracks[i].rating = rating
                    changed = true
                }
            }
        }

        if changed {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return changed
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

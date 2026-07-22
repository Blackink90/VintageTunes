import Foundation

/// Legge il file "Play Counts" scritto dall’iPod (delta dall’ultimo sync) e lo fonde nei brani.
///
/// L’iPod **non** aggiorna rating/play count nell’iTunesDB: li scrive qui. iTunes/VintageTunes
/// devono fonderli nel DB e poi cancellare il file (come iTunes in autosync).
enum PlayCountsFile {
    static func url(on device: iPodDevice) -> URL {
        device.iTunesURL.appendingPathComponent("Play Counts")
    }

    /// Risultato del merge: `changed` se i brani sono stati aggiornati;
    /// `canRemoveFile` se è sicuro cancellare Play Counts (tutte le entry sono state applicate).
    struct MergeResult: Equatable {
        var changed: Bool
        var canRemoveFile: Bool
    }

    /// Applica i delta dell’iPod. **Non** cancella il file: chiamare `remove` solo dopo
    /// aver persistito le stats nell’iTunesDB, altrimenti si perdono stelle/ascolti.
    @discardableResult
    static func merge(into tracks: inout [Track], device: iPodDevice) -> MergeResult {
        let fileURL = url(on: device)
        guard let data = try? Data(contentsOf: fileURL), data.count >= 16 else {
            return MergeResult(changed: false, canRemoveFile: false)
        }

        let magic = String(bytes: data[0..<4], encoding: .ascii) ?? ""
        guard magic == "mhdp" else {
            return MergeResult(changed: false, canRemoveFile: false)
        }

        let headerLength = Int(readU32(data, 4))
        let entryLength = Int(readU32(data, 8))
        let entryCount = Int(readU32(data, 12))
        guard headerLength >= 16, entryLength >= 12, entryCount > 0, !tracks.isEmpty else {
            return MergeResult(changed: false, canRemoveFile: false)
        }

        // Entry in ordine 1:1 con la mhlt. Se abbiamo aggiunto brani in coda, il prefisso resta valido.
        // Se Play Counts ha più entry del DB, non cancelliamo (stato inconsistente).
        let limit = min(entryCount, tracks.count)
        var changed = false
        for i in 0..<limit {
            let offset = headerLength + i * entryLength
            guard offset + entryLength <= data.count else { break }

            let deltaPlays = readU32(data, offset)
            let lastPlayed = entryLength >= 8 ? readU32(data, offset + 4) : 0
            let hasRating = entryLength >= 16
            let ratingRaw = hasRating ? readU32(data, offset + 12) : UInt32.max

            if deltaPlays > 0 {
                tracks[i].playCount &+= deltaPlays
                changed = true
            }
            if lastPlayed > tracks[i].lastPlayedMacTime {
                tracks[i].lastPlayedMacTime = lastPlayed
                changed = true
            }
            if hasRating, ratingRaw <= 100 {
                let rating = UInt8(ratingRaw)
                if tracks[i].rating != rating {
                    tracks[i].rating = rating
                    changed = true
                }
            }
        }

        return MergeResult(changed: changed, canRemoveFile: entryCount <= tracks.count)
    }

    static func remove(from device: iPodDevice) {
        try? FileManager.default.removeItem(at: url(on: device))
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

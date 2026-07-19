import Foundation

/// Indice SHA-256 dei file sull'iPod, salvato accanto a iTunesDB.
struct TrackHashIndex: Codable, Equatable {
    /// location (path iPod) → sha256
    var byLocation: [String: String] = [:]
    /// sha256 → location (per lookup inverso)
    var byHash: [String: String] = [:]

    mutating func set(location: String, hash: String) {
        if let oldHash = byLocation[location], oldHash != hash {
            byHash.removeValue(forKey: oldHash)
        }
        byLocation[location] = hash
        byHash[hash] = location
    }

    mutating func remove(location: String) {
        if let hash = byLocation.removeValue(forKey: location) {
            if byHash[hash] == location {
                byHash.removeValue(forKey: hash)
            }
        }
    }

    func contains(hash: String) -> Bool {
        byHash[hash] != nil
    }

    static func storeURL(on device: iPodDevice) -> URL {
        device.iTunesURL.appendingPathComponent("VintageTunes-hashes.json")
    }

    static func load(from device: iPodDevice) -> TrackHashIndex {
        let url = storeURL(on: device)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TrackHashIndex.self, from: data) else {
            return TrackHashIndex()
        }
        return decoded
    }

    func save(to device: iPodDevice) throws {
        try FileManager.default.createDirectory(at: device.iTunesURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.storeURL(on: device), options: .atomic)
    }
}

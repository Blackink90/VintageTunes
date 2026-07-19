import Foundation
import AppKit

enum SimulatediPod {
    static let deviceID = "vintagetunes.simulated.ipod"

    static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("SimulatediPod", isDirectory: true)
    }

    /// Creates (or refreshes) a fake iPod 5.5G volume on disk and returns a device handle.
    @discardableResult
    static func prepare(reset: Bool = false) throws -> iPodDevice {
        let fm = FileManager.default
        let root = rootURL

        if reset, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let control = root.appendingPathComponent("iPod_Control", isDirectory: true)
        let music = control.appendingPathComponent("Music", isDirectory: true)
        let itunes = control.appendingPathComponent("iTunes", isDirectory: true)
        let deviceDir = control.appendingPathComponent("Device", isDirectory: true)

        try fm.createDirectory(at: music, withIntermediateDirectories: true)
        try fm.createDirectory(at: itunes, withIntermediateDirectories: true)
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        for i in 0..<50 {
            try fm.createDirectory(
                at: music.appendingPathComponent(String(format: "F%02d", i), isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let sysInfo = """
        ModelNumStr: MA450
        pszSerialNumber: VTDEMO000055
        """
        try sysInfo.write(
            to: deviceDir.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )

        let dbURL = itunes.appendingPathComponent("iTunesDB")
        let needsSeed = !fm.fileExists(atPath: dbURL.path)

        if needsSeed {
            try seedSampleLibrary(musicRoot: music, databaseURL: dbURL)
        }

        return makeDevice(at: root)
    }

    static func makeDevice(at root: URL) -> iPodDevice {
        let used = directorySize(at: root)
        let capacity: Int64 = 80 * 1024 * 1024 * 1024 // 80 GB come un 5.5G
        let available = max(0, capacity - used)
        let hasDB = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("iPod_Control/iTunes/iTunesDB").path
        )

        return iPodDevice(
            id: deviceID,
            name: "iPod Demo 5.5",
            volumeURL: root,
            capacityBytes: capacity,
            availableBytes: available,
            modelHint: "iPod Video 5.5G (80GB) · simulato",
            firmwareMode: .stock,
            hasDatabase: hasDB,
            isSimulated: true
        )
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([rootURL])
    }

    // MARK: - Seed

    private static func seedSampleLibrary(musicRoot: URL, databaseURL: URL) throws {
        let samples: [(title: String, artist: String, album: String, genre: String, seconds: Double, freq: Double)] = [
            ("Click Wheel Blues", "VintageTunes", "Demo Sessions", "Blues", 2.0, 220),
            ("Disk Mode Drive", "VintageTunes", "Demo Sessions", "Electronic", 2.5, 330),
            ("Firewire Sunset", "Analog Hearts", "Portable Memories", "Indie", 3.0, 440),
            ("Shuffle Serenade", "Analog Hearts", "Portable Memories", "Indie", 2.2, 523),
            ("LCD Glow", "Pocket Stereo", "Backlight EP", "Ambient", 2.8, 392)
        ]

        var drafts: [iTunesDBWriter.TrackDraft] = []

        for (index, sample) in samples.enumerated() {
            let trackID = UInt32(1001 + index)
            let folderIndex = Int(trackID % 50)
            let folderName = String(format: "F%02d", folderIndex)
            let filename = String(format: "VT%08X.wav", trackID)
            let dest = musicRoot
                .appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent(filename)

            let wav = makeToneWAV(frequency: sample.freq, durationSeconds: sample.seconds)
            try wav.write(to: dest)

            drafts.append(
                iTunesDBWriter.TrackDraft(
                    id: trackID,
                    title: sample.title,
                    artist: sample.artist,
                    album: sample.album,
                    genre: sample.genre,
                    location: ":iPod_Control:Music:\(folderName):\(filename)",
                    durationMs: UInt32(sample.seconds * 1000),
                    sizeBytes: UInt32(wav.count),
                    trackNumber: UInt32(index + 1),
                    year: 2026,
                    bitrate: 705,
                    sampleRate: 44100,
                    mediaType: 1,
                    filetype: "WAV audio file"
                )
            )
        }

        let trackIDs = drafts.map(\.id)
        let playlists = [
            iTunesDBWriter.PlaylistDraft(id: 1, name: "Libreria", isMaster: true, trackIDs: trackIDs),
            iTunesDBWriter.PlaylistDraft(
                id: 2,
                name: "Demo Favorites",
                isMaster: false,
                trackIDs: Array(trackIDs.prefix(3))
            )
        ]

        try iTunesDBWriter().write(
            tracks: drafts,
            playlists: playlists,
            dbVersion: 0x14,
            to: databaseURL
        )
    }

    /// Minimal mono 16-bit PCM WAV with a sine tone.
    private static func makeToneWAV(frequency: Double, durationSeconds: Double, sampleRate: Int = 44100) -> Data {
        let sampleCount = Int(Double(sampleRate) * durationSeconds)
        var pcm = Data(capacity: sampleCount * 2)
        let amplitude: Double = 0.25 * Double(Int16.max)

        for n in 0..<sampleCount {
            let t = Double(n) / Double(sampleRate)
            // Soft fade in/out to avoid clicks
            let fade = min(1, Double(n) / 1000, Double(sampleCount - n) / 1000)
            let sample = Int16((sin(2 * .pi * frequency * t) * amplitude * fade).rounded())
            pcm.append(UInt8(sample & 0xff))
            pcm.append(UInt8((sample >> 8) & 0xff))
        }

        let dataSize = UInt32(pcm.count)
        let riffSize = dataSize + 36
        var wav = Data()

        func ascii(_ s: String) { wav.append(contentsOf: s.utf8) }
        func le32(_ v: UInt32) {
            wav.append(UInt8(v & 0xff))
            wav.append(UInt8((v >> 8) & 0xff))
            wav.append(UInt8((v >> 16) & 0xff))
            wav.append(UInt8((v >> 24) & 0xff))
        }
        func le16(_ v: UInt16) {
            wav.append(UInt8(v & 0xff))
            wav.append(UInt8((v >> 8) & 0xff))
        }

        ascii("RIFF")
        le32(riffSize)
        ascii("WAVE")
        ascii("fmt ")
        le32(16) // PCM chunk size
        le16(1) // PCM
        le16(1) // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2)) // byte rate
        le16(2) // block align
        le16(16) // bits
        ascii("data")
        le32(dataSize)
        wav.append(pcm)
        return wav
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

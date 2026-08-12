import Foundation
import UniformTypeIdentifiers

enum iPodBackupError: LocalizedError, Equatable {
    case noDevice
    case simulatedDevice
    case cancelled
    case notEnoughSpace(need: Int64, available: Int64)
    case invalidArchive
    case unsupportedVersion(Int)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return L10n.t("error.backup.no_device")
        case .simulatedDevice:
            return L10n.t("error.backup.demo")
        case .cancelled:
            return L10n.t("error.backup.cancelled")
        case .notEnoughSpace(let need, let available):
            let n = ByteCountFormatter.string(fromByteCount: need, countStyle: .file)
            let a = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return L10n.tf("error.backup.not_enough_space", n, a)
        case .invalidArchive:
            return L10n.t("error.backup.invalid_archive")
        case .unsupportedVersion(let v):
            return L10n.tf("error.backup.unsupported_version", v)
        case .failed(let m):
            return m
        }
    }
}

/// Backup totale del volume iPod in un archivio `.vbk` (ZIP + manifest).
enum iPodVolumeBackup {
    static let fileExtension = "vbk"
    static let formatID = "vintagetunes.vbk"
    static let formatVersion = 1

    static var utType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }

    /// Nomi da escludere sempre dal tree (anche nested).
    static let excludedAnywhere: Set<String> = [
        ".Spotlight-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".Trashes",
        ".DocumentRevisions-V100",
        ".VintageTunesBackupStaging",
        ".DS_Store"
    ]

    struct Manifest: Codable, Equatable {
        var format: String
        var version: Int
        var createdAt: String
        var appVersion: String
        var deviceName: String
        var modelHint: String
        var firmwareMode: String
        var capacityBytes: Int64
        var usedBytes: Int64
        var fileCount: Int
        var byteCount: Int64
        var exclusions: [String]
    }

    struct Progress {
        var fraction: Double
        var message: String
    }

    // MARK: - Backup

    static func createBackup(
        device: iPodDevice,
        to destination: URL,
        progress: @escaping @Sendable (Progress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        guard !device.isSimulated else { throw iPodBackupError.simulatedDevice }

        let fm = FileManager.default
        let volume = device.volumeURL.standardizedFileURL
        progress(Progress(fraction: 0.01, message: L10n.t("backup.analyzing")))

        let entries = try collectEntries(from: volume, isCancelled: isCancelled)
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let fileCount = entries.count

        try ensureSpace(forBytes: totalBytes + max(64_000_000, totalBytes / 20), near: destination)

        let stagingRoot = try makeStagingDirectory(near: destination)
        defer { try? fm.removeItem(at: stagingRoot) }

        let volumeRoot = stagingRoot.appendingPathComponent("volume", isDirectory: true)
        try fm.createDirectory(at: volumeRoot, withIntermediateDirectories: true)

        progress(Progress(fraction: 0.03, message: L10n.tf("backup.copying_count", fileCount)))

        var copied: Int64 = 0
        for (index, entry) in entries.enumerated() {
            if isCancelled() { throw iPodBackupError.cancelled }
            let dest = volumeRoot.appendingPathComponent(entry.relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: entry.url, to: dest)
            copied += max(entry.size, 1)
            if index % 8 == 0 || index == entries.count - 1 {
                let frac = 0.03 + 0.72 * (Double(copied) / Double(max(totalBytes, 1)))
                progress(Progress(
                    fraction: min(0.75, frac),
                    message: L10n.tf(
                        "backup.copying_progress",
                        index + 1,
                        fileCount,
                        ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)
                    )
                ))
            }
        }

        let manifest = Manifest(
            format: formatID,
            version: formatVersion,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.0",
            deviceName: device.name,
            modelHint: device.modelHint,
            firmwareMode: device.firmwareMode.rawValue,
            capacityBytes: device.capacityBytes,
            usedBytes: device.usedBytes,
            fileCount: fileCount,
            byteCount: totalBytes,
            exclusions: Array(excludedAnywhere).sorted()
        )
        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try manifestData.write(to: stagingRoot.appendingPathComponent("manifest.json"), options: .atomic)

        if isCancelled() { throw iPodBackupError.cancelled }
        progress(Progress(fraction: 0.78, message: L10n.t("backup.creating_archive")))

        let tempArchive = stagingRoot.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tempArchive) }

        try runDittoArchive(from: stagingRoot, to: tempArchive)
        if isCancelled() { throw iPodBackupError.cancelled }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempArchive, to: destination)
        progress(Progress(fraction: 1, message: L10n.t("backup.completed")))
    }

    // MARK: - Restore

    static func readManifest(from archive: URL) throws -> Manifest {
        let fm = FileManager.default
        let extractRoot = try makeStagingDirectory(near: archive)
        defer { try? fm.removeItem(at: extractRoot) }
        try runDittoExtract(from: archive, to: extractRoot)
        let manifestURL = try findManifest(in: extractRoot)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.format == formatID else { throw iPodBackupError.invalidArchive }
        guard manifest.version <= formatVersion else {
            throw iPodBackupError.unsupportedVersion(manifest.version)
        }
        return manifest
    }

    static func restoreBackup(
        from archive: URL,
        to device: iPodDevice,
        progress: @escaping @Sendable (Progress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        guard !device.isSimulated else { throw iPodBackupError.simulatedDevice }

        let fm = FileManager.default
        let volume = device.volumeURL.standardizedFileURL
        progress(Progress(fraction: 0.02, message: L10n.t("restore.reading_archive")))

        let extractRoot = try makeStagingDirectory(near: archive)
        defer { try? fm.removeItem(at: extractRoot) }

        try runDittoExtract(from: archive, to: extractRoot)
        if isCancelled() { throw iPodBackupError.cancelled }

        let manifestURL = try findManifest(in: extractRoot)
        let manifest = try JSONDecoder().decode(Manifest.self, from: try Data(contentsOf: manifestURL))
        guard manifest.format == formatID else { throw iPodBackupError.invalidArchive }
        guard manifest.version <= formatVersion else {
            throw iPodBackupError.unsupportedVersion(manifest.version)
        }

        let payloadRoot = try findVolumePayload(in: extractRoot)
        progress(Progress(fraction: 0.12, message: L10n.t("restore.wiping")))
        try wipeUserContent(on: volume, isCancelled: isCancelled)

        let restoreEntries = try collectEntries(from: payloadRoot, isCancelled: isCancelled)
        let totalBytes = max(1, restoreEntries.reduce(Int64(0)) { $0 + $1.size })
        var copied: Int64 = 0

        progress(Progress(fraction: 0.18, message: L10n.t("restore.restoring_files")))
        for (index, entry) in restoreEntries.enumerated() {
            if isCancelled() { throw iPodBackupError.cancelled }
            let dest = volume.appendingPathComponent(entry.relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: entry.url, to: dest)
            copied += max(entry.size, 1)
            if index % 8 == 0 || index == restoreEntries.count - 1 {
                let frac = 0.18 + 0.80 * (Double(copied) / Double(totalBytes))
                progress(Progress(
                    fraction: min(0.98, frac),
                    message: L10n.tf(
                        "restore.progress",
                        index + 1,
                        restoreEntries.count,
                        ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)
                    )
                ))
            }
        }

        // Nome volume (Finder / etichetta iPod) salvato nel manifest.
        let restoredName = manifest.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !restoredName.isEmpty {
            if isCancelled() { throw iPodBackupError.cancelled }
            progress(Progress(fraction: 0.99, message: L10n.tf("restore.renaming", restoredName)))
            do {
                var volumeURL = volume
                var values = URLResourceValues()
                values.volumeName = restoredName
                try volumeURL.setResourceValues(values)
            } catch {
                // Best-effort: i file sono già ripristinati; il rename può fallire su alcuni mount.
            }
        }

        progress(Progress(fraction: 1, message: L10n.t("restore.completed")))
    }

    // MARK: - Internals

    private struct Entry {
        var url: URL
        var relativePath: String
        var size: Int64
    }

    private static func collectEntries(
        from root: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> [Entry] {
        let fm = FileManager.default
        var results: [Entry] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw iPodBackupError.failed(L10n.tf("error.backup.list_failed", root.path))
        }

        let rootPath = root.standardizedFileURL.path
        for case let item as URL in enumerator {
            if isCancelled() { throw iPodBackupError.cancelled }
            let name = item.lastPathComponent
            if excludedAnywhere.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // Salta anche percorsi nascosti di sistema sotto root.
            let rel = relativePath(of: item, under: rootPath)
            if rel.split(separator: "/").contains(where: { excludedAnywhere.contains(String($0)) }) {
                enumerator.skipDescendants()
                continue
            }

            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isDirectory == true { continue }
            if values.isSymbolicLink == true {
                // Copia i symlink come file entry (copyItem li preserva).
                results.append(Entry(url: item, relativePath: rel, size: 1))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            results.append(Entry(url: item, relativePath: rel, size: max(size, 0)))
        }
        return results.sorted { $0.relativePath < $1.relativePath }
    }

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath) {
            var rel = String(path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }

    private static func wipeUserContent(
        on volume: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(
            at: volume,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )
        for item in items {
            if isCancelled() { throw iPodBackupError.cancelled }
            let name = item.lastPathComponent
            // Non toccare cartelle di sistema del volume.
            if excludedAnywhere.contains(name) { continue }
            if name.hasPrefix(".") && name != ".rockbox" { continue }
            try fm.removeItem(at: item)
        }
    }

    private static func makeStagingDirectory(near url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let dir = parent.appendingPathComponent(".VintageTunesVBK-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func ensureSpace(forBytes need: Int64, near url: URL) throws {
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let available: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage {
            available = important
        } else if let capacity = values.volumeAvailableCapacity {
            available = Int64(capacity)
        } else {
            available = Int64.max
        }
        if available < need {
            throw iPodBackupError.notEnoughSpace(need: need, available: available)
        }
    }

    private static func runDittoArchive(from sourceDir: URL, to archive: URL) throws {
        // ZIP con resource fork Apple (._*) dove presenti.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sourceDir.path, archive.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: archive.path) else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw iPodBackupError.failed(msg.isEmpty ? L10n.t("error.backup.archive_failed") : msg)
        }
    }

    private static func runDittoExtract(from archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw iPodBackupError.failed(msg.isEmpty ? L10n.t("error.backup.extract_failed") : msg)
        }
    }

    private static func findManifest(in extractRoot: URL) throws -> URL {
        let fm = FileManager.default
        let direct = extractRoot.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: direct.path) { return direct }
        // ditto --keepParent wrappa in una cartella.
        let children = try fm.contentsOfDirectory(at: extractRoot, includingPropertiesForKeys: nil)
        for child in children {
            let candidate = child.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw iPodBackupError.invalidArchive
    }

    private static func findVolumePayload(in extractRoot: URL) throws -> URL {
        let fm = FileManager.default
        let direct = extractRoot.appendingPathComponent("volume", isDirectory: true)
        if fm.fileExists(atPath: direct.path) { return direct }
        let children = try fm.contentsOfDirectory(at: extractRoot, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            let candidate = child.appendingPathComponent("volume", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw iPodBackupError.invalidArchive
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
}

/// Flag cancellazione condiviso tra MainActor e worker backup.
final class BackupCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

struct PendingVolumeRestore: Equatable {
    var archiveURL: URL
    var manifest: iPodVolumeBackup.Manifest

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: manifest.byteCount, countStyle: .file)
        return L10n.tf(
            "restore.summary",
            manifest.deviceName,
            manifest.fileCount,
            size,
            manifest.createdAt,
            manifest.modelHint
        )
    }
}

import Foundation
import AppKit
import Combine

@MainActor
final class iPodDetector: ObservableObject {
    @Published private(set) var devices: [iPodDevice] = []

    private var workspaceObservers: [NSObjectProtocol] = []

    func start() {
        stop()
        scan()

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            },
            nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            },
            nc.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
        ]
    }

    func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    func scan() {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        let found = volumes.compactMap(inspect(volume:))
        devices = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func eject(_ device: iPodDevice) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: device.volumeURL)
        scan()
    }

    /// Rinomina il volume montato (come l’etichetta in Finder / iTunes).
    func rename(_ device: iPodDevice, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RenameError.emptyName
        }
        guard !device.isSimulated else {
            throw RenameError.notApplicable
        }

        var url = device.volumeURL
        var values = URLResourceValues()
        values.volumeName = trimmed
        try url.setResourceValues(values)
        scan()
    }

    enum RenameError: LocalizedError {
        case emptyName
        case notApplicable

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Il nome non può essere vuoto"
            case .notApplicable: return "Rinomina non disponibile per questo dispositivo"
            }
        }
    }

    private func inspect(volume: URL) -> iPodDevice? {
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        var isDir: ObjCBool = false
        let hasControl = FileManager.default.fileExists(atPath: control.path, isDirectory: &isDir) && isDir.boolValue

        // iPod appena ripristinato da Finder: HFS+ “iPod” con partizione firmware, senza iPod_Control.
        if !hasControl {
            guard Self.looksLikeRestoredStockiPod(volume: volume) else { return nil }
            do {
                try Self.initializeStockControl(at: volume)
            } catch {
                return nil
            }
        }

        let values = try? volume.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeUUIDStringKey
        ])

        let name = values?.volumeName ?? volume.lastPathComponent
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        let available = Int64(values?.volumeAvailableCapacity ?? 0)
        let uuid = values?.volumeUUIDString ?? volume.path

        let rockbox = volume.appendingPathComponent(".rockbox", isDirectory: true)
        let hasRockbox = FileManager.default.fileExists(atPath: rockbox.path)
        let dbURL = control.appendingPathComponent("iTunes/iTunesDB")
        let hasDB = FileManager.default.fileExists(atPath: dbURL.path)

        return iPodDevice(
            id: uuid,
            name: name,
            volumeURL: volume,
            capacityBytes: capacity,
            availableBytes: available,
            modelHint: Self.modelHint(for: control),
            firmwareMode: hasRockbox ? .rockbox : .stock,
            hasDatabase: hasDB,
            isSimulated: false
        )
    }

    /// Volume dati di un classic/video ripristinato su Mac (schema Apple + Apple_MDFW).
    private static func looksLikeRestoredStockiPod(volume: URL) -> Bool {
        let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Nome di default post-restore Finder.
        guard name.compare("iPod", options: [.caseInsensitive]) == .orderedSame else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "-plist", volume.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        guard task.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: pipe.fileHandleForReading.readDataToEndOfFile(),
                options: [],
                format: nil
              ) as? [String: Any],
              let parent = plist["ParentWholeDisk"] as? String
        else { return false }

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        list.arguments = ["list", parent]
        let listPipe = Pipe()
        list.standardOutput = listPipe
        list.standardError = Pipe()
        do {
            try list.run()
            list.waitUntilExit()
        } catch {
            return false
        }
        let output = String(data: listPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("Apple_MDFW")
    }

    private static func initializeStockControl(at volume: URL) throws {
        let fm = FileManager.default
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        let music = control.appendingPathComponent("Music", isDirectory: true)
        let itunes = control.appendingPathComponent("iTunes", isDirectory: true)
        let device = control.appendingPathComponent("Device", isDirectory: true)
        let artwork = control.appendingPathComponent("Artwork", isDirectory: true)
        try fm.createDirectory(at: music, withIntermediateDirectories: true)
        try fm.createDirectory(at: itunes, withIntermediateDirectories: true)
        try fm.createDirectory(at: device, withIntermediateDirectories: true)
        try fm.createDirectory(at: artwork, withIntermediateDirectories: true)
        for i in 0..<50 {
            try fm.createDirectory(
                at: music.appendingPathComponent(String(format: "F%02d", i), isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let sysInfoURL = device.appendingPathComponent("SysInfo")
        let sysInfoEmpty: Bool = {
            guard let data = try? Data(contentsOf: sysInfoURL) else { return true }
            return data.isEmpty
        }()
        if sysInfoEmpty {
            let body = """
            ModelNumStr: MA450
            """
            try? body.write(to: sysInfoURL, atomically: true, encoding: .utf8)
        }
    }

    private static func modelHint(for controlURL: URL) -> String {
        let sysInfo = controlURL.appendingPathComponent("Device/SysInfo")
        if let data = try? String(contentsOf: sysInfo, encoding: .utf8), !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = data.split(whereSeparator: \.isNewline)
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                if key.contains("modelnum") || key.contains("model") || key.contains("psz") {
                    return mapModel(parts[1])
                }
            }
        }
        // Prefer Video sizing when SysInfo is missing/empty (common after restore).
        // Do not return a string containing "CLASSIC" — ArtworkDB would pick Classic thumbs.
        return "iPod Video"
    }

    private static func mapModel(_ raw: String) -> String {
        let value = raw.uppercased()
        // Common 5G / 5.5G identifiers
        if value.contains("MA002") || value.contains("MA146") { return "iPod Video 5G (30GB)" }
        if value.contains("MA003") || value.contains("MA147") { return "iPod Video 5G (60GB)" }
        if value.contains("MA477") { return "iPod Video 5.5G (30GB)" }
        if value.contains("MA450") || value.contains("MA448") { return "iPod Video 5.5G (80GB)" }
        if value.contains("MA446") { return "iPod Classic 6G" }
        if value.contains("MB147") || value.contains("MB139") { return "iPod Classic 6.5G / 7G" }
        return raw
    }
}

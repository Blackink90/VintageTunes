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

    private func inspect(volume: URL) -> iPodDevice? {
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: control.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
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

    private static func modelHint(for controlURL: URL) -> String {
        let sysInfo = controlURL.appendingPathComponent("Device/SysInfo")
        guard let data = try? String(contentsOf: sysInfo, encoding: .utf8) else {
            return "iPod Classic / Video"
        }

        let lines = data.split(whereSeparator: \.isNewline)
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if key.contains("modelnum") || key.contains("model") || key.contains("psz") {
                return mapModel(parts[1])
            }
        }
        return "iPod Classic / Video"
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

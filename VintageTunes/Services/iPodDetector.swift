import Foundation
import AppKit
import Combine

@MainActor
final class iPodDetector: ObservableObject {
    @Published private(set) var devices: [iPodDevice] = []

    private var workspaceObservers: [NSObjectProtocol] = []
    /// Volume BSD (es. disk4s2) dopo smontaggio soft — per rimontare senza staccare il cavo.
    private var lastUnmountedVolumeDevice: String?
    private var lastUnmountedWholeDisk: String?

    func start() {
        stop()
        scanMounted()

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scanMounted() }
            },
            nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scanMounted() }
            },
            nc.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scanMounted() }
            }
        ]
    }

    func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    /// Solo volumi già montati (notifiche di sistema).
    func scan() {
        scanMounted()
    }

    /// Cerca dispositivi: rimonta eventuali iPod smontati ma ancora in USB, poi aggiorna la lista.
    func scanAndRemount() {
        remountRememberedOrExternalCandidates()
        scanMounted()
        if !devices.isEmpty { return }

        // Dopo `diskutil eject` l’iPod esce dalla mass storage: non c’è più un BSD da mountDisk.
        // Serve un re-enumerate USB (equivalente a stacca/riattacca) e poi attendere il disco.
        _ = VTReenumerateConnectediPods()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.5)
            remountRememberedOrExternalCandidates()
            scanMounted()
            if !devices.isEmpty { return }
        }
    }

    /// Variante async: non blocca il main thread durante re-enumerate / attesa disco.
    func scanAndRemountAsync() async {
        let rememberedVolume = lastUnmountedVolumeDevice
        let rememberedWhole = lastUnmountedWholeDisk

        scanMounted()
        if !devices.isEmpty { return }

        await Task.detached(priority: .userInitiated) {
            Self.remountWork(
                rememberedVolume: rememberedVolume,
                rememberedWhole: rememberedWhole,
                allowUSBReenumerate: true
            )
        }.value

        scanMounted()
    }

    /// Lavoro diskutil + USB fuori dal main actor.
    nonisolated private static func remountWork(
        rememberedVolume: String?,
        rememberedWhole: String?,
        allowUSBReenumerate: Bool
    ) {
        remountCandidates(volume: rememberedVolume, whole: rememberedWhole)
        if hasMountediPodVolume() { return }

        guard allowUSBReenumerate else { return }
        _ = VTReenumerateConnectediPods()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.5)
            remountCandidates(volume: rememberedVolume, whole: rememberedWhole)
            if hasMountediPodVolume() { return }
        }
    }

    nonisolated private static func hasMountediPodVolume() -> Bool {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes {
            let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: control.path, isDirectory: &isDir), isDir.boolValue {
                return true
            }
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.compare("iPod", options: [.caseInsensitive]) == .orderedSame {
                return true
            }
        }
        return false
    }

    nonisolated private static func remountCandidates(volume: String?, whole: String?) {
        var tried = Set<String>()

        func tryMount(_ bsd: String) -> Bool {
            let id = bsd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !tried.contains(id) else { return false }
            tried.insert(id)
            return runDiskutilStatic(["mount", id]).exitCode == 0
        }

        func tryMountDisk(_ bsd: String) -> Bool {
            let id = bsd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return false }
            for attempt in 0..<4 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                if runDiskutilStatic(["mountDisk", id]).exitCode == 0 { return true }
            }
            return false
        }

        if let whole, tryMountDisk(whole) { return }
        if let volume, tryMount(volume) { return }

        for bsd in unmountedExternalHFVolumesStatic() {
            _ = tryMount(bsd)
        }
        for wholeDisk in externalWholeDisksStatic() where tryMountDisk(wholeDisk) {
            return
        }
    }

    nonisolated private static func runDiskutilStatic(_ arguments: [String]) -> (exitCode: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, Data(), error.localizedDescription)
        }
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, out.fileHandleForReading.readDataToEndOfFile(), stderr)
    }

    nonisolated private static func diskutilInfoPlistStatic(pathOrBSD: String) -> [String: Any]? {
        let result = runDiskutilStatic(["info", "-plist", pathOrBSD])
        guard result.exitCode == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: result.stdout, options: [], format: nil)) as? [String: Any]
    }

    nonisolated private static func externalWholeDisksStatic() -> [String] {
        let result = runDiskutilStatic(["list", "-plist"])
        guard result.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, options: [], format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var wholes: [String] = []
        for disk in disks {
            guard let diskBSD = disk["DeviceIdentifier"] as? String else { continue }
            let info = diskutilInfoPlistStatic(pathOrBSD: diskBSD) ?? [:]
            let internalDisk = (info["Internal"] as? Bool) ?? false
            let ejectable = (info["Ejectable"] as? Bool) ?? false
            let removable = (info["Removable"] as? Bool) ?? (info["RemovableMedia"] as? Bool) ?? false
            guard !internalDisk, ejectable || removable else { continue }
            wholes.append(diskBSD)
        }
        return wholes
    }

    nonisolated private static func unmountedExternalHFVolumesStatic() -> [String] {
        let result = runDiskutilStatic(["list", "-plist"])
        guard result.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, options: [], format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var candidates: [String] = []
        for disk in disks {
            guard let diskBSD = disk["DeviceIdentifier"] as? String else { continue }
            let info = diskutilInfoPlistStatic(pathOrBSD: diskBSD) ?? [:]
            let internalDisk = (info["Internal"] as? Bool) ?? false
            let ejectable = (info["Ejectable"] as? Bool) ?? false
            let removable = (info["Removable"] as? Bool) ?? (info["RemovableMedia"] as? Bool) ?? false
            guard !internalDisk, ejectable || removable else { continue }

            let partitions = disk["Partitions"] as? [[String: Any]] ?? []
            for part in partitions {
                let content = (part["Content"] as? String ?? "").uppercased()
                let mountPoint = part["MountPoint"] as? String ?? ""
                guard mountPoint.isEmpty else { continue }
                let looksHFS = content.contains("HFS") || content.contains("48465300")
                if looksHFS, let id = part["DeviceIdentifier"] as? String {
                    candidates.append(id)
                }
            }

            if let content = disk["Content"] as? String,
               content.uppercased().contains("HFS"),
               (disk["MountPoint"] as? String ?? "").isEmpty {
                candidates.append(diskBSD)
            }
        }
        return candidates
    }

    private func scanMounted() {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        let found = volumes.compactMap(inspect(volume:))
        devices = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !found.isEmpty {
            lastUnmountedVolumeDevice = nil
            lastUnmountedWholeDisk = nil
        }
    }

    /// Espelle il disco (l’iPod esce da «Non scollegare» e torna utilizzabile).
    /// Il cavo resta collegato: «Cerca dispositivi» prova a rimontarlo con mountDisk.
    func eject(_ device: iPodDevice) throws {
        if device.isSimulated {
            scanMounted()
            return
        }

        if let info = diskutilInfoPlist(pathOrBSD: device.volumeURL.path) {
            lastUnmountedVolumeDevice = info["DeviceIdentifier"] as? String
            lastUnmountedWholeDisk = info["ParentWholeDisk"] as? String
            if lastUnmountedWholeDisk == nil,
               let devid = lastUnmountedVolumeDevice,
               let sRange = devid.range(of: #"^disk\d+"#, options: .regularExpression) {
                lastUnmountedWholeDisk = String(devid[sRange])
            }
        }

        try ejectDiskKeepingUSBAttached(volumeURL: device.volumeURL)
        scanMounted()
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
        scanMounted()
    }

    enum RenameError: LocalizedError {
        case emptyName
        case notApplicable

        var errorDescription: String? {
            switch self {
            case .emptyName: return L10n.t("error.rename.empty_name")
            case .notApplicable: return L10n.t("error.rename.not_applicable")
            }
        }
    }

    enum EjectError: LocalizedError {
        case unmountFailed(String)

        var errorDescription: String? {
            switch self {
            case .unmountFailed(let m): return m.isEmpty ? L10n.t("error.eject.failed") : m
            }
        }
    }

    // MARK: - Mount / unmount

    /// Serve `eject` sul whole disk: solo `unmount` lascia l’iPod su «Non scollegare».
    private func ejectDiskKeepingUSBAttached(volumeURL: URL) throws {
        let whole = lastUnmountedWholeDisk
        let targets: [String] = {
            var list: [String] = []
            if let whole, !whole.isEmpty { list.append(whole) }
            if let vol = lastUnmountedVolumeDevice, !vol.isEmpty { list.append(vol) }
            list.append(volumeURL.path)
            return list
        }()

        var lastErr = ""
        for target in targets {
            // eject = SCSI eject → l’iPod esce dalla modalità disco.
            let status = runDiskutil(["eject", target])
            if status.exitCode == 0 {
                // Lascia al firmware un attimo per lasciare disk mode.
                Thread.sleep(forTimeInterval: 0.6)
                return
            }
            lastErr = status.stderr
        }

        // Ultimo fallback: API Finder (eject completo).
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            Thread.sleep(forTimeInterval: 0.6)
        } catch {
            throw EjectError.unmountFailed(lastErr.isEmpty ? error.localizedDescription : lastErr)
        }
    }

    private func remountRememberedOrExternalCandidates() {
        Self.remountCandidates(volume: lastUnmountedVolumeDevice, whole: lastUnmountedWholeDisk)
    }

    private func diskutilInfoPlist(pathOrBSD: String) -> [String: Any]? {
        let result = runDiskutil(["info", "-plist", pathOrBSD])
        guard result.exitCode == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: result.stdout, options: [], format: nil)) as? [String: Any]
    }

    @discardableResult
    private func runDiskutil(_ arguments: [String]) -> (exitCode: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, Data(), error.localizedDescription)
        }
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, out.fileHandleForReading.readDataToEndOfFile(), stderr)
    }

    private func inspect(volume: URL) -> iPodDevice? {
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        var isDir: ObjCBool = false
        let hasControl = FileManager.default.fileExists(atPath: control.path, isDirectory: &isDir) && isDir.boolValue

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

    private static func looksLikeRestoredStockiPod(volume: URL) -> Bool {
        let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard name.compare("iPod", options: [.caseInsensitive]) == .orderedSame else { return false }

        let cacheKey = "VTRestorediPod:" + (volume.path as NSString).standardizingPath
        if UserDefaults.standard.object(forKey: cacheKey) != nil {
            return UserDefaults.standard.bool(forKey: cacheKey)
        }

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
        let ok = output.contains("Apple_MDFW")
        UserDefaults.standard.set(ok, forKey: cacheKey)
        return ok
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
        switch sniffArtworkFamily(controlURL: controlURL) {
        case .nano2: return "iPod nano 2G"
        case .video: return "iPod Video"
        case .classic: return "iPod Classic"
        case .unknown:
            return "iPod Video"
        }
    }

    private enum ArtworkFamilyHint {
        case nano2, video, classic, unknown
    }

    private static func sniffArtworkFamily(controlURL: URL) -> ArtworkFamilyHint {
        let artwork = controlURL.appendingPathComponent("Artwork", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: artwork, includingPropertiesForKeys: nil) else {
            return .unknown
        }
        let names = Set(files.map { $0.lastPathComponent.uppercased() })
        let hasNano = names.contains(where: { $0.hasPrefix("F1027_") || $0.hasPrefix("F1031_") })
        let hasVideo = names.contains(where: { $0.hasPrefix("F1028_") || $0.hasPrefix("F1029_") })
        let hasClassic = names.contains(where: {
            $0.hasPrefix("F1061_") || $0.hasPrefix("F1055_") || $0.hasPrefix("F1060_")
        })
        if hasClassic, !hasVideo, !hasNano { return .classic }
        if hasNano { return .nano2 }
        if hasVideo { return .video }
        return .unknown
    }

    private static func mapModel(_ raw: String) -> String {
        let value = raw.uppercased()
        if value.contains("MA002") || value.contains("MA146") { return "iPod Video 5G (30GB)" }
        if value.contains("MA003") || value.contains("MA147") { return "iPod Video 5G (60GB)" }
        if value.contains("MA477") { return "iPod Video 5.5G (30GB)" }
        if value.contains("MA450") || value.contains("MA448") { return "iPod Video 5.5G (80GB)" }
        if value.contains("MA446") { return "iPod Classic 6G" }
        if value.contains("MB147") || value.contains("MB139") { return "iPod Classic 6.5G / 7G" }
        if value.contains("MA004") || value.contains("MA005") || value.contains("MA099")
            || value.contains("MA107") || value.contains("MA350") || value.contains("MA352") {
            return "iPod nano 2G"
        }
        if value.contains("NANO") { return "iPod nano 2G" }
        return raw
    }
}

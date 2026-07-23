import AppKit
import Foundation

/// Device-side album art (ArtworkDB + .ithmb), matching Music.app for Video, Classic & nano 2G.
enum ArtworkDBError: LocalizedError {
    case unsupportedDevice
    case invalidImage
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice: return "Artwork sul dispositivo non supportato per questo modello."
        case .invalidImage: return "Immagine cover non valida."
        case .writeFailed(let m): return "Scrittura ArtworkDB fallita: \(m)"
        }
    }
}

struct ArtworkThumbFormat: Equatable {
    let correlationID: UInt32
    let width: Int
    let height: Int

    var slotBytes: Int { width * height * 2 }
    var ithmbName: String { String(format: "F%04d_1.ithmb", correlationID) }
    /// Music.app / Video 5.5G use `:F1028_1.ithmb` (no `Artwork:` prefix).
    var ithmbPath: String { ":\(ithmbName)" }
}

enum ArtworkDeviceProfile: Equatable {
    /// iPod Video 5G / 5.5G — RGB565 non-sparse.
    case video5G
    /// iPod Classic 6G/6.5G/7G — RGB565 (libgpod tables).
    case classic
    /// iPod nano 1G / 2G — RGB565 (F1027 / F1031).
    case nano2

    var formats: [ArtworkThumbFormat] {
        switch self {
        case .video5G:
            return [
                ArtworkThumbFormat(correlationID: 1028, width: 100, height: 100),
                ArtworkThumbFormat(correlationID: 1029, width: 200, height: 200)
            ]
        case .classic:
            return [
                ArtworkThumbFormat(correlationID: 1061, width: 56, height: 56),
                ArtworkThumbFormat(correlationID: 1055, width: 128, height: 128),
                ArtworkThumbFormat(correlationID: 1060, width: 320, height: 320)
            ]
        case .nano2:
            return [
                ArtworkThumbFormat(correlationID: 1027, width: 100, height: 100),
                ArtworkThumbFormat(correlationID: 1031, width: 42, height: 42)
            ]
        }
    }

    var correlationIDs: Set<UInt32> { Set(formats.map(\.correlationID)) }

    static func detect(for device: iPodDevice) -> ArtworkDeviceProfile? {
        if device.firmwareMode == .rockbox { return nil }
        let hint = device.modelHint.uppercased()
        // Only explicit Classic model ids / names — never the ambiguous "Classic / Video" fallback.
        if hint.contains("MB147") || hint.contains("MB139") || hint.contains("MA446") {
            return .classic
        }
        if hint.contains("CLASSIC"), !hint.contains("VIDEO") {
            return .classic
        }
        // Nano 1G/2G prima del fallback Video (SysInfo spesso vuoto).
        if hint.contains("NANO") {
            return .nano2
        }
        // Video 5G/5.5G e unknown stock → Video sizes (MA450 etc.).
        return .video5G
    }
}

struct ArtworkThumbRef: Equatable {
    var correlationID: UInt32
    var offset: UInt32
    var size: UInt32
    var width: UInt16
    var height: UInt16
}

struct ArtworkImageEntry: Equatable {
    var id: UInt32
    var songDBID: UInt64
    var sourceImageBytes: UInt32
    var thumbs: [ArtworkThumbRef]
}

/// Loads, appends, and writes `iPod_Control/Artwork/ArtworkDB` + `.ithmb` files.
final class ArtworkDBStore {
    private(set) var profile: ArtworkDeviceProfile
    private(set) var images: [ArtworkImageEntry] = []
    /// True when on-disk ArtworkDB/ithmb do not match this device profile (need full rewrite).
    private(set) var needsRebuild = false
    private var nextImageID: UInt32 = 0x64
    private let artworkDir: URL

    init(device: iPodDevice, profile: ArtworkDeviceProfile) {
        self.profile = profile
        self.artworkDir = device.controlURL.appendingPathComponent("Artwork", isDirectory: true)
    }

    var databaseURL: URL { artworkDir.appendingPathComponent("ArtworkDB") }

    static func open(for device: iPodDevice) throws -> ArtworkDBStore? {
        guard let profile = ArtworkDeviceProfile.detect(for: device) else { return nil }
        // Seed SysInfo solo per Video: mai MA450 su un nano (rompe le cover).
        if profile == .video5G {
            Self.ensureModelHintInSysInfo(for: device)
        }
        let store = ArtworkDBStore(device: device, profile: profile)
        try FileManager.default.createDirectory(at: store.artworkDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: store.databaseURL.path) {
            try store.load()
            store.evaluateCompatibility()
        } else {
            store.ensureEmptyIthmbFiles()
            store.needsRebuild = false
        }
        return store
    }

    /// After a restore SysInfo is often empty; seed ModelNumStr so future scans stay on Video formats.
    /// Chiamare solo per profilo `.video5G`.
    private static func ensureModelHintInSysInfo(for device: iPodDevice) {
        let sysInfo = device.controlURL.appendingPathComponent("Device/SysInfo")
        let existing = (try? String(contentsOf: sysInfo, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existing.isEmpty else { return }
        let model: String
        let gb = Double(device.capacityBytes) / 1_000_000_000
        if gb >= 70 { model = "MA450" }
        else if gb >= 50 { model = "MA003" }
        else { model = "MA477" }
        try? "ModelNumStr: \(model)\n".write(to: sysInfo, atomically: true, encoding: .utf8)
    }

    /// Wipe image list + ithmb payloads so covers can be rewritten in the correct format.
    func beginRebuild() {
        images.removeAll()
        nextImageID = 0x64
        needsRebuild = false
        let fm = FileManager.default
        // Remove thumbnails that do not belong to this profile (e.g. Classic files on Video).
        if let files = try? fm.contentsOfDirectory(at: artworkDir, includingPropertiesForKeys: nil) {
            let keep = Set(profile.formats.map(\.ithmbName) + ["ArtworkDB"])
            for url in files where url.lastPathComponent.hasPrefix("F") && url.pathExtension.lowercased() == "ithmb" {
                if !keep.contains(url.lastPathComponent) {
                    try? fm.removeItem(at: url)
                }
            }
        }
        for format in profile.formats {
            let url = artworkDir.appendingPathComponent(format.ithmbName)
            fm.createFile(atPath: url.path, contents: Data(), attributes: nil)
        }
    }

    /// Append cover art for a track. Returns mhii id to store in `Track.mhiiLink`.
    @discardableResult
    func addArtwork(imageData: Data, songDBID: UInt64) throws -> UInt32 {
        try setArtwork(imageData: imageData, songDBID: songDBID, existingMhiiLink: 0)
    }

    /// Imposta/sostituisce la cover di un brano. Se esiste già un mhii per lo stesso `songDBID`
    /// (o `existingMhiiLink`), sovrascrive i pixel negli slot `.ithmb` e riusa lo stesso id —
    /// così l’iPod non resta agganciato alle thumb vecchie.
    @discardableResult
    func setArtwork(imageData: Data, songDBID: UInt64, existingMhiiLink: UInt32 = 0) throws -> UInt32 {
        guard let nsImage = NSImage(data: imageData) else { throw ArtworkDBError.invalidImage }

        // Preferisci entry già collegata, altrimenti per songDBID.
        let existingIndex = images.firstIndex(where: { $0.id == existingMhiiLink && existingMhiiLink != 0 })
            ?? images.firstIndex(where: { $0.songDBID == songDBID && songDBID != 0 })

        if let existingIndex {
            var entry = images[existingIndex]
            var thumbs: [ArtworkThumbRef] = []
            for format in profile.formats {
                let slot = try Self.preparedRGB565Slot(from: nsImage, format: format)
                let fileURL = artworkDir.appendingPathComponent(format.ithmbName)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
                }

                let offset: UInt32
                if let old = entry.thumbs.first(where: { $0.correlationID == format.correlationID }),
                   old.size >= UInt32(format.slotBytes) {
                    offset = old.offset
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: slot)
                    try handle.synchronize()
                } else {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    offset = UInt32(handle.offsetInFile)
                    try handle.write(contentsOf: slot)
                    try handle.synchronize()
                }

                thumbs.append(
                    ArtworkThumbRef(
                        correlationID: format.correlationID,
                        offset: offset,
                        size: UInt32(format.slotBytes),
                        width: UInt16(format.width),
                        height: UInt16(format.height)
                    )
                )
            }
            entry.songDBID = songDBID
            entry.sourceImageBytes = UInt32(clamping: imageData.count)
            entry.thumbs = thumbs
            images[existingIndex] = entry

            // Elimina duplicati orfani (aggiunte precedenti per lo stesso brano).
            images.removeAll { $0.songDBID == songDBID && $0.id != entry.id }
            return entry.id
        }

        var thumbs: [ArtworkThumbRef] = []
        for format in profile.formats {
            let slot = try Self.preparedRGB565Slot(from: nsImage, format: format)
            let fileURL = artworkDir.appendingPathComponent(format.ithmbName)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let offset = UInt32(handle.offsetInFile)
            try handle.write(contentsOf: slot)
            try handle.synchronize()
            thumbs.append(
                ArtworkThumbRef(
                    correlationID: format.correlationID,
                    offset: offset,
                    size: UInt32(format.slotBytes),
                    width: UInt16(format.width),
                    height: UInt16(format.height)
                )
            )
        }

        let id = nextImageID
        nextImageID += 1
        images.append(
            ArtworkImageEntry(
                id: id,
                songDBID: songDBID,
                sourceImageBytes: UInt32(clamping: imageData.count),
                thumbs: thumbs
            )
        )
        return id
    }

    private static func preparedRGB565Slot(from image: NSImage, format: ArtworkThumbFormat) throws -> Data {
        let pixels = try rgb565LE(from: image, width: format.width, height: format.height)
        var slot = pixels
        if slot.count < format.slotBytes {
            slot.append(Data(count: format.slotBytes - slot.count))
        } else if slot.count > format.slotBytes {
            slot = Data(slot.prefix(format.slotBytes))
        }
        return slot
    }

    func save() throws {
        let data = buildDatabase()
        let tmp = databaseURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        try FileManager.default.moveItem(at: tmp, to: databaseURL)
        if let dir = try? FileHandle(forWritingTo: artworkDir) {
            try? dir.synchronize()
            try? dir.close()
        }
        needsRebuild = false
    }

    // MARK: - Load

    private func load() throws {
        let data = try Data(contentsOf: databaseURL)
        guard data.count >= 12, String(bytes: data[0..<4], encoding: .ascii) == "mhfd" else {
            throw ArtworkDBError.writeFailed("ArtworkDB non valido")
        }
        nextImageID = max(readU32(data, 28), 0x64)
        images.removeAll()

        var offset = Int(readU32(data, 4))
        let end = min(Int(readU32(data, 8)), data.count)
        var seenFileFormats = Set<UInt32>()
        while offset + 12 <= end {
            let magic = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let headerLen = Int(readU32(data, offset + 4))
            let total = Int(readU32(data, offset + 8))
            guard total >= 12, offset + total <= data.count else { break }
            if magic == "mhsd" {
                let type = readU32(data, offset + 12)
                let contentStart = offset + headerLen
                let contentEnd = offset + total
                if type == 1 {
                    parseImageList(data, start: contentStart, end: contentEnd)
                } else if type == 3 {
                    seenFileFormats.formUnion(parseFileListIDs(data, start: contentStart, end: contentEnd))
                }
                // Music.app uses mhsd header length 0x60; short headers are from older VT builds.
                if headerLen < 0x60 {
                    needsRebuild = true
                }
            }
            offset += total
        }
        if let maxID = images.map(\.id).max() {
            nextImageID = max(nextImageID, maxID &+ 1)
        }
        if !seenFileFormats.isEmpty, seenFileFormats != profile.correlationIDs {
            needsRebuild = true
        }
        ensureEmptyIthmbFiles()
    }

    private func evaluateCompatibility() {
        let allowed = profile.correlationIDs
        for image in images {
            for thumb in image.thumbs where !allowed.contains(thumb.correlationID) {
                needsRebuild = true
                return
            }
        }
    }

    private func parseImageList(_ data: Data, start: Int, end: Int) {
        guard start + 12 <= end, String(bytes: data[start..<(start + 4)], encoding: .ascii) == "mhli" else { return }
        var offset = start + Int(readU32(data, start + 4))
        while offset + 12 <= end {
            let magic = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            guard magic == "mhii" else { break }
            let headerLen = Int(readU32(data, offset + 4))
            let total = Int(readU32(data, offset + 8))
            guard total >= headerLen, offset + total <= data.count else { break }

            let id = readU32(data, offset + 16)
            let songDBID = readU64(data, offset + 20)
            let sourceBytes = headerLen > 52 ? readU32(data, offset + 48) : 0
            var thumbs: [ArtworkThumbRef] = []

            var child = offset + headerLen
            let childEnd = offset + total
            while child + 16 <= childEnd {
                let cm = String(bytes: data[child..<(child + 4)], encoding: .ascii) ?? ""
                let cTotal = Int(readU32(data, child + 8))
                guard cTotal >= 12, child + cTotal <= data.count else { break }
                if cm == "mhod", readU16(data, child + 12) == 2 {
                    let mhniOffset = child + Int(readU32(data, child + 4))
                    if mhniOffset + 0x4c <= child + cTotal,
                       String(bytes: data[mhniOffset..<(mhniOffset + 4)], encoding: .ascii) == "mhni" {
                        thumbs.append(
                            ArtworkThumbRef(
                                correlationID: readU32(data, mhniOffset + 16),
                                offset: readU32(data, mhniOffset + 20),
                                size: readU32(data, mhniOffset + 24),
                                width: readU16(data, mhniOffset + 34),
                                height: readU16(data, mhniOffset + 32)
                            )
                        )
                    }
                }
                child += cTotal
            }

            images.append(
                ArtworkImageEntry(
                    id: id,
                    songDBID: songDBID,
                    sourceImageBytes: sourceBytes,
                    thumbs: thumbs
                )
            )
            offset += total
        }
    }

    private func parseFileListIDs(_ data: Data, start: Int, end: Int) -> Set<UInt32> {
        guard start + 12 <= end, String(bytes: data[start..<(start + 4)], encoding: .ascii) == "mhlf" else {
            return []
        }
        var ids = Set<UInt32>()
        var offset = start + Int(readU32(data, start + 4))
        while offset + 20 <= end {
            let magic = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            guard magic == "mhif" else { break }
            let total = Int(readU32(data, offset + 8))
            guard total >= 20, offset + total <= data.count else { break }
            ids.insert(readU32(data, offset + 16))
            offset += total
        }
        return ids
    }

    private func ensureEmptyIthmbFiles() {
        let fm = FileManager.default
        for format in profile.formats {
            let url = artworkDir.appendingPathComponent(format.ithmbName)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: Data(), attributes: nil)
            }
        }
    }

    // MARK: - Build ArtworkDB (Music.app / Video 5.5G layout)

    private func buildDatabase() -> Data {
        let imageList = buildImageList()
        let albumList = buildEmptyAlbumList()
        let fileList = buildFileList()

        let ds1 = wrapMHSD(type: 1, child: imageList)
        let ds2 = wrapMHSD(type: 2, child: albumList)
        let ds3 = wrapMHSD(type: 3, child: fileList)

        var body = Data()
        body.append(ds1)
        body.append(ds2)
        body.append(ds3)

        let headerLen = 0x84
        var file = Data(count: headerLen)
        writeFourCC(&file, at: 0, "mhfd")
        writeU32(&file, at: 4, UInt32(headerLen))
        writeU32(&file, at: 8, UInt32(headerLen + body.count))
        writeU32(&file, at: 16, 6) // Music.app on Video 5.5G
        writeU32(&file, at: 20, 3) // child mhsd count
        writeU32(&file, at: 28, nextImageID)
        file.append(body)
        writeU32(&file, at: 8, UInt32(file.count))
        return file
    }

    private func wrapMHSD(type: UInt32, child: Data) -> Data {
        // Music.app uses 0x60-byte mhsd headers (not the minimal 0x10).
        let headerLen = 0x60
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhsd")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(headerLen + child.count))
        writeU32(&data, at: 12, type)
        data.append(child)
        return data
    }

    private func buildImageList() -> Data {
        var children = Data()
        for image in images {
            children.append(buildMHII(image))
        }
        let headerLen = 0x5c
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhli")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(images.count))
        data.append(children)
        return data
    }

    private func buildEmptyAlbumList() -> Data {
        let headerLen = 0x5c
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhla")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, 0)
        return data
    }

    private func buildFileList() -> Data {
        var children = Data()
        for format in profile.formats {
            children.append(buildMHIF(format))
        }
        let headerLen = 0x5c
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhlf")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(profile.formats.count))
        data.append(children)
        return data
    }

    private func buildMHIF(_ format: ArtworkThumbFormat) -> Data {
        let headerLen = 0x7c
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhif")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(headerLen))
        writeU32(&data, at: 16, format.correlationID)
        writeU32(&data, at: 20, UInt32(format.slotBytes))
        return data
    }

    private func buildMHII(_ image: ArtworkImageEntry) -> Data {
        var children = Data()
        for thumb in image.thumbs {
            children.append(buildThumbnailMHOD(thumb))
        }
        children.append(buildEmptyMHAF())

        let headerLen = 0x98
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhii")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + children.count))
        writeU32(&header, at: 12, UInt32(image.thumbs.count + 1)) // thumbs + mhaf
        writeU32(&header, at: 16, image.id)
        writeU64(&header, at: 20, image.songDBID)
        writeU32(&header, at: 48, image.sourceImageBytes)
        writeU32(&header, at: 56, 1)
        writeU32(&header, at: 60, 1)
        // Music.app writes quiet-NaN floats here (likely unused colour averages).
        writeU32(&header, at: 76, 0x7FF8_0000)
        writeU32(&header, at: 84, 0x7FF8_0000)
        header.append(children)
        return header
    }

    private func buildThumbnailMHOD(_ thumb: ArtworkThumbRef) -> Data {
        let mhni = buildMHNI(thumb)
        let headerLen = 0x18
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(headerLen + mhni.count))
        writeU16(&data, at: 12, 2) // container
        data.append(mhni)
        return data
    }

    private func buildMHNI(_ thumb: ArtworkThumbRef) -> Data {
        let pathMHOD = buildArtworkStringMHOD(type: 3, string: String(format: ":F%04d_1.ithmb", thumb.correlationID))
        let headerLen = 0x4c
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhni")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + pathMHOD.count))
        writeU32(&header, at: 12, 1)
        writeU32(&header, at: 16, thumb.correlationID)
        writeU32(&header, at: 20, thumb.offset)
        writeU32(&header, at: 24, thumb.size)
        writeU16(&header, at: 32, thumb.height)
        writeU16(&header, at: 34, thumb.width)
        writeU32(&header, at: 40, thumb.size)
        header.append(pathMHOD)
        return header
    }

    /// Empty album-face payload required by Music.app (mhod type 6 → mhaf).
    private func buildEmptyMHAF() -> Data {
        let mhafLen = 0x60
        var mhaf = Data(count: mhafLen)
        writeFourCC(&mhaf, at: 0, "mhaf")
        writeU32(&mhaf, at: 4, UInt32(mhafLen))
        writeU32(&mhaf, at: 8, 0x3c)

        let headerLen = 0x18
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(headerLen + mhaf.count))
        writeU16(&data, at: 12, 6)
        data.append(mhaf)
        return data
    }

    private func buildArtworkStringMHOD(type: UInt16, string: String) -> Data {
        var stringBytes = Data()
        for unit in string.utf16 {
            appendU16(&stringBytes, unit)
        }
        // Layout matches Music.app ArtworkDB strings: length@0x18, encoding@0x1c, payload@0x24.
        let total = 0x24 + stringBytes.count
        var data = Data(count: total)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, 0x18)
        writeU32(&data, at: 8, UInt32(total))
        writeU16(&data, at: 12, type)
        writeU32(&data, at: 0x18, UInt32(stringBytes.count))
        writeU32(&data, at: 0x1c, 2) // UTF-16LE
        data.replaceSubrange(0x24..<(0x24 + stringBytes.count), with: stringBytes)
        return data
    }

    // MARK: - RGB565

    static func rgb565LE(from image: NSImage, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0 else { throw ArtworkDBError.invalidImage }
        let size = NSSize(width: width, height: height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { throw ArtworkDBError.invalidImage }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            let src = image.size
            let scale = min(CGFloat(width) / max(src.width, 1), CGFloat(height) / max(src.height, 1))
            let drawW = src.width * scale
            let drawH = src.height * scale
            let rect = NSRect(
                x: (CGFloat(width) - drawW) / 2,
                y: (CGFloat(height) - drawH) / 2,
                width: drawW,
                height: drawH
            )
            NSColor.black.setFill()
            NSBezierPath.fill(NSRect(origin: .zero, size: size))
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let ptr = rep.bitmapData else { throw ArtworkDBError.invalidImage }
        var out = Data(capacity: width * height * 2)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(ptr[i])
                let g = Int(ptr[i + 1])
                let b = Int(ptr[i + 2])
                let pixel = UInt16(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))
                out.append(UInt8(pixel & 0xff))
                out.append(UInt8((pixel >> 8) & 0xff))
            }
        }
        return out
    }

    // MARK: - Binary helpers

    private func writeFourCC(_ data: inout Data, at offset: Int, _ value: String) {
        let chars = Array(value.utf8.prefix(4))
        for (i, b) in chars.enumerated() { data[offset + i] = b }
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

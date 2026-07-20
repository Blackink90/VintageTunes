import AppKit
import Foundation

/// Device-side album art (ArtworkDB + .ithmb), matching iTunes / libgpod for Video & Classic.
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
    var ithmbPath: String { ":Artwork:\(ithmbName)" }
}

enum ArtworkDeviceProfile: Equatable {
    /// iPod Video 5G / 5.5G — RGB565 non-sparse.
    case video5G
    /// iPod Classic 6G/6.5G/7G — RGB565 (libgpod tables).
    case classic

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
        }
    }

    static func detect(for device: iPodDevice) -> ArtworkDeviceProfile? {
        if device.firmwareMode == .rockbox { return nil }
        let hint = device.modelHint.uppercased()
        if hint.contains("CLASSIC") || hint.contains("MB147") || hint.contains("MB139") || hint.contains("MA446") {
            return .classic
        }
        // Video 5G/5.5G and unknown stock → Video sizes (simulated iPod is MA450 Video).
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
    var thumbs: [ArtworkThumbRef]
}

/// Loads, appends, and writes `iPod_Control/Artwork/ArtworkDB` + `.ithmb` files.
final class ArtworkDBStore {
    private(set) var profile: ArtworkDeviceProfile
    private(set) var images: [ArtworkImageEntry] = []
    private var nextImageID: UInt32 = 0x40
    private let artworkDir: URL

    init(device: iPodDevice, profile: ArtworkDeviceProfile) {
        self.profile = profile
        self.artworkDir = device.controlURL.appendingPathComponent("Artwork", isDirectory: true)
    }

    var databaseURL: URL { artworkDir.appendingPathComponent("ArtworkDB") }

    static func open(for device: iPodDevice) throws -> ArtworkDBStore? {
        guard let profile = ArtworkDeviceProfile.detect(for: device) else { return nil }
        let store = ArtworkDBStore(device: device, profile: profile)
        try FileManager.default.createDirectory(at: store.artworkDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: store.databaseURL.path) {
            try store.load()
        } else {
            store.ensureEmptyIthmbFiles()
        }
        return store
    }

    /// Append cover art for a track. Returns mhii id to store in `Track.mhiiLink`.
    @discardableResult
    func addArtwork(imageData: Data, songDBID: UInt64) throws -> UInt32 {
        guard let nsImage = NSImage(data: imageData) else { throw ArtworkDBError.invalidImage }

        var thumbs: [ArtworkThumbRef] = []
        for format in profile.formats {
            let pixels = try Self.rgb565LE(from: nsImage, width: format.width, height: format.height)
            var slot = pixels
            if slot.count < format.slotBytes {
                slot.append(Data(count: format.slotBytes - slot.count))
            } else if slot.count > format.slotBytes {
                slot = Data(slot.prefix(format.slotBytes))
            }
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
        images.append(ArtworkImageEntry(id: id, songDBID: songDBID, thumbs: thumbs))
        return id
    }

    func save() throws {
        let data = buildDatabase()
        let tmp = databaseURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        try FileManager.default.moveItem(at: tmp, to: databaseURL)
        // Best-effort flush of directory entries on FAT32.
        if let dir = try? FileHandle(forWritingTo: artworkDir) {
            try? dir.synchronize()
            try? dir.close()
        }
    }

    // MARK: - Load

    private func load() throws {
        let data = try Data(contentsOf: databaseURL)
        guard data.count >= 12, String(bytes: data[0..<4], encoding: .ascii) == "mhfd" else {
            throw ArtworkDBError.writeFailed("ArtworkDB non valido")
        }
        nextImageID = max(readU32(data, 28), 0x40)
        images.removeAll()

        var offset = Int(readU32(data, 4))
        let end = min(Int(readU32(data, 8)), data.count)
        while offset + 12 <= end {
            let magic = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let total = Int(readU32(data, offset + 8))
            guard total >= 12, offset + total <= data.count else { break }
            if magic == "mhsd", readU32(data, offset + 12) == 1 {
                parseImageList(data, start: offset + Int(readU32(data, offset + 4)), end: offset + total)
            }
            offset += total
        }
        if let maxID = images.map(\.id).max() {
            nextImageID = max(nextImageID, maxID &+ 1)
        }
        ensureEmptyIthmbFiles()
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
            var thumbs: [ArtworkThumbRef] = []

            var child = offset + headerLen
            let childEnd = offset + total
            while child + 16 <= childEnd {
                let cm = String(bytes: data[child..<(child + 4)], encoding: .ascii) ?? ""
                let cTotal = Int(readU32(data, child + 8))
                guard cTotal >= 12, child + cTotal <= data.count else { break }
                if cm == "mhod", readU16(data, child + 12) == 2 {
                    // type-2 container → mhni
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

            images.append(ArtworkImageEntry(id: id, songDBID: songDBID, thumbs: thumbs))
            offset += total
        }
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

    // MARK: - Build ArtworkDB

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
        writeU32(&file, at: 16, 2) // required by iTunes 7+
        writeU32(&file, at: 20, 3) // child mhsd count
        writeU32(&file, at: 28, nextImageID)
        file.append(body)
        writeU32(&file, at: 8, UInt32(file.count))
        return file
    }

    private func wrapMHSD(type: UInt32, child: Data) -> Data {
        let headerLen = 0x10
        var data = Data()
        appendFourCC(&data, "mhsd")
        appendU32(&data, UInt32(headerLen))
        appendU32(&data, UInt32(headerLen + child.count))
        appendU32(&data, type)
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
        let headerLen = 0x98
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhii")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + children.count))
        writeU32(&header, at: 12, UInt32(image.thumbs.count))
        writeU32(&header, at: 16, image.id)
        writeU64(&header, at: 20, image.songDBID)
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
        let path = String(format: ":Artwork:F%04d_1.ithmb", thumb.correlationID)
        let pathMHOD = buildArtworkStringMHOD(type: 3, string: path)
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

    private func buildArtworkStringMHOD(type: UInt16, string: String) -> Data {
        var stringBytes = Data()
        for unit in string.utf16 {
            appendU16(&stringBytes, unit)
        }
        let contentHeader = 12
        let rawTotal = 0x18 + contentHeader + stringBytes.count
        let padding = (4 - (rawTotal % 4)) % 4
        let total = rawTotal + padding
        var data = Data(count: total)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, 0x18)
        writeU32(&data, at: 8, UInt32(total))
        writeU16(&data, at: 12, type)
        data[15] = UInt8(padding)
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
            // Letterbox into square slot.
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

    // MARK: - Binary helpers (local to avoid fighting iTunesDB writer privates)

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

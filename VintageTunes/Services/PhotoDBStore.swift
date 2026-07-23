import AppKit
import Foundation

enum PhotoDBError: LocalizedError {
    case unsupportedDevice
    case invalidImage
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice: return "Foto non supportate su questo iPod."
        case .invalidImage: return "Immagine non valida."
        case .writeFailed(let m): return "Scrittura Photo Database fallita: \(m)"
        }
    }
}

enum PhotoPixelFormat {
    case rgb565LE
    case uyvyBE
}

struct PhotoThumbFormat: Equatable {
    let correlationID: UInt32
    let width: Int
    let height: Int
    let pixelFormat: PhotoPixelFormat

    var slotBytes: Int { width * height * 2 }
    var ithmbName: String { String(format: "F%04d_1.ithmb", correlationID) }
    /// Music.app: `:Thumbs:F1019_1.ithmb`
    var ithmbPath: String { ":Thumbs:\(ithmbName)" }
}

enum PhotoDeviceProfile: Equatable {
    /// iPod Video 5G / 5.5G — stessi ID del backup Music.app.
    case video5G

    var formats: [PhotoThumbFormat] {
        // Ordine Music.app nei mhni / mhif.
        [
            PhotoThumbFormat(correlationID: 1019, width: 720, height: 480, pixelFormat: .uyvyBE),
            PhotoThumbFormat(correlationID: 1015, width: 130, height: 88, pixelFormat: .rgb565LE),
            PhotoThumbFormat(correlationID: 1024, width: 320, height: 240, pixelFormat: .rgb565LE),
            PhotoThumbFormat(correlationID: 1036, width: 50, height: 41, pixelFormat: .rgb565LE)
        ]
    }

    var correlationIDs: Set<UInt32> { Set(formats.map(\.correlationID)) }

    /// Solo Video 5G/5.5G stock (Classic / nano / Rockbox = nil).
    static func detect(for device: iPodDevice) -> PhotoDeviceProfile? {
        guard device.firmwareMode == .stock else { return nil }
        let hint = device.modelHint.uppercased()
        if hint.contains("NANO") { return nil }
        if hint.contains("CLASSIC"), !hint.contains("VIDEO") { return nil }
        if hint.contains("MB147") || hint.contains("MB139") || hint.contains("MA446") { return nil }
        let video = hint.contains("VIDEO")
            || hint.contains("MA002") || hint.contains("MA146")
            || hint.contains("MA003") || hint.contains("MA147")
            || hint.contains("MA477") || hint.contains("MA450") || hint.contains("MA448")
        return video ? .video5G : nil
    }
}

struct PhotoThumbRef: Equatable {
    var correlationID: UInt32
    var offset: UInt32
    var size: UInt32
    /// Dimensioni disegnate (aspect-fit), come mhni w/h Music.app.
    var width: UInt16
    var height: UInt16
    /// `(storageWidth - drawnWidth) << 16`
    var paddingMeta: UInt32
}

struct PhotoImageEntry: Equatable {
    var id: UInt32
    /// Secondo id Music.app (mhii+0x14 / mhba+0x14).
    var companionID: UInt32
    var thumbs: [PhotoThumbRef]
}

/// `Photos/Photo Database` + `Photos/Thumbs/*.ithmb` (Video 5.5G / Music.app).
final class PhotoDBStore {
    private(set) var profile: PhotoDeviceProfile
    private(set) var images: [PhotoImageEntry] = []
    private(set) var albumName: String = "Photo Library"
    private var nextImageID: UInt32 = 0x64
    /// Music.app scrive UUID opachi in mhfd; a zero il firmware può ignorare il DB.
    private var mhfdUUID: Data = Data(count: 16)
    private var mhfdExtraID: UInt64 = 0
    private let photosDir: URL
    private let thumbsDir: URL

    init(device: iPodDevice, profile: PhotoDeviceProfile) {
        self.profile = profile
        self.photosDir = device.volumeURL.appendingPathComponent("Photos", isDirectory: true)
        self.thumbsDir = photosDir.appendingPathComponent("Thumbs", isDirectory: true)
    }

    var databaseURL: URL { photosDir.appendingPathComponent("Photo Database") }

    static func open(for device: iPodDevice) throws -> PhotoDBStore? {
        guard let profile = PhotoDeviceProfile.detect(for: device) else { return nil }
        let store = PhotoDBStore(device: device, profile: profile)
        let fm = FileManager.default
        try fm.createDirectory(at: store.photosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: store.thumbsDir, withIntermediateDirectories: true)
        store.loadAlbumNameHint(from: device)
        if fm.fileExists(atPath: store.databaseURL.path) {
            try store.load()
        } else {
            store.ensureMhfdIdentity()
            store.ensureEmptyIthmbFiles()
        }
        return store
    }

    /// Anteprima Mac da thumb RGB565 (preferisci 1024, poi 1015).
    func previewJPEGData(for imageID: UInt32) -> Data? {
        guard let entry = images.first(where: { $0.id == imageID }) else { return nil }
        let prefer: [UInt32] = [1024, 1015, 1036]
        for cid in prefer {
            guard let thumb = entry.thumbs.first(where: { $0.correlationID == cid }),
                  let format = profile.formats.first(where: { $0.correlationID == cid }),
                  format.pixelFormat == .rgb565LE,
                  let ns = decodeRGB565Thumb(thumb: thumb, format: format),
                  let tiff = ns.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            else { continue }
            return jpeg
        }
        return nil
    }

    @discardableResult
    func addPhoto(imageData: Data) throws -> UInt32 {
        guard let nsImage = NSImage(data: imageData) else { throw PhotoDBError.invalidImage }

        var thumbs: [PhotoThumbRef] = []
        for format in profile.formats {
            let prepared = try Self.preparedSlot(from: nsImage, format: format)
            let fileURL = thumbsDir.appendingPathComponent(format.ithmbName)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let offset = UInt32(handle.offsetInFile)
            try handle.write(contentsOf: prepared.pixels)
            try handle.synchronize()
            thumbs.append(
                PhotoThumbRef(
                    correlationID: format.correlationID,
                    offset: offset,
                    size: UInt32(format.slotBytes),
                    width: prepared.drawnWidth,
                    height: prepared.drawnHeight,
                    paddingMeta: prepared.paddingMeta
                )
            )
        }

        let id = nextImageID
        let companion = id &+ 1
        nextImageID = companion &+ 1
        images.append(PhotoImageEntry(id: id, companionID: companion, thumbs: thumbs))
        try save()
        return id
    }

    func deletePhotos(ids: Set<UInt32>) throws {
        let before = images.count
        images.removeAll { ids.contains($0.id) }
        guard images.count != before else { return }
        try rebuildIthmbsFromImages()
        try save()
    }

    func save() throws {
        let data = buildDatabase()
        let tmp = databaseURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        try FileManager.default.moveItem(at: tmp, to: databaseURL)
        if let dir = try? FileHandle(forWritingTo: photosDir) {
            try? dir.synchronize()
            try? dir.close()
        }
    }

    // MARK: - Load

    private func loadAlbumNameHint(from device: iPodDevice) {
        let url = device.iTunesURL.appendingPathComponent("PhotosFolderName")
        guard let data = try? Data(contentsOf: url), data.count >= 4 else { return }
        let len = Int(readU16(data, 0))
        guard len > 0, 2 + len * 2 <= data.count else { return }
        var units: [UInt16] = []
        for i in 0..<len {
            units.append(readU16(data, 2 + i * 2))
        }
        let name = String(decoding: units, as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            albumName = name
        }
    }

    private func load() throws {
        let data = try Data(contentsOf: databaseURL)
        guard data.count >= 12, String(bytes: data[0..<4], encoding: .ascii) == "mhfd" else {
            throw PhotoDBError.writeFailed("Photo Database non valido")
        }
        nextImageID = max(readU32(data, 28), 0x64)
        if data.count >= 0x30 {
            mhfdUUID = Data(data[0x20..<0x30])
        }
        if data.count >= 0x44 {
            mhfdExtraID = readU64(data, 0x3c)
        }
        ensureMhfdIdentity()
        images.removeAll()

        var offset = Int(readU32(data, 4))
        let end = min(Int(readU32(data, 8)), data.count)
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
                } else if type == 2 {
                    if let name = parseAlbumName(data, start: contentStart, end: contentEnd), !name.isEmpty {
                        albumName = name
                    }
                }
            }
            offset += total
        }
        if let maxID = images.map({ max($0.id, $0.companionID) }).max() {
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
            let companion = readU32(data, offset + 20)
            var thumbs: [PhotoThumbRef] = []

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
                            PhotoThumbRef(
                                correlationID: readU32(data, mhniOffset + 16),
                                offset: readU32(data, mhniOffset + 20),
                                size: readU32(data, mhniOffset + 24),
                                width: readU16(data, mhniOffset + 34),
                                height: readU16(data, mhniOffset + 32),
                                paddingMeta: readU32(data, mhniOffset + 28)
                            )
                        )
                    }
                }
                child += cTotal
            }

            images.append(PhotoImageEntry(id: id, companionID: companion == 0 ? id &+ 1 : companion, thumbs: thumbs))
            offset += total
        }
    }

    private func parseAlbumName(_ data: Data, start: Int, end: Int) -> String? {
        guard start + 12 <= end, String(bytes: data[start..<(start + 4)], encoding: .ascii) == "mhla" else {
            return nil
        }
        var offset = start + Int(readU32(data, start + 4))
        while offset + 12 <= end {
            let magic = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let total = Int(readU32(data, offset + 8))
            guard total >= 12, offset + total <= data.count else { break }
            if magic == "mhba" {
                let headerLen = Int(readU32(data, offset + 4))
                var child = offset + headerLen
                let childEnd = offset + total
                while child + 16 <= childEnd {
                    let cm = String(bytes: data[child..<(child + 4)], encoding: .ascii) ?? ""
                    let cTotal = Int(readU32(data, child + 8))
                    guard cTotal >= 16, child + cTotal <= data.count else { break }
                    if cm == "mhod", readU16(data, child + 12) == 1 {
                        let byteLen = Int(readU32(data, child + 0x18))
                        let encoding = readU32(data, child + 0x1c)
                        let payloadStart = child + 0x24
                        guard payloadStart + byteLen <= child + cTotal else { break }
                        let payload = data[payloadStart..<(payloadStart + byteLen)]
                        if encoding == 1, let s = String(data: payload, encoding: .utf8) {
                            return s
                        }
                        if encoding == 2 {
                            var units: [UInt16] = []
                            var i = payloadStart
                            while i + 1 < payloadStart + byteLen {
                                units.append(readU16(data, i))
                                i += 2
                            }
                            return String(decoding: units, as: UTF16.self)
                        }
                    }
                    child += cTotal
                }
            }
            offset += total
        }
        return nil
    }

    private func ensureEmptyIthmbFiles() {
        let fm = FileManager.default
        for format in profile.formats {
            let url = thumbsDir.appendingPathComponent(format.ithmbName)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: Data(), attributes: nil)
            }
        }
    }

    /// Riscrive tutti gli ithmb in ordine (dopo delete).
    private func rebuildIthmbsFromImages() throws {
        let fm = FileManager.default
        // Snapshot prima di truncare: gli offset delle entry residue sono ancora validi.
        var snapshots: [UInt32: Data] = [:]
        for format in profile.formats {
            let url = thumbsDir.appendingPathComponent(format.ithmbName)
            snapshots[format.correlationID] = (try? Data(contentsOf: url)) ?? Data()
        }

        for format in profile.formats {
            fm.createFile(atPath: thumbsDir.appendingPathComponent(format.ithmbName).path, contents: Data(), attributes: nil)
        }

        var rebuilt: [PhotoImageEntry] = []
        for entry in images {
            var newThumbs: [PhotoThumbRef] = []
            for format in profile.formats {
                guard let old = entry.thumbs.first(where: { $0.correlationID == format.correlationID }),
                      let fileData = snapshots[format.correlationID],
                      Int(old.offset) + Int(old.size) <= fileData.count
                else { continue }
                let slice = fileData[Int(old.offset)..<Int(old.offset) + Int(old.size)]
                let fileURL = thumbsDir.appendingPathComponent(format.ithmbName)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                let offset = UInt32(handle.offsetInFile)
                try handle.write(contentsOf: slice)
                try handle.synchronize()
                newThumbs.append(
                    PhotoThumbRef(
                        correlationID: format.correlationID,
                        offset: offset,
                        size: UInt32(format.slotBytes),
                        width: old.width,
                        height: old.height,
                        paddingMeta: old.paddingMeta
                    )
                )
            }
            guard newThumbs.count == profile.formats.count else { continue }
            rebuilt.append(PhotoImageEntry(id: entry.id, companionID: entry.companionID, thumbs: newThumbs))
        }
        images = rebuilt
    }

    // MARK: - Build Photo Database

    private func buildDatabase() -> Data {
        let imageList = buildImageList()
        let albumList = buildAlbumList()
        let fileList = buildFileList()

        var body = Data()
        body.append(wrapMHSD(type: 1, child: imageList))
        body.append(wrapMHSD(type: 2, child: albumList))
        body.append(wrapMHSD(type: 3, child: fileList))

        let headerLen = 0x84
        var file = Data(count: headerLen)
        writeFourCC(&file, at: 0, "mhfd")
        writeU32(&file, at: 4, UInt32(headerLen))
        writeU32(&file, at: 8, UInt32(headerLen + body.count))
        writeU32(&file, at: 16, 6)
        writeU32(&file, at: 20, 3)
        writeU32(&file, at: 28, nextImageID)
        ensureMhfdIdentity()
        file.replaceSubrange(0x20..<0x30, with: mhfdUUID)
        writeU64(&file, at: 0x3c, mhfdExtraID)
        writeU32(&file, at: 0x30, 1)
        writeU32(&file, at: 0x34, 2)
        file.append(body)
        writeU32(&file, at: 8, UInt32(file.count))
        return file
    }

    private func ensureMhfdIdentity() {
        if mhfdUUID.count != 16 || mhfdUUID.allSatisfy({ $0 == 0 }) {
            var bytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
            mhfdUUID = Data(bytes)
        }
        if mhfdExtraID == 0 {
            mhfdExtraID = UInt64.random(in: 1...UInt64.max)
        }
    }

    private func writeU64(_ data: inout Data, at offset: Int, _ value: UInt64) {
        for i in 0..<8 {
            data[offset + i] = UInt8((value >> (8 * i)) & 0xff)
        }
    }

    private func wrapMHSD(type: UInt32, child: Data) -> Data {
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

    private func buildAlbumList() -> Data {
        var children = Data()
        children.append(buildMHBA())
        let headerLen = 0x5c
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhla")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, 1)
        data.append(children)
        return data
    }

    private func buildMHBA() -> Data {
        var children = Data()
        children.append(buildUTF8StringMHOD(type: 1, string: albumName))
        for image in images {
            children.append(buildMHIA(imageID: image.id))
        }

        let headerLen = 0x94
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhba")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + children.count))
        writeU32(&header, at: 12, 1) // string mhod count (nome album)
        // libgpod: +0x10 = num_mhias (numero foto nell’album). Hardcoded 1 rompeva il parse firmware.
        writeU32(&header, at: 16, UInt32(images.count))
        let companion = images.first?.companionID ?? 0x65
        writeU32(&header, at: 20, companion)
        writeU32(&header, at: 28, 0x0001_0000)
        if let first = images.first {
            writeU32(&header, at: 60, first.id)
        }
        writeU32(&header, at: 80, macTimestamp())
        header.append(children)
        return header
    }

    private func buildMHIA(imageID: UInt32) -> Data {
        let headerLen = 0x28
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhia")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(headerLen))
        writeU32(&data, at: 16, imageID)
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

    private func buildMHIF(_ format: PhotoThumbFormat) -> Data {
        let headerLen = 0x7c
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhif")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(headerLen))
        writeU32(&data, at: 16, format.correlationID)
        writeU32(&data, at: 20, UInt32(format.slotBytes))
        return data
    }

    private func buildMHII(_ image: PhotoImageEntry) -> Data {
        var children = Data()
        // Ordine formati Music.app.
        for format in profile.formats {
            if let thumb = image.thumbs.first(where: { $0.correlationID == format.correlationID }) {
                children.append(buildThumbnailMHOD(thumb, path: format.ithmbPath))
            }
        }
        children.append(buildEmptyMHAF())

        let stamp = macTimestamp()
        let headerLen = 0x98
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhii")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + children.count))
        writeU32(&header, at: 12, UInt32(image.thumbs.count + 1))
        writeU32(&header, at: 16, image.id)
        writeU32(&header, at: 20, image.companionID)
        writeU32(&header, at: 40, stamp)
        writeU32(&header, at: 44, stamp)
        writeU32(&header, at: 76, 0x7FF8_0000)
        writeU32(&header, at: 84, 0x7FF8_0000)
        writeU32(&header, at: 88, stamp)
        header.append(children)
        return header
    }

    private func buildThumbnailMHOD(_ thumb: PhotoThumbRef, path: String) -> Data {
        let mhni = buildMHNI(thumb, path: path)
        let headerLen = 0x18
        var data = Data(count: headerLen)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, UInt32(headerLen))
        writeU32(&data, at: 8, UInt32(headerLen + mhni.count))
        writeU16(&data, at: 12, 2)
        data.append(mhni)
        return data
    }

    private func buildMHNI(_ thumb: PhotoThumbRef, path: String) -> Data {
        let pathMHOD = buildUTF16PathMHOD(string: path)
        let headerLen = 0x4c
        var header = Data(count: headerLen)
        writeFourCC(&header, at: 0, "mhni")
        writeU32(&header, at: 4, UInt32(headerLen))
        writeU32(&header, at: 8, UInt32(headerLen + pathMHOD.count))
        writeU32(&header, at: 12, 1)
        writeU32(&header, at: 16, thumb.correlationID)
        writeU32(&header, at: 20, thumb.offset)
        writeU32(&header, at: 24, thumb.size)
        writeU32(&header, at: 28, thumb.paddingMeta)
        writeU16(&header, at: 32, thumb.height)
        writeU16(&header, at: 34, thumb.width)
        writeU32(&header, at: 40, thumb.size)
        header.append(pathMHOD)
        return header
    }

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

    private func buildUTF16PathMHOD(string: String) -> Data {
        var stringBytes = Data()
        for unit in string.utf16 {
            appendU16(&stringBytes, unit)
        }
        // Music.app: +0xe = 0x0200, pad totale a multiplo di 4.
        var total = 0x24 + stringBytes.count
        let pad = (4 - (total % 4)) % 4
        total += pad
        var data = Data(count: total)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, 0x18)
        writeU32(&data, at: 8, UInt32(total))
        writeU16(&data, at: 12, 3)
        writeU16(&data, at: 14, 0x0200)
        writeU32(&data, at: 0x18, UInt32(stringBytes.count))
        writeU32(&data, at: 0x1c, 2)
        data.replaceSubrange(0x24..<(0x24 + stringBytes.count), with: stringBytes)
        return data
    }

    private func buildUTF8StringMHOD(type: UInt16, string: String) -> Data {
        let stringBytes = Data(string.utf8)
        var total = 0x24 + stringBytes.count
        let pad = (4 - (total % 4)) % 4
        total += pad
        var data = Data(count: total)
        writeFourCC(&data, at: 0, "mhod")
        writeU32(&data, at: 4, 0x18)
        writeU32(&data, at: 8, UInt32(total))
        writeU16(&data, at: 12, type)
        writeU16(&data, at: 14, 0x0300)
        writeU32(&data, at: 0x18, UInt32(stringBytes.count))
        writeU32(&data, at: 0x1c, 1) // UTF-8
        data.replaceSubrange(0x24..<(0x24 + stringBytes.count), with: stringBytes)
        return data
    }

    // MARK: - Pixel encode / decode

    private struct PreparedSlot {
        var pixels: Data
        var drawnWidth: UInt16
        var drawnHeight: UInt16
        var paddingMeta: UInt32
    }

    private static func preparedSlot(from image: NSImage, format: PhotoThumbFormat) throws -> PreparedSlot {
        let src = image.size
        let scale = min(
            CGFloat(format.width) / max(src.width, 1),
            CGFloat(format.height) / max(src.height, 1)
        )
        let drawW = max(1, Int((src.width * scale).rounded()))
        let drawH = max(1, Int((src.height * scale).rounded()))
        let padW = max(0, format.width - drawW)
        // Music.app: high halfword ≈ pad; F1015 usava 0x23 invece di 0x24 — usiamo pad reale.
        let paddingMeta = UInt32(padW) << 16

        let pixels: Data
        switch format.pixelFormat {
        case .rgb565LE:
            pixels = try ArtworkDBStore.rgb565LE(from: image, width: format.width, height: format.height)
        case .uyvyBE:
            pixels = try uyvyBE(from: image, width: format.width, height: format.height)
        }
        var slot = pixels
        if slot.count < format.slotBytes {
            slot.append(Data(count: format.slotBytes - slot.count))
        } else if slot.count > format.slotBytes {
            slot = Data(slot.prefix(format.slotBytes))
        }
        return PreparedSlot(
            pixels: slot,
            drawnWidth: UInt16(drawW),
            drawnHeight: UInt16(drawH),
            paddingMeta: paddingMeta
        )
    }

    /// UYVY byte order U Y0 V Y1 (libgpod UYVY_BE / Music.app F1019).
    private static func uyvyBE(from image: NSImage, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width % 2 == 0 else { throw PhotoDBError.invalidImage }
        let rgba = try rgbaBytes(from: image, width: width, height: height)
        var out = Data(capacity: width * height * 2)
        for y in 0..<height {
            var x = 0
            while x < width {
                let i0 = (y * width + x) * 4
                let i1 = (y * width + x + 1) * 4
                let r0 = Int(rgba[i0]), g0 = Int(rgba[i0 + 1]), b0 = Int(rgba[i0 + 2])
                let r1 = Int(rgba[i1]), g1 = Int(rgba[i1 + 1]), b1 = Int(rgba[i1 + 2])
                let y0 = clampByte(((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16)
                let y1 = clampByte(((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16)
                let u = clampByte(((-38 * r0 - 74 * g0 + 112 * b0 + 128) >> 8) + 128)
                let v = clampByte(((112 * r0 - 94 * g0 - 18 * b0 + 128) >> 8) + 128)
                out.append(UInt8(u))
                out.append(UInt8(y0))
                out.append(UInt8(v))
                out.append(UInt8(y1))
                x += 2
            }
        }
        return out
    }

    private static func rgbaBytes(from image: NSImage, width: Int, height: Int) throws -> [UInt8] {
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
        ) else { throw PhotoDBError.invalidImage }

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
        guard let ptr = rep.bitmapData else { throw PhotoDBError.invalidImage }
        return Array(UnsafeBufferPointer(start: ptr, count: width * height * 4))
    }

    private static func clampByte(_ v: Int) -> Int { max(0, min(255, v)) }

    private func decodeRGB565Thumb(thumb: PhotoThumbRef, format: PhotoThumbFormat) -> NSImage? {
        let url = thumbsDir.appendingPathComponent(format.ithmbName)
        guard let file = try? Data(contentsOf: url),
              Int(thumb.offset) + Int(thumb.size) <= file.count else { return nil }
        let slice = file[Int(thumb.offset)..<Int(thumb.offset) + Int(thumb.size)]
        let w = format.width
        let h = format.height
        guard slice.count >= w * h * 2 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: w * 4,
            bitsPerPixel: 32
        ), let ptr = rep.bitmapData else { return nil }

        var si = slice.startIndex
        for y in 0..<h {
            for x in 0..<w {
                let lo = Int(slice[si])
                let hi = Int(slice[si + 1])
                si += 2
                let pix = lo | (hi << 8)
                let r = ((pix >> 11) & 0x1f) * 255 / 31
                let g = ((pix >> 5) & 0x3f) * 255 / 63
                let b = (pix & 0x1f) * 255 / 31
                let di = (y * w + x) * 4
                ptr[di] = UInt8(r)
                ptr[di + 1] = UInt8(g)
                ptr[di + 2] = UInt8(b)
                ptr[di + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Helpers

    private func macTimestamp() -> UInt32 {
        UInt32(Date().timeIntervalSince1970 + 2_082_844_800)
    }

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

    private func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }
}

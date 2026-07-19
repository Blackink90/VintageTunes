import Foundation

/// Espande file e cartelle in una lista piatta di file audio importabili/convertibili.
enum AudioFileCollector {
    static var importableExtensions: Set<String> {
        AudioMetadataReader.supportedExtensions
            .union(AudioConverter.convertibleExtensions)
    }

    /// Raccoglie ricorsivamente i file audio da file e/o cartelle.
    static func collectAudioFiles(from urls: [URL]) -> [URL] {
        var collected: [URL] = []
        var seen = Set<String>()

        for url in urls {
            collect(from: url.standardizedFileURL, into: &collected, seen: &seen)
        }

        return collected.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private static func collect(from url: URL, into collected: inout [URL], seen: inout Set<String>) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return }

            for case let item as URL in enumerator {
                var itemIsDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &itemIsDir), !itemIsDir.boolValue else {
                    continue
                }
                appendIfAudio(item, into: &collected, seen: &seen)
            }
        } else {
            appendIfAudio(url, into: &collected, seen: &seen)
        }
    }

    private static func appendIfAudio(_ url: URL, into collected: inout [URL], seen: inout Set<String>) {
        let ext = url.pathExtension.lowercased()
        guard importableExtensions.contains(ext) else { return }
        let key = url.standardizedFileURL.path
        guard seen.insert(key).inserted else { return }
        collected.append(url.standardizedFileURL)
    }
}

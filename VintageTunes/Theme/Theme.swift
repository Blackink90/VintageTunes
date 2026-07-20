import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Automatica"
        case .light: return "Chiara"
        case .dark: return "Scura"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SyncMode: String, CaseIterable, Identifiable {
    case manual
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Manuale"
        case .automatic: return "Automatica"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private static let appearanceKey = "appearanceMode"
    private static let syncModeKey = "syncMode"
    private static let syncBookmarkKey = "syncFolderBookmark"
    private static let syncPathKey = "syncFolderDisplayPath"
    private static let dismissedHashesKey = "dismissedSyncHashes"

    @Published var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceKey)
        }
    }

    @Published var syncMode: SyncMode {
        didSet {
            UserDefaults.standard.set(syncMode.rawValue, forKey: Self.syncModeKey)
        }
    }

    @Published private(set) var syncFolderDisplayPath: String? {
        didSet {
            if let syncFolderDisplayPath {
                UserDefaults.standard.set(syncFolderDisplayPath, forKey: Self.syncPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.syncPathKey)
            }
        }
    }

    @Published private(set) var dismissedSyncHashes: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(dismissedSyncHashes).sorted(), forKey: Self.dismissedHashesKey)
        }
    }

    private var syncFolderBookmark: Data? {
        didSet {
            if let syncFolderBookmark {
                UserDefaults.standard.set(syncFolderBookmark, forKey: Self.syncBookmarkKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.syncBookmarkKey)
            }
        }
    }

    var hasSyncFolder: Bool { syncFolderBookmark != nil }

    init() {
        let appearanceRaw = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? AppearanceMode.dark.rawValue
        appearanceMode = AppearanceMode(rawValue: appearanceRaw) ?? .dark

        let syncRaw = UserDefaults.standard.string(forKey: Self.syncModeKey) ?? SyncMode.manual.rawValue
        syncMode = SyncMode(rawValue: syncRaw) ?? .manual

        syncFolderBookmark = UserDefaults.standard.data(forKey: Self.syncBookmarkKey)
        syncFolderDisplayPath = UserDefaults.standard.string(forKey: Self.syncPathKey)
        let dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedHashesKey) ?? []
        dismissedSyncHashes = Set(dismissed)
    }

    @discardableResult
    func chooseSyncFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Seleziona"
        panel.message = "Cartella da cui VintageTunes proporrà le nuove canzoni all’iPod"
        if let current = resolvedSyncFolderURL() {
            panel.directoryURL = current
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return storeSyncFolderBookmark(for: url)
    }

    @discardableResult
    private func storeSyncFolderBookmark(for url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            syncFolderBookmark = data
            syncFolderDisplayPath = url.path
            return true
        } catch {
            return false
        }
    }

    func clearSyncFolder() {
        syncFolderBookmark = nil
        syncFolderDisplayPath = nil
    }

    func resolvedSyncFolderURL() -> URL? {
        guard let data = syncFolderBookmark else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                if let refreshed = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    syncFolderBookmark = refreshed
                    syncFolderDisplayPath = url.path
                }
            }
            return url
        } catch {
            return nil
        }
    }

    func dismissSyncHashes(_ hashes: [String]) {
        guard !hashes.isEmpty else { return }
        dismissedSyncHashes.formUnion(hashes)
    }

    func clearDismissedSyncHashes() {
        dismissedSyncHashes = []
    }
}

enum VTTheme {
    static let steelTop = Color(red: 0.78, green: 0.80, blue: 0.84)
    static let steelBottom = Color(red: 0.55, green: 0.58, blue: 0.63)
    static let amber = Color(red: 0.96, green: 0.52, blue: 0.12)
    static let amberSoft = Color(red: 0.96, green: 0.52, blue: 0.12).opacity(0.18)
    static let lcdGreen = Color(red: 0.55, green: 0.92, blue: 0.62)
    /// Nero fisso per cromature stile iPod (logo, schermo illustrato).
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.13)

    static let charcoal = adaptiveColor(
        light: NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1),
        dark: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    )
    static let panel = adaptiveColor(
        light: NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.95, alpha: 1),
        dark: NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1)
    )
    static let panelStroke = adaptiveColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    static let textPrimary = adaptiveColor(
        light: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1),
        dark: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    )
    static let textSecondary = adaptiveColor(
        light: NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.48, alpha: 1),
        dark: NSColor(calibratedRed: 0.70, green: 0.72, blue: 0.76, alpha: 1)
    )
    static let hairline = adaptiveColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    static let elevatedFill = adaptiveColor(
        light: NSColor(calibratedWhite: 1, alpha: 0.72),
        dark: NSColor(calibratedWhite: 1, alpha: 0.05)
    )
    static let controlFill = adaptiveColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    static let tableBackground = adaptiveColor(
        light: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
        dark: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    )
    static let playerChrome = adaptiveColor(
        light: NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.96, alpha: 1),
        dark: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
    )

    private static let backgroundTop = adaptiveColor(
        light: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1),
        dark: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
    )
    private static let backgroundBottom = adaptiveColor(
        light: NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1),
        dark: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)
    )
    private static let brushStroke = adaptiveColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.025),
        dark: NSColor(calibratedWhite: 1, alpha: 0.015)
    )

    /// Serif di sistema (New York su Apple) con weight reale — evita i warning di `.custom("New York").weight(...)`.
    static func displayFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static var background: some View {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            GeometryReader { geo in
                Path { path in
                    stride(from: 0.0, through: geo.size.height, by: 3).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(brushStroke, lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }))
    }
}

struct BrandMark: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [VTTheme.steelTop, VTTheme.steelBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                Circle()
                    .stroke(VTTheme.amber.opacity(0.9), lineWidth: 2)
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(VTTheme.ink)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("VintageTunes")
                    .font(VTTheme.displayFont(size: 22))
                    .foregroundStyle(VTTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text("iPod Companion")
                    .font(.custom("Avenir Next", size: 11).weight(.medium))
                    .tracking(1.2)
                    .foregroundStyle(VTTheme.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Stelle 0…5 stile iPod/iTunes. Tap sulla stessa stella attiva la azzera.
struct StarRatingControl: View {
    let stars: Int
    var size: CGFloat = 12
    var interactive: Bool = false
    var onRate: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: max(1, size * 0.15)) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= stars ? "star.fill" : "star")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(index <= stars ? VTTheme.amber : VTTheme.textSecondary.opacity(0.45))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard interactive, let onRate else { return }
                        onRate(index == stars ? 0 : index)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stars == 0 ? "Nessuna valutazione" : "\(stars) stelle")
        .accessibilityAddTraits(interactive ? .isButton : [])
    }
}

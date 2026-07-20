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

@MainActor
final class AppSettings: ObservableObject {
    private static let appearanceKey = "appearanceMode"

    @Published var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceKey)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? AppearanceMode.dark.rawValue
        appearanceMode = AppearanceMode(rawValue: raw) ?? .dark
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

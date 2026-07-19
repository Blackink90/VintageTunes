import SwiftUI

enum VTTheme {
    static let steelTop = Color(red: 0.78, green: 0.80, blue: 0.84)
    static let steelBottom = Color(red: 0.55, green: 0.58, blue: 0.63)
    static let charcoal = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let panel = Color(red: 0.14, green: 0.15, blue: 0.17)
    static let panelStroke = Color.white.opacity(0.08)
    static let amber = Color(red: 0.96, green: 0.52, blue: 0.12)
    static let amberSoft = Color(red: 0.96, green: 0.52, blue: 0.12).opacity(0.18)
    static let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.96)
    static let textSecondary = Color(red: 0.70, green: 0.72, blue: 0.76)
    static let lcdGreen = Color(red: 0.55, green: 0.92, blue: 0.62)

    static var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.13, blue: 0.15),
                Color(red: 0.07, green: 0.08, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            // subtle brushed texture via lines
            GeometryReader { geo in
                Path { path in
                    stride(from: 0.0, through: geo.size.height, by: 3).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.015), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
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
                    .fill(VTTheme.charcoal)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("VintageTunes")
                    .font(.custom("New York", size: 22).weight(.semibold))
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

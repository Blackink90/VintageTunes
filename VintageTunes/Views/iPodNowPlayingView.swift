import SwiftUI

/// Overlay flottante: solo l’iPod, senza sheet/bordo. Trascinabile dal corpo.
struct iPodNowPlayingOverlay: View {
    @EnvironmentObject private var library: LibraryController
    @State private var offset: CGSize = .zero
    @State private var dragOrigin: CGSize = .zero

    private var mode: FirmwareMode {
        library.connectedDevice?.firmwareMode ?? .stock
    }

    var body: some View {
        iPodBaseOverlay(
            playback: library.playback,
            mode: mode,
            deviceName: library.connectedDevice?.name ?? "iPod",
            onMenu: { library.showiPodPreview = false },
            onSelect: { library.playback.togglePlayPause() },
            onPlayPause: { library.playback.togglePlayPause() },
            onPrevious: { library.playback.playPrevious() },
            onNext: { library.playback.playNext() }
        )
        .frame(width: 300, height: 504)
        .offset(offset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    offset = CGSize(
                        width: dragOrigin.width + value.translation.width,
                        height: dragOrigin.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    dragOrigin = offset
                }
        )
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .help("Trascina per spostare l'iPod")
    }
}

// MARK: - Image + overlays

private struct iPodBaseOverlay: View {
    @ObservedObject var playback: PlaybackController
    let mode: FirmwareMode
    let deviceName: String
    var onMenu: () -> Void
    var onSelect: () -> Void
    var onPlayPause: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void

    /// Geometria misurata sull’asset 611×1024.
    private enum Layout {
        static let screen = CGRect(x: 0.090, y: 0.054, width: 0.823, height: 0.369)
        static let wheelCenter = CGPoint(x: 0.499, y: 0.706)
        static let wheelRadius: CGFloat = 0.297
        static let selectRadius: CGFloat = 0.105
    }

    var body: some View {
        Image("iPodBase")
            .resizable()
            .aspectRatio(611 / 1024, contentMode: .fit)
            .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
            .overlay {
                GeometryReader { geo in
                    let screen = scaled(Layout.screen, in: geo.size)
                    let wheelC = CGPoint(
                        x: Layout.wheelCenter.x * geo.size.width,
                        y: Layout.wheelCenter.y * geo.size.height
                    )
                    let wheelR = Layout.wheelRadius * geo.size.width
                    let selectR = Layout.selectRadius * geo.size.width

                    Group {
                        if mode == .rockbox {
                            RockboxNowPlayingScreen(playback: playback, deviceName: deviceName)
                        } else {
                            StockNowPlayingScreen(playback: playback)
                        }
                    }
                    .frame(width: screen.width, height: screen.height)
                    .position(x: screen.midX, y: screen.midY)
                    // Serve per lo scrubber sullo schermo LCD.

                    // Click wheel hit zones
                    wheelButton(size: selectR * 2, action: onSelect)
                        .position(x: wheelC.x, y: wheelC.y)

                    wheelArcButton(
                        center: wheelC,
                        radius: wheelR,
                        startDeg: -135,
                        endDeg: -45,
                        action: onMenu
                    )
                    wheelArcButton(
                        center: wheelC,
                        radius: wheelR,
                        startDeg: 135,
                        endDeg: 225,
                        action: onPrevious
                    )
                    wheelArcButton(
                        center: wheelC,
                        radius: wheelR,
                        startDeg: -45,
                        endDeg: 45,
                        action: onNext
                    )
                    wheelArcButton(
                        center: wheelC,
                        radius: wheelR,
                        startDeg: 45,
                        endDeg: 135,
                        action: onPlayPause
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("iPod Now Playing")
    }

    private func scaled(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: r.origin.x * size.width,
            y: r.origin.y * size.height,
            width: r.width * size.width,
            height: r.height * size.height
        )
    }

    private func wheelButton(size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Play / Pausa")
    }

    /// Corona del click wheel (esclude il bottone centrale).
    private func wheelArcButton(
        center: CGPoint,
        radius: CGFloat,
        startDeg: Double,
        endDeg: Double,
        action: @escaping () -> Void
    ) -> some View {
        let inner = radius * 0.38
        let outer = radius * 0.98
        return Button(action: action) {
            WheelArcShape(startDegrees: startDeg, endDegrees: endDeg, innerRadius: inner, outerRadius: outer)
                .fill(Color.clear)
                .frame(width: outer * 2, height: outer * 2)
                .contentShape(
                    WheelArcShape(startDegrees: startDeg, endDegrees: endDeg, innerRadius: inner, outerRadius: outer)
                )
        }
        .buttonStyle(.plain)
        .frame(width: outer * 2, height: outer * 2)
        .position(x: center.x, y: center.y)
    }
}

private struct WheelArcShape: Shape {
    var startDegrees: Double
    var endDegrees: Double
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle(degrees: startDegNormalized)
        let end = Angle(degrees: endDegNormalized)
        var path = Path()
        path.addArc(center: c, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: c, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private var startDegNormalized: Double { startDegrees }
    private var endDegNormalized: Double {
        endDegrees < startDegrees ? endDegrees + 360 : endDegrees
    }
}

// MARK: - Stock Apple Now Playing

private struct StockNowPlayingScreen: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject private var artwork = ArtworkCache.shared

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.82, green: 0.86, blue: 0.90),
                    Color(red: 0.70, green: 0.76, blue: 0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if let track = playback.nowPlaying {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Image(systemName: playback.isPlaying ? "play.fill" : "pause.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text("Now Playing")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                        Spacer()
                        BatteryGlyph(level: 0.85)
                    }
                    .foregroundStyle(Color(red: 0.15, green: 0.18, blue: 0.22))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.35))

                    HStack(alignment: .top, spacing: 8) {
                        cover(for: track)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color.black.opacity(0.2), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

                        VStack(alignment: .leading, spacing: 3) {
                            marquee(track.displayTitle, weight: .bold, size: 11)
                            marquee(track.displayArtist, weight: .medium, size: 10)
                            marquee(track.displayAlbum, weight: .regular, size: 9)
                                .opacity(0.75)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    Spacer(minLength: 4)

                    VStack(spacing: 3) {
                        GeometryReader { geo in
                            PlaybackScrubber(
                                playback: playback,
                                width: geo.size.width,
                                height: 7,
                                style: .stockiPod
                            )
                        }
                        .frame(height: 10)

                        HStack {
                            Text(playback.currentTimeLabel)
                            Spacer()
                            Text(playback.durationLabel)
                        }
                        .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color(red: 0.20, green: 0.24, blue: 0.28))
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    artwork.request(
                        artist: track.displayArtist,
                        album: track.displayAlbum,
                        fileURL: track.resolvedPath
                    )
                }
                .onChange(of: track.id) { _, _ in
                    artwork.request(
                        artist: track.displayArtist,
                        album: track.displayAlbum,
                        fileURL: track.resolvedPath
                    )
                }
            } else {
                Text("No Song")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.25, green: 0.28, blue: 0.32))
            }
        }
    }

    private func cover(for track: Track) -> some View {
        Group {
            if let image = artwork.image(artist: track.displayArtist, album: track.displayAlbum) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(red: 0.55, green: 0.60, blue: 0.66)
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private func marquee(_ text: String, weight: Font.Weight, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Rockbox Now Playing

private struct RockboxNowPlayingScreen: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject private var artwork = ArtworkCache.shared
    let deviceName: String

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.10, blue: 0.14)

            if let track = playback.nowPlaying {
                VStack(spacing: 0) {
                    HStack {
                        Text("Rockbox")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.35, green: 0.75, blue: 1.0))
                        Spacer()
                        Text(playback.isPlaying ? "▶" : "❚❚")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                        Text("85%")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45))

                    HStack(alignment: .center, spacing: 8) {
                        cover(for: track)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color(red: 0.25, green: 0.55, blue: 0.85), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle)
                                .font(.system(size: 10, weight: .semibold, design: .default))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(track.displayArtist)
                                .font(.system(size: 9, weight: .medium, design: .default))
                                .foregroundStyle(Color(red: 0.45, green: 0.80, blue: 1.0))
                                .lineLimit(1)
                            Text(track.displayAlbum)
                                .font(.system(size: 8, weight: .regular, design: .default))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    Spacer(minLength: 4)

                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            PlaybackScrubber(
                                playback: playback,
                                width: geo.size.width,
                                height: 5,
                                style: .rockbox
                            )
                        }
                        .frame(height: 8)

                        HStack {
                            Text(playback.currentTimeLabel)
                            Spacer()
                            Text(deviceName)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Spacer()
                            Text(playback.durationLabel)
                        }
                        .font(.system(size: 8, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.65))
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    artwork.request(
                        artist: track.displayArtist,
                        album: track.displayAlbum,
                        fileURL: track.resolvedPath
                    )
                }
                .onChange(of: track.id) { _, _ in
                    artwork.request(
                        artist: track.displayArtist,
                        album: track.displayAlbum,
                        fileURL: track.resolvedPath
                    )
                }
            } else {
                Text("Nothing to play")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    private func cover(for track: Track) -> some View {
        Group {
            if let image = artwork.image(artist: track.displayArtist, album: track.displayAlbum) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(red: 0.15, green: 0.18, blue: 0.24)
                    Image(systemName: "music.note")
                        .foregroundStyle(Color(red: 0.35, green: 0.70, blue: 0.95).opacity(0.8))
                }
            }
        }
    }
}

private struct BatteryGlyph: View {
    let level: CGFloat

    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .stroke(Color(red: 0.15, green: 0.18, blue: 0.22), lineWidth: 0.8)
                .frame(width: 14, height: 7)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                        .fill(Color(red: 0.15, green: 0.18, blue: 0.22))
                        .frame(width: max(2, 11 * level), height: 4)
                        .padding(.leading, 1.5)
                }
            RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                .fill(Color(red: 0.15, green: 0.18, blue: 0.22))
                .frame(width: 1.5, height: 3)
        }
    }
}

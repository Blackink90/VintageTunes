import SwiftUI

/// Overlay flottante: solo l’iPod, senza sheet/bordo. Trascinabile dal corpo.
struct iPodNowPlayingOverlay: View {
    @EnvironmentObject private var library: LibraryController
    @State private var offset: CGSize = .zero
    @State private var dragOrigin: CGSize = .zero
    @State private var isScrubbing = false

    private var mode: FirmwareMode {
        library.connectedDevice?.firmwareMode ?? .stock
    }

    var body: some View {
        iPodBaseOverlay(
            playback: library.playback,
            mode: mode,
            deviceName: library.connectedDevice?.name ?? "iPod",
            scrubbingActive: $isScrubbing,
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
                    guard !isScrubbing else { return }
                    offset = CGSize(
                        width: dragOrigin.width + value.translation.width,
                        height: dragOrigin.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    if !isScrubbing {
                        dragOrigin = offset
                    }
                }
        )
        .onChange(of: isScrubbing) { _, scrubbing in
            // A fine scrub: sincronizza l’origine così il prossimo drag non “salta”.
            if !scrubbing {
                dragOrigin = offset
            }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .help("Trascina per spostare l'iPod")
    }
}

// MARK: - Image + overlays

private struct iPodBaseOverlay: View {
    @ObservedObject var playback: PlaybackController
    let mode: FirmwareMode
    let deviceName: String
    @Binding var scrubbingActive: Bool
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
                            RockboxNowPlayingScreen(
                                playback: playback,
                                deviceName: deviceName,
                                scrubbingActive: $scrubbingActive
                            )
                        } else {
                            StockNowPlayingScreen(
                                playback: playback,
                                scrubbingActive: $scrubbingActive
                            )
                        }
                    }
                    .frame(width: screen.width, height: screen.height)
                    .position(x: screen.midX, y: screen.midY)

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
        }
        .buttonStyle(iPodWheelCenterStyle(size: size))
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
            Color.clear
                .frame(width: outer * 2, height: outer * 2)
        }
        .buttonStyle(
            iPodWheelArcStyle(
                startDegrees: startDeg,
                endDegrees: endDeg,
                innerRadius: inner,
                outerRadius: outer
            )
        )
        .frame(width: outer * 2, height: outer * 2)
        .position(x: center.x, y: center.y)
    }
}

/// Feedback “tasto fisico” sul centro Select.
private struct iPodWheelCenterStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return ZStack {
            Circle()
                .fill(Color.black.opacity(pressed ? 0.22 : 0))
            Circle()
                .stroke(Color.black.opacity(pressed ? 0.14 : 0), lineWidth: 1.5)
                .padding(1)
            configuration.label
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
    }
}

/// Feedback “tasto fisico” sulle zone MENU / << / >> / play della corona.
private struct iPodWheelArcStyle: ButtonStyle {
    let startDegrees: Double
    let endDegrees: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = WheelArcShape(
            startDegrees: startDegrees,
            endDegrees: endDegrees,
            innerRadius: innerRadius,
            outerRadius: outerRadius
        )
        return ZStack {
            shape
                .fill(Color.black.opacity(pressed ? 0.22 : 0))
            shape
                .stroke(Color.black.opacity(pressed ? 0.12 : 0), lineWidth: 1)
            configuration.label
        }
        .frame(width: outerRadius * 2, height: outerRadius * 2)
        .contentShape(shape)
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
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

// MARK: - Stock Apple Now Playing (layout Classic / Video)

private struct StockNowPlayingScreen: View {
    @ObservedObject var playback: PlaybackController
    @Binding var scrubbingActive: Bool
    @ObservedObject private var artwork = ArtworkCache.shared

    private let ink = Color.black.opacity(0.92)
    private let lcdTop = Color(red: 0.93, green: 0.94, blue: 0.95)
    private let lcdBottom = Color(red: 0.82, green: 0.84, blue: 0.86)

    var body: some View {
        ZStack {
            LinearGradient(colors: [lcdTop, lcdBottom], startPoint: .top, endPoint: .bottom)
            // Trama LCD orizzontale leggera
            GeometryReader { geo in
                Path { path in
                    stride(from: 0.0, through: geo.size.height, by: 2).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.black.opacity(0.035), lineWidth: 1)
            }
            .allowsHitTesting(false)

            if let track = playback.nowPlaying {
                VStack(spacing: 0) {
                    header

                    HStack(alignment: .top, spacing: 6) {
                        cover(for: track)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.black.opacity(0.35), lineWidth: 0.6)
                            )
                            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                            .padding(.top, 9)
                            .allowsHitTesting(false)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Spacer(minLength: 0)
                                Image(systemName: "shuffle")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(ink.opacity(0.85))
                            }
                            .padding(.top, 2)
                            .padding(.bottom, 1)

                            Text(track.displayTitle)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ink)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)

                            Text(track.displayArtist)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)

                            Text(track.displayAlbum)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(ink)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)

                            if let pos = playback.queuePosition {
                                Text("\(pos.index) of \(pos.total)")
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(ink)
                                    .padding(.top, 3)
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 5)
                    .padding(.top, 2)

                    Spacer(minLength: 4)

                    progressBlock
                        .padding(.horizontal, 4)
                        .padding(.bottom, 10)
                }
                .onAppear { requestArt(for: track) }
                .onChange(of: track.id) { _, _ in requestArt(for: track) }
            } else {
                Text("No Song")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.6))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("Now Playing")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ink)
            Spacer()
            Image(systemName: playback.isPlaying ? "play.fill" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.22, green: 0.42, blue: 0.88))
            iPodBatteryGlyph(level: 0.82)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.72, green: 0.74, blue: 0.77),
                    Color(red: 0.58, green: 0.60, blue: 0.64),
                    Color(red: 0.66, green: 0.68, blue: 0.71)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            // Ombra sotto la barra status
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.08),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 3)
            .offset(y: 3)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private var progressBlock: some View {
        HStack(spacing: 4) {
            Text(playback.currentTimeLabel)
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(ink)
                .frame(minWidth: 28, alignment: .leading)
                .allowsHitTesting(false)

            GeometryReader { geo in
                PlaybackScrubber(
                    playback: playback,
                    width: geo.size.width,
                    height: 13,
                    style: .stockiPod,
                    scrubbingActive: $scrubbingActive
                )
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            Text(playback.remainingTimeLabel)
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(ink)
                .frame(minWidth: 32, alignment: .trailing)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 2)
    }

    private func requestArt(for track: Track) {
        artwork.request(
            artist: track.displayArtist,
            album: track.displayAlbum,
            fileURL: track.resolvedPath
        )
    }

    private func cover(for track: Track) -> some View {
        Group {
            if let image = artwork.image(artist: track.displayArtist, album: track.displayAlbum) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(red: 0.72, green: 0.74, blue: 0.78)
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.black.opacity(0.35))
                }
            }
        }
        .clipped()
    }
}

// MARK: - Rockbox Now Playing

private struct RockboxNowPlayingScreen: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject private var artwork = ArtworkCache.shared
    let deviceName: String
    @Binding var scrubbingActive: Bool

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
                                style: .rockbox,
                                scrubbingActive: $scrubbingActive
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

private struct iPodBatteryGlyph: View {
    let level: CGFloat

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .stroke(Color.black.opacity(0.85), lineWidth: 0.9)
                    .frame(width: 15, height: 7)
                RoundedRectangle(cornerRadius: 0.6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.45, green: 0.85, blue: 0.35),
                                Color(red: 0.25, green: 0.70, blue: 0.22)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(2, 12 * min(1, max(0, level))), height: 4.5)
                    .padding(.leading, 1.4)
            }
            RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .frame(width: 1.6, height: 3.2)
        }
    }
}

private struct BatteryGlyph: View {
    let level: CGFloat

    var body: some View {
        iPodBatteryGlyph(level: level)
    }
}

import SwiftUI

struct LibraryStatsBar: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        if library.connectedDevice != nil {
            HStack(spacing: 0) {
                stat(library.statsTracks.count == 1 ? "1 canzone" : "\(library.statsTracks.count) canzoni")
                separator
                stat(durationLabel)
                separator
                stat(sizeLabel)
                Spacer(minLength: 8)
                if !library.selection.isEmpty {
                    Text("selezione")
                        .font(.custom("Avenir Next", size: 10).weight(.semibold))
                        .foregroundStyle(VTTheme.amber.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(VTTheme.amberSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Rectangle()
                    .fill(VTTheme.charcoal)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(VTTheme.hairline)
                            .frame(height: 1)
                    }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                library.clearListSelection()
            }
            .help(
                library.selection.isEmpty
                    ? "Totali della lista corrente"
                    : "Clic per deselezionare e vedere i totali"
            )
        }
    }

    private var durationLabel: String {
        let sum = library.statsTracks.reduce(UInt64(0)) { $0 + UInt64($1.durationMs) }
        return LibraryStats.formatTotalMinutes(durationMsSum: sum)
    }

    private var sizeLabel: String {
        let bytes = library.statsTracks.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }
        return LibraryStats.formatBytes(bytes)
    }

    private func stat(_ text: String) -> some View {
        Text(text)
            .font(.custom("Avenir Next", size: 12).weight(.medium))
            .foregroundStyle(VTTheme.textSecondary)
    }

    private var separator: some View {
        Text("·")
            .font(.custom("Avenir Next", size: 12).weight(.bold))
            .foregroundStyle(VTTheme.textSecondary.opacity(0.45))
            .padding(.horizontal, 10)
    }
}

struct PlayerBar: View {
    @EnvironmentObject private var library: LibraryController
    @ObservedObject var playback: PlaybackController
    @ObservedObject private var artwork = ArtworkCache.shared

    var body: some View {
        if let track = playback.nowPlaying {
            HStack(spacing: 14) {
                CoverArtView(
                    artist: track.displayArtist,
                    album: track.displayAlbum,
                    fileURL: track.resolvedPath,
                    cornerRadius: 6
                )
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VTTheme.amber)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "Pausa" : "Riproduci")

                Button {
                    playback.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VTTheme.textPrimary.opacity(0.85))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Stop")

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(
                        text: track.displayTitle,
                        font: .custom("Avenir Next", size: 13).weight(.semibold),
                        color: VTTheme.textPrimary
                    )
                    MarqueeText(
                        text: track.displayArtist,
                        font: .custom("Avenir Next", size: 11),
                        color: VTTheme.textSecondary
                    )

                    GeometryReader { geo in
                        PlaybackScrubber(
                            playback: playback,
                            width: geo.size.width,
                            height: 6,
                            style: .playerBar
                        )
                    }
                    .frame(height: 10)
                    .padding(.top, 2)
                }
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                let liveStars = library.tracks.first(where: { $0.id == track.id })?.starRating ?? track.starRating
                let livePlays = library.tracks.first(where: { $0.id == track.id })?.playCount ?? track.playCount
                VStack(alignment: .trailing, spacing: 2) {
                    StarRatingControl(stars: liveStars, size: 12, interactive: true) { stars in
                        library.setStarRating(stars, for: [track.id])
                    }
                    if livePlays > 0 {
                        Text("\(livePlays) ascolti")
                            .font(.custom("Avenir Next", size: 10))
                            .foregroundStyle(VTTheme.textSecondary)
                    }
                }
                .help("Valutazione e ascolti")

                Text("\(playback.currentTimeLabel) / \(playback.durationLabel)")
                    .font(.custom("Avenir Next", size: 11).monospacedDigit())
                    .foregroundStyle(VTTheme.textSecondary)
                    .frame(minWidth: 84, alignment: .trailing)

                Button {
                    library.showiPodPreview = true
                } label: {
                    Image(systemName: "ipod")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VTTheme.amber)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(VTTheme.amberSoft)
                        )
                }
                .buttonStyle(.plain)
                .help("Apri iPod Now Playing")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(VTTheme.playerChrome)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(VTTheme.panelStroke, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                artwork.request(
                    artist: track.displayArtist,
                    album: track.displayAlbum,
                    fileURL: track.resolvedPath,
                    title: track.displayTitle
                )
            }
            .onChange(of: track.id) { _, _ in
                artwork.request(
                    artist: track.displayArtist,
                    album: track.displayAlbum,
                    fileURL: track.resolvedPath,
                    title: track.displayTitle
                )
            }
            .onChange(of: playback.nowPlaying?.id) { _, id in
                if id == nil {
                    library.showiPodPreview = false
                }
            }
        }
    }
}

// MARK: - Marquee (titolo / artista lunghi)

/// Scorre il testo solo se non entra nella larghezza disponibile.
private struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color
    /// Punti al secondo durante lo scorrimento.
    var speed: CGFloat = 32
    var gap: CGFloat = 40
    var leadPause: Double = 1.35
    var trailPause: Double = 0.85

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var runID = UUID()

    private var needsScroll: Bool {
        textWidth > containerWidth + 0.5 && containerWidth > 0 && textWidth > 0
    }

    var body: some View {
        // Altezza dalla riga statica; overlay scorre se serve.
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack(alignment: .leading) {
                        measureLabel
                        HStack(spacing: gap) {
                            visibleLabel
                            if needsScroll {
                                visibleLabel
                            }
                        }
                        .offset(x: offset)
                    }
                    .frame(width: width, alignment: .leading)
                    .clipped()
                    .onAppear {
                        containerWidth = width
                        restartLoop()
                    }
                    .onChange(of: width) { _, newWidth in
                        containerWidth = newWidth
                        restartLoop()
                    }
                }
            }
            .clipped()
            .onChange(of: text) { _, _ in
                offset = 0
                restartLoop()
            }
            .onDisappear {
                runID = UUID()
            }
    }

    private var visibleLabel: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var measureLabel: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .opacity(0)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(MarqueeWidthKey.self) { width in
                textWidth = width
                restartLoop()
            }
    }

    private func restartLoop() {
        let id = UUID()
        runID = id
        offset = 0
        guard needsScroll else { return }

        let travel = textWidth + gap
        let duration = Double(travel / max(speed, 1))

        Task { @MainActor in
            while !Task.isCancelled, runID == id {
                try? await Task.sleep(nanoseconds: UInt64(leadPause * 1_000_000_000))
                guard runID == id else { return }

                withAnimation(.linear(duration: duration)) {
                    offset = -travel
                }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard runID == id else { return }

                try? await Task.sleep(nanoseconds: UInt64(trailPause * 1_000_000_000))
                guard runID == id else { return }

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    offset = 0
                }
            }
        }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Scrubber condiviso (player bar + iPod)

enum ScrubberStyle {
    case playerBar
    case stockiPod
    case rockbox
}

struct PlaybackScrubber: View {
    @ObservedObject var playback: PlaybackController
    var width: CGFloat
    var height: CGFloat = 6
    var style: ScrubberStyle = .playerBar
    var scrubbingActive: Binding<Bool>? = nil

    @State private var dragProgress: Double?

    private var progress: Double {
        dragProgress ?? playback.progress
    }

    var body: some View {
        ZStack(alignment: .leading) {
            trackBackground
            trackFill
                .frame(width: max(style == .playerBar ? 4 : 2, width * progress))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    scrubbingActive?.wrappedValue = true
                    guard width > 0, playback.duration > 0 else { return }
                    let p = min(1, max(0, value.location.x / width))
                    dragProgress = p
                    playback.seek(toProgress: p)
                }
                .onEnded { value in
                    defer { scrubbingActive?.wrappedValue = false }
                    guard width > 0, playback.duration > 0 else {
                        dragProgress = nil
                        return
                    }
                    let p = min(1, max(0, value.location.x / width))
                    playback.seek(toProgress: p)
                    dragProgress = nil
                }
        )
        .help("Trascina per spostarti nel brano")
    }

    @ViewBuilder
    private var trackBackground: some View {
        switch style {
        case .playerBar:
            Capsule().fill(VTTheme.controlFill)
        case .stockiPod:
            // Barra rettangolare stile Classic (niente capsule)
            Rectangle()
                .fill(Color(red: 0.45, green: 0.48, blue: 0.52))
        case .rockbox:
            Rectangle().fill(Color.white.opacity(0.12))
        }
    }

    @ViewBuilder
    private var trackFill: some View {
        switch style {
        case .playerBar:
            Capsule().fill(VTTheme.amber)
        case .stockiPod:
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.72, blue: 0.98),
                            Color(red: 0.28, green: 0.48, blue: 0.92),
                            Color(red: 0.35, green: 0.55, blue: 0.95)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        case .rockbox:
            Rectangle().fill(Color(red: 0.25, green: 0.65, blue: 0.95))
        }
    }
}

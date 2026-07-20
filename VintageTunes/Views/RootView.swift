import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: LibraryController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        // VStack (non safeAreaInset): la Table/NSTableView di macOS ignora gli inset
        // e disegnava le ultime righe sotto stats/player.
        VStack(spacing: 0) {
            ZStack {
                VTTheme.background

                if library.connectedDevice == nil && !library.isLoading {
                    EmptyDeviceView()
                } else {
                    NavigationSplitView {
                        SidebarView()
                            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                    } detail: {
                        DetailContainer()
                    }
                    .navigationSplitViewStyle(.balanced)
                    .background(.clear)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LibraryStatsBar()
            PlayerBar(playback: library.playback)
        }
        .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
        .tint(VTTheme.amber)
        .onAppear { library.start(settings: settings) }
        .sheet(isPresented: Binding(
            get: { library.trackEditDraft != nil },
            set: { if !$0 { library.cancelTrackEdit() } }
        )) {
            TrackEditSheet()
                .environmentObject(library)
        }
        .sheet(isPresented: Binding(
            get: { library.autoSyncPrompt != nil },
            set: { if !$0 { library.dismissAutoSync() } }
        )) {
            AutoSyncConfirmSheet()
                .environmentObject(library)
        }
        .overlay(alignment: .bottom) {
            if case .idle = library.syncStatus {
                EmptyView()
            } else {
                StatusBanner(status: library.syncStatus) {
                    library.cancelImport()
                }
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomBannerPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: library.syncStatus)
        .overlay {
            if library.showiPodPreview, library.playback.nowPlaying != nil {
                ZStack {
                    // Backdrop invisibile: tap fuori chiude, senza alone nero
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            library.showiPodPreview = false
                        }

                    iPodNowPlayingOverlay()
                        .environmentObject(library)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: library.showiPodPreview)
    }

    private var bottomBannerPadding: CGFloat {
        let stats: CGFloat = library.connectedDevice == nil ? 0 : 36
        let player: CGFloat = library.playback.nowPlaying == nil ? 0 : 76
        return 16 + stats + player
    }
}

struct StatusBanner: View {
    let status: SyncStatus
    var onCancel: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch status {
                case .idle:
                    EmptyView()
                case .working:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VTTheme.lcdGreen)
                case .failure:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(VTTheme.amber)
                }
            }

            Text(message)
                .font(.custom("Avenir Next", size: 13).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if case .working = status, let onCancel {
                Button("Annulla") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.custom("Avenir Next", size: 12).weight(.bold))
                .foregroundStyle(VTTheme.amber)
                .padding(.leading, 4)
                .help("Interrompi import / conversione")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(
            Capsule(style: .continuous)
                .fill(bannerColor)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var message: String {
        switch status {
        case .idle: return ""
        case .working(let m), .success(let m), .failure(let m): return m
        }
    }

    private var bannerColor: Color {
        switch status {
        case .failure:
            return Color(red: 0.28, green: 0.12, blue: 0.10)
        case .success:
            return Color(red: 0.10, green: 0.22, blue: 0.14)
        default:
            return Color(red: 0.14, green: 0.15, blue: 0.18)
        }
    }
}

struct EmptyDeviceView: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        VStack(spacing: 28) {
            BrandMark()
                .scaleEffect(1.15)

            VStack(spacing: 14) {
                DemoiPodHeroView()
                    .frame(width: 220)
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 14)

                Text("Collega il tuo iPod")
                    .font(VTTheme.displayFont(size: 28))
                    .foregroundStyle(VTTheme.textPrimary)

                Text("VintageTunes riconosce automaticamente iPod Classic / Video\ncon firmware stock o Rockbox.")
                    .font(.custom("Avenir Next", size: 14))
                    .foregroundStyle(VTTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button {
                    library.refresh()
                } label: {
                    Label("Cerca dispositivi", systemImage: "arrow.triangle.2.circlepath")
                        .font(.custom("Avenir Next", size: 14).weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(VTTheme.amber)

                Button {
                    library.startDemo()
                } label: {
                    Label("Prova senza iPod", systemImage: "play.rectangle.on.rectangle")
                        .font(.custom("Avenir Next", size: 14).weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }

            Text("La demo crea un iPod virtuale sul Mac con 5 brani di prova.")
                .font(.custom("Avenir Next", size: 11))
                .foregroundStyle(VTTheme.textSecondary)
        }
        .padding(40)
    }
}

/// iPodBase con Now Playing statico (Lack of Color) — solo grafica, niente audio.
private struct DemoiPodHeroView: View {
    private enum Layout {
        static let screen = CGRect(x: 0.090, y: 0.054, width: 0.823, height: 0.369)
    }

    @State private var trackIndex = 1
    @State private var trackTotal = 18
    @State private var elapsed: TimeInterval = 72
    private let duration: TimeInterval = 3 * 60 + 36 // 3:36

    var body: some View {
        Image("iPodBase")
            .resizable()
            .aspectRatio(611 / 1024, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let screen = CGRect(
                        x: Layout.screen.origin.x * geo.size.width,
                        y: Layout.screen.origin.y * geo.size.height,
                        width: Layout.screen.width * geo.size.width,
                        height: Layout.screen.height * geo.size.height
                    )
                    DemoStockNowPlayingScreen(
                        trackIndex: trackIndex,
                        trackTotal: trackTotal,
                        elapsed: elapsed,
                        duration: duration
                    )
                    .frame(width: screen.width, height: screen.height)
                    .position(x: screen.midX, y: screen.midY)
                }
            }
            .allowsHitTesting(false)
            .onAppear { randomizePlaybackLook() }
    }

    private func randomizePlaybackLook() {
        trackTotal = Int.random(in: 5...220)
        trackIndex = Int.random(in: 1...trackTotal)
        // Evita estremi 0% / 100% così la barra si vede sempre “in corso”.
        elapsed = Double.random(in: 8...(duration - 8))
    }
}

private struct DemoStockNowPlayingScreen: View {
    let trackIndex: Int
    let trackTotal: Int
    let elapsed: TimeInterval
    let duration: TimeInterval

    private let ink = Color.black.opacity(0.92)
    private let lcdTop = Color(red: 0.93, green: 0.94, blue: 0.95)
    private let lcdBottom = Color(red: 0.82, green: 0.84, blue: 0.86)

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    private var remaining: TimeInterval { max(0, duration - elapsed) }

    var body: some View {
        ZStack {
            LinearGradient(colors: [lcdTop, lcdBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                Path { path in
                    stride(from: 0.0, through: geo.size.height, by: 2).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.black.opacity(0.035), lineWidth: 1)
            }

            VStack(spacing: 0) {
                header

                HStack(alignment: .top, spacing: 6) {
                    Image("DemoCoverTransatlanticism")
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(
                            Rectangle()
                                .stroke(Color.black.opacity(0.35), lineWidth: 0.6)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .padding(.top, 9)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Spacer(minLength: 0)
                            Image(systemName: "shuffle")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(ink.opacity(0.85))
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 1)

                        Text("A Lack of Color")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)

                        Text("Death Cab for Cutie")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text("Transatlanticism (10th Anniversary Edition)")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)

                        Text("\(trackIndex) of \(trackTotal)")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(ink)
                            .padding(.top, 3)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 5)
                .padding(.top, 2)

                Spacer(minLength: 4)

                progressBlock
                    .padding(.horizontal, 4)
                    .padding(.bottom, 10)
            }
        }
        .clipped()
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("Now Playing")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ink)
            Spacer()
            Image(systemName: "play.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.22, green: 0.42, blue: 0.88))
            // Batteria statica (stesso look dell’overlay reale)
            RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                .stroke(ink.opacity(0.75), lineWidth: 1)
                .frame(width: 18, height: 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 0.6, style: .continuous)
                        .fill(Color(red: 0.35, green: 0.72, blue: 0.38))
                        .padding(1.2)
                        .frame(width: 18 * 0.72)
                }
                .overlay(alignment: .trailing) {
                    Capsule()
                        .fill(ink.opacity(0.75))
                        .frame(width: 1.6, height: 3.5)
                        .offset(x: 2.2)
                }
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
    }

    private var progressBlock: some View {
        HStack(spacing: 4) {
            Text(Self.formatTime(elapsed))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(ink)
                .frame(minWidth: 28, alignment: .leading)

            GeometryReader { geo in
                let barHeight: CGFloat = 6
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(red: 0.45, green: 0.48, blue: 0.52))
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
                        .frame(width: max(2, geo.size.width * progress))
                }
                .frame(height: barHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)

            Text("-\(Self.formatTime(remaining))")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(ink)
                .frame(minWidth: 32, alignment: .trailing)
        }
        .padding(.horizontal, 2)
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct AutoSyncConfirmSheet: View {
    @EnvironmentObject private var library: LibraryController

    private var candidates: [AutoSyncCandidate] {
        library.autoSyncPrompt?.candidates ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nuove canzoni nella cartella sync")
                        .font(VTTheme.displayFont(size: 20))
                        .foregroundStyle(VTTheme.textPrimary)
                    Text(candidates.count == 1
                          ? "1 brano non è ancora sull’iPod."
                          : "\(candidates.count) brani non sono ancora sull’iPod.")
                        .font(.custom("Avenir Next", size: 13))
                        .foregroundStyle(VTTheme.textSecondary)
                }
                Spacer()
            }
            .padding(20)

            Divider().opacity(0.2)

            List(candidates) { candidate in
                HStack(spacing: 12) {
                    CoverArtView(
                        artist: candidate.displayArtist,
                        album: candidate.displayAlbum,
                        fileURL: candidate.url,
                        cornerRadius: 6
                    )
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.displayTitle)
                            .font(.custom("Avenir Next", size: 13).weight(.semibold))
                            .foregroundStyle(VTTheme.textPrimary)
                            .lineLimit(1)
                        Text("\(candidate.displayArtist) · \(candidate.displayAlbum)")
                            .font(.custom("Avenir Next", size: 11))
                            .foregroundStyle(VTTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if candidate.needsConversion {
                        Text("Conversione")
                            .font(.custom("Avenir Next", size: 10).weight(.bold))
                            .foregroundStyle(VTTheme.amber)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(VTTheme.amberSoft, in: Capsule())
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider().opacity(0.2)

            HStack {
                Button("Non ora") {
                    library.dismissAutoSync()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(candidates.count == 1 ? "Importa 1 canzone" : "Importa \(candidates.count) canzoni") {
                    library.confirmAutoSync()
                }
                .buttonStyle(.borderedProminent)
                .tint(VTTheme.amber)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
        .background(VTTheme.panel)
    }
}

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: LibraryController

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
        .preferredColorScheme(.dark)
        .tint(VTTheme.amber)
        .onAppear { library.start() }
        .alert(
            "Convertire in M4A?",
            isPresented: Binding(
                get: { library.conversionPrompt != nil },
                set: { newValue in
                    // I pulsanti gestiscono conferma/rifiuto; dismiss “vuoto” = annulla tutto.
                    if !newValue, library.conversionPrompt != nil {
                        library.cancelImport()
                    }
                }
            )
        ) {
            Button("Converti e trasferisci") {
                library.confirmConversion()
            }
            Button("Solo file compatibili") {
                library.declineConversion()
            }
            Button("Annulla", role: .cancel) {
                library.cancelImport()
            }
        } message: {
            Text(library.conversionPrompt?.message ?? "")
        }
        .sheet(isPresented: Binding(
            get: { library.trackEditDraft != nil },
            set: { if !$0 { library.cancelTrackEdit() } }
        )) {
            TrackEditSheet()
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
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            BrandMark()
                .scaleEffect(1.15)

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [VTTheme.steelTop, VTTheme.steelBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 160, height: 220)
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                        .scaleEffect(pulse ? 1.02 : 1.0)

                    VStack(spacing: 18) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(VTTheme.charcoal)
                            .frame(width: 110, height: 72)
                            .overlay {
                                Text("WAIT")
                                    .font(.custom("Avenir Next", size: 14).weight(.bold))
                                    .tracking(3)
                                    .foregroundStyle(VTTheme.lcdGreen.opacity(pulse ? 1 : 0.45))
                            }
                        Circle()
                            .stroke(VTTheme.charcoal.opacity(0.35), lineWidth: 10)
                            .frame(width: 70, height: 70)
                            .overlay {
                                Circle().fill(VTTheme.charcoal.opacity(0.2)).frame(width: 12, height: 12)
                            }
                    }
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

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

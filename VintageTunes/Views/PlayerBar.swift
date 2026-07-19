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
                    .fill(Color(red: 0.10, green: 0.11, blue: 0.13))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
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
            .foregroundStyle(Color.white.opacity(0.78))
    }

    private var separator: some View {
        Text("·")
            .font(.custom("Avenir Next", size: 12).weight(.bold))
            .foregroundStyle(Color.white.opacity(0.28))
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
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Stop")

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.displayTitle)
                        .font(.custom("Avenir Next", size: 13).weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(VTTheme.amber)
                                .frame(width: max(4, geo.size.width * playback.progress))
                        }
                    }
                    .frame(height: 4)
                }

                Text("\(playback.currentTimeLabel) / \(playback.durationLabel)")
                    .font(.custom("Avenir Next", size: 11).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.55))
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
                    .fill(Color(red: 0.12, green: 0.13, blue: 0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
            .onChange(of: playback.nowPlaying?.id) { _, id in
                if id == nil {
                    library.showiPodPreview = false
                }
            }
        }
    }
}

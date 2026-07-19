import SwiftUI

struct PlayerBar: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        if let track = playback.nowPlaying {
            HStack(spacing: 14) {
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
        }
    }
}

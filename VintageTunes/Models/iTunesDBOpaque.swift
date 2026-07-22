import Foundation

/// Opaque mhit header + MHOD types not managed by VintageTunes (types outside 1…6).
struct TrackDBBlob: Equatable, Hashable {
    var header: Data
    var extraMhods: [Data]
}

/// Opaque mhyp header + MHOD children other than the playlist name (type 1).
struct PlaylistDBBlob: Equatable, Hashable {
    var header: Data
    var extraMhods: [Data]
}

/// Top-level mhsd slot order preserved across rewrite.
enum iTunesDBMHSDSlot: Equatable, Hashable {
    case tracks
    case playlists
    /// Type-3 mirror of playlists (Music.app writes an identical copy).
    case podcastPlaylists
    /// Type-5 smart lists (Musica / Film / …) — firmware stock le usa per il menu Musica.
    case specialPlaylists
    /// Full mhsd chunk including its header (album lists, artist lists, type 9, etc.).
    case preserved(Data)
}

/// Session state kept between load and persist so unused iTunesDB sections survive.
struct iTunesDBSessionState: Equatable {
    var mhbdHeader: Data
    var mhsdLayout: [iTunesDBMHSDSlot]

    static var emptyNewDatabase: iTunesDBSessionState {
        iTunesDBSessionState(
            mhbdHeader: Data(),
            mhsdLayout: [.tracks, .podcastPlaylists, .playlists, .specialPlaylists]
        )
    }
}

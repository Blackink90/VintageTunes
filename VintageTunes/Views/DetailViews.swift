import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DetailContainer: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        Group {
            switch library.selectedSection {
            case .songs:
                TrackTableView(title: L10n.t("section.songs"))
            case .artists:
                ArtistsBrowserView()
            case .albums:
                AlbumsBrowserView()
            case .genres:
                GenresBrowserView()
            case .videos:
                VideosView()
            case .photos:
                PhotosView()
            case .playlists:
                PlaylistDetailView()
            case .dropZone:
                DropImportView()
            }
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    library.clearListSelection()
                }
        }
    }
}

struct TrackTableView: View {
    @EnvironmentObject private var library: LibraryController
    let title: String
    var showsBackButton: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            Table(of: Track.self, selection: $library.selection) {
                TableColumn("") { track in
                    CoverArtView(
                        artist: track.displayArtist,
                        album: track.displayAlbum,
                        fileURL: track.resolvedPath,
                        title: track.displayTitle,
                        cornerRadius: 4
                    )
                    .frame(width: 28, height: 28)
                }
                .width(36)

                TableColumn(L10n.t("table.column_title")) { track in
                    HStack(spacing: 6) {
                        if library.playback.nowPlaying?.id == track.id {
                            Image(systemName: library.playback.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(VTTheme.amber)
                        }
                        Text(track.displayTitle)
                            .font(.custom("Avenir Next", size: 13))
                            .foregroundStyle(VTTheme.textPrimary)
                    }
                }
                .width(min: 160, ideal: 220)

                TableColumn(L10n.t("table.column_artist")) { track in
                    Text(track.displayArtist)
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(min: 120, ideal: 160)

                TableColumn(L10n.t("table.column_album")) { track in
                    Text(track.displayAlbum)
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(min: 120, ideal: 160)

                TableColumn(L10n.t("table.column_genre")) { track in
                    Text(track.displayGenre)
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(min: 90, ideal: 120)

                TableColumn(L10n.t("table.column_year")) { track in
                    Text(track.displayYear)
                        .monospacedDigit()
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(56)

                TableColumn("★") { track in
                    StarRatingControl(
                        stars: track.starRating,
                        size: 11,
                        interactive: true
                    ) { stars in
                        library.setStarRating(stars, for: [track.id])
                    }
                }
                .width(88)

                TableColumn(L10n.t("table.column_plays")) { track in
                    Text(track.displayPlayCount)
                        .monospacedDigit()
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(56)

                TableColumn(L10n.t("table.column_duration")) { track in
                    Text(track.durationLabel)
                        .monospacedDigit()
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(60)
            } rows: {
                ForEach(library.filteredTracks) { track in
                    TableRow(track)
                }
            }
            .id(library.tracksListEpoch)
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .background(VTTheme.tableBackground)
            .foregroundStyle(VTTheme.textPrimary)
            .onNativeTableDoubleClick(onEmptyClick: {
                library.clearListSelection()
            }) { row in
                // Preferisci la selezione (ID): l’indice riga della NSTableView può non allinearsi a filteredTracks.
                if let id = library.selection.first,
                   let track = library.filteredTracks.first(where: { $0.id == id })
                    ?? library.tracks.first(where: { $0.id == id }) {
                    library.playTrack(track)
                    return
                }
                let list = library.filteredTracks
                guard list.indices.contains(row) else { return }
                let track = list[row]
                library.selection = [track.id]
                library.playTrack(track)
            }
            .dropDestination(for: URL.self) { urls, _ in
                if library.selectedSection == .videos {
                    library.importDroppedVideos(urls)
                } else {
                    library.importDroppedURLs(urls)
                }
                return true
            }
            .contextMenu(forSelectionType: Track.ID.self) { ids in
                if !ids.isEmpty {
                    Button(L10n.t("track.play")) {
                        if let id = ids.first, let track = library.tracks.first(where: { $0.id == id }) {
                            library.playTrack(track)
                        }
                    }
                    Button(L10n.t("track.edit_info")) {
                        library.beginEditingTracks(ids: Array(ids))
                    }
                    Menu(L10n.t("track.rating_menu")) {
                        Button(L10n.t("track.rating_none")) {
                            library.setStarRating(0, for: Array(ids))
                        }
                        ForEach(1...5, id: \.self) { stars in
                            Button(String(repeating: "★", count: stars)) {
                                library.setStarRating(stars, for: Array(ids))
                            }
                        }
                    }
                    Button(L10n.t("track.reload_artwork")) {
                        library.refreshArtwork(for: Array(ids))
                    }
                    Button(L10n.t("track.show_in_finder")) {
                        library.selection = Set(ids)
                        library.revealSelectedTracksInFinder()
                    }
                    Menu(L10n.t("track.add_to_playlist")) {
                        ForEach(library.sidebarPlaylists) { playlist in
                            Button(playlist.displayName) {
                                library.selection = Set(ids)
                                library.addSelectionToPlaylist(playlist.id)
                            }
                        }
                    }
                    if library.selectedSection == .playlists,
                       let pid = library.selectedPlaylistID,
                       let current = library.playlists.first(where: { $0.id == pid }),
                       !current.isMaster {
                        Button(L10n.t("track.remove_from_playlist")) {
                            library.selection = Set(ids)
                            library.removeSelectionFromCurrentPlaylist()
                        }
                    }
                    Button(L10n.t("track.delete_from_ipod"), role: .destructive) {
                        library.selection = Set(ids)
                        library.requestDeleteSelectedTracks()
                    }
                }
            }
            .onKeyPress(.space) {
                library.playSelectedOrToggle()
                return .handled
            }
            .onKeyPress(.return) {
                if let id = library.selection.first,
                   let track = library.tracks.first(where: { $0.id == id }) {
                    library.playTrack(track)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.escape) {
                if library.selection.isEmpty { return .ignored }
                library.clearListSelection()
                return .handled
            }
        }
    }

    private var header: some View {
        HStack {
            if showsBackButton {
                Button {
                    library.browseBack()
                } label: {
                    Label(L10n.t("common.back"), systemImage: "chevron.left")
                        .font(.custom("Avenir Next", size: 13).weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(VTTheme.amber)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(VTTheme.displayFont(size: 24))
                    .foregroundStyle(VTTheme.textPrimary)
                Text(LibraryStats.trackCountLabel(library.filteredTracks.count))
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(VTTheme.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                library.clearListSelection()
            }
            Spacer()
            TextField(L10n.t("common.search"), text: $library.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .padding(16)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    library.clearListSelection()
                }
        }
    }
}

struct ArtistsBrowserView: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        if let album = library.browseAlbum {
            TrackTableView(title: album.name, showsBackButton: true)
        } else if let artist = library.browseArtist {
            AlbumGridView(
                title: artist,
                subtitle: L10n.tf("browse.album_count", library.albums(forArtist: artist).count),
                albums: library.albums(forArtist: artist),
                showsBackButton: true,
                showsArtistOnTile: false
            )
        } else {
            ArtistListView()
        }
    }
}

struct AlbumsBrowserView: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        if let album = library.browseAlbum {
            TrackTableView(title: album.name, showsBackButton: true)
        } else {
            AlbumGridView(
                title: L10n.t("section.albums"),
                subtitle: L10n.tf("browse.album_count", library.albums.count),
                albums: library.albums,
                showsBackButton: false,
                showsArtistOnTile: true
            )
        }
    }
}

struct GenresBrowserView: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        if library.browseGenre != nil, let artist = library.browseArtist {
            TrackTableView(title: artist, showsBackButton: true)
        } else if let genre = library.browseGenre {
            ArtistListView(
                title: genre,
                subtitle: L10n.tf("browse.artist_count", library.artists(forGenre: genre).count),
                artists: library.artists(forGenre: genre),
                showsBackButton: true,
                genreFilter: genre
            )
        } else {
            GenreGridView()
        }
    }
}

struct ArtistListView: View {
    @EnvironmentObject private var library: LibraryController
    var title: String = L10n.t("section.artists")
    var subtitle: String? = nil
    var artists: [(name: String, count: Int)]? = nil
    var showsBackButton: Bool = false
    var genreFilter: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if showsBackButton {
                    Button {
                        library.browseBack()
                    } label: {
                        Label(L10n.t("common.back"), systemImage: "chevron.left")
                            .font(.custom("Avenir Next", size: 13).weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(VTTheme.amber)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(VTTheme.displayFont(size: 24))
                        .foregroundStyle(VTTheme.textPrimary)
                    Text(subtitle ?? L10n.tf("browse.artist_count", rows.count))
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(VTTheme.textSecondary)
                }
                Spacer()
                TextField(L10n.t("common.search"), text: $library.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(16)

            Divider().opacity(0.2)

            List(filteredArtists, id: \.name) { artist in
                Button {
                    library.openArtist(artist.name)
                } label: {
                    HStack(spacing: 12) {
                        ArtistAvatar(
                            name: artist.name,
                            track: library.representativeTrack(forArtist: artist.name, genre: genreFilter)
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name)
                                .font(.custom("Avenir Next", size: 14).weight(.medium))
                                .foregroundStyle(VTTheme.textPrimary)
                            Text(LibraryStats.trackCountLabel(artist.count))
                                .font(.custom("Avenir Next", size: 12))
                                .foregroundStyle(VTTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(VTTheme.textSecondary.opacity(0.5))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var rows: [(name: String, count: Int)] {
        artists ?? library.artists
    }

    private var filteredArtists: [(name: String, count: Int)] {
        let q = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}

struct GenreGridView: View {
    @EnvironmentObject private var library: LibraryController

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("section.genres"))
                        .font(VTTheme.displayFont(size: 24))
                        .foregroundStyle(VTTheme.textPrimary)
                    Text(L10n.tf("browse.genre_count", filteredGenres.count))
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(VTTheme.textSecondary)
                }
                Spacer()
                TextField(L10n.t("common.search"), text: $library.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(16)

            Divider().opacity(0.2)

            if filteredGenres.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "guitars")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(VTTheme.amber)
                    Text(L10n.t("genres.empty_title"))
                        .font(.custom("Avenir Next", size: 14).weight(.medium))
                        .foregroundStyle(VTTheme.textSecondary)
                    Text(L10n.t("genres.empty_body"))
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(VTTheme.textSecondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(filteredGenres) { genre in
                            Button {
                                library.openGenre(genre.name)
                            } label: {
                                GenreTile(genre: genre)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var filteredGenres: [GenreRef] {
        let q = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return library.genres }
        return library.genres.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}

struct GenreTile: View {
    let genre: GenreRef

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: genreGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Texture leggera
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)

                VStack(spacing: 6) {
                    Image(systemName: "guitars")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(genre.name)
                        .font(.custom("Avenir Next", size: 13).weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 10)
                }
            }
            .frame(width: 120, height: 120)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            VStack(spacing: 2) {
                Text(genre.name)
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                    .foregroundStyle(VTTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(L10n.tf(
                    "genres.row_subtitle",
                    genre.artistCount,
                    LibraryStats.trackCountLabel(genre.trackCount)
                ))
                    .font(.custom("Avenir Next", size: 10))
                    .foregroundStyle(VTTheme.textSecondary.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(width: 120)
        }
    }

    /// Palette stabile derivata dal nome del genere (sempre uguale per lo stesso genere).
    private var genreGradient: [Color] {
        let palette: [[Color]] = [
            [Color(red: 0.45, green: 0.22, blue: 0.18), Color(red: 0.18, green: 0.10, blue: 0.10)],
            [Color(red: 0.20, green: 0.32, blue: 0.42), Color(red: 0.10, green: 0.14, blue: 0.22)],
            [Color(red: 0.28, green: 0.36, blue: 0.22), Color(red: 0.12, green: 0.16, blue: 0.10)],
            [Color(red: 0.38, green: 0.24, blue: 0.40), Color(red: 0.16, green: 0.10, blue: 0.20)],
            [Color(red: 0.42, green: 0.30, blue: 0.16), Color(red: 0.18, green: 0.12, blue: 0.08)],
            [Color(red: 0.18, green: 0.34, blue: 0.36), Color(red: 0.08, green: 0.14, blue: 0.18)]
        ]
        let idx = abs(stableHash(genre.name)) % palette.count
        return palette[idx]
    }

    private func stableHash(_ string: String) -> Int {
        var hash = 0
        for char in string.lowercased().unicodeScalars {
            hash = (hash &* 31) &+ Int(char.value)
        }
        return hash
    }
}

struct AlbumGridView: View {
    @EnvironmentObject private var library: LibraryController
    let title: String
    let subtitle: String
    let albums: [AlbumRef]
    var showsBackButton: Bool
    var showsArtistOnTile: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if showsBackButton {
                    Button {
                        library.browseBack()
                    } label: {
                        Label(L10n.t("common.back"), systemImage: "chevron.left")
                            .font(.custom("Avenir Next", size: 13).weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(VTTheme.amber)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(VTTheme.displayFont(size: 24))
                        .foregroundStyle(VTTheme.textPrimary)
                    Text(subtitle)
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(VTTheme.textSecondary)
                }
                Spacer()
                TextField(L10n.t("common.search"), text: $library.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(16)

            Divider().opacity(0.2)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(filteredAlbums) { album in
                        Button {
                            library.openAlbum(album)
                        } label: {
                            AlbumTile(
                                album: album,
                                showsArtist: showsArtistOnTile,
                                track: library.representativeTrack(for: album)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { library.clearListSelection() }
            }
        }
    }

    private var filteredAlbums: [AlbumRef] {
        let q = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return albums }
        return albums.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }
}

struct AlbumTile: View {
    @ObservedObject private var artwork = ArtworkCache.shared
    let album: AlbumRef
    let showsArtist: Bool
    let track: Track?

    var body: some View {
        VStack(spacing: 8) {
            CoverArtView(
                artist: album.artist,
                album: album.name,
                fileURL: track?.resolvedPath,
                cornerRadius: 8
            )
            .frame(width: 120, height: 120)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            VStack(spacing: 2) {
                Text(album.name)
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                    .foregroundStyle(VTTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if showsArtist {
                    Text(album.artist)
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(VTTheme.textSecondary)
                        .lineLimit(1)
                }
                Text(LibraryStats.trackCountLabel(album.trackCount))
                    .font(.custom("Avenir Next", size: 10))
                    .foregroundStyle(VTTheme.textSecondary.opacity(0.75))
            }
            .frame(width: 120)
        }
        .onAppear {
            artwork.request(artist: album.artist, album: album.name, fileURL: track?.resolvedPath)
        }
    }
}

struct ArtistAvatar: View {
    let name: String
    let track: Track?

    var body: some View {
        CoverArtView(
            artist: track?.displayArtist ?? name,
            album: track?.displayAlbum ?? "",
            fileURL: track?.resolvedPath,
            cornerRadius: 20,
            placeholderSystemImage: "person.fill",
            isCircle: true
        )
        .frame(width: 40, height: 40)
    }
}

struct CoverArtView: View {
    @ObservedObject private var artwork = ArtworkCache.shared
    let artist: String
    let album: String
    let fileURL: URL?
    var title: String? = nil
    var cornerRadius: CGFloat = 6
    var placeholderSystemImage: String = "music.note"
    var isCircle: Bool = false

    var body: some View {
        Group {
            if isCircle {
                content.clipShape(Circle())
            } else {
                content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .onAppear {
            requestArtwork()
        }
    }

    private var content: some View {
        ZStack {
            Group {
                if isCircle {
                    Circle().fill(placeholderFill)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(placeholderFill)
                }
            }

            if let image = resolvedImage, image.size.width > 0 {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: isCircle ? 14 : 22, weight: .light))
                    .foregroundStyle(VTTheme.textSecondary.opacity(0.55))
            }
        }
    }

    private var placeholderFill: LinearGradient {
        LinearGradient(
            colors: [
                VTTheme.controlFill,
                VTTheme.panel
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var resolvedImage: NSImage? {
        if !album.isEmpty, let img = artwork.image(artist: artist, album: album) {
            return img
        }
        return nil
    }

    private func requestArtwork() {
        guard !album.isEmpty else { return }
        artwork.request(artist: artist, album: album, fileURL: fileURL, title: title)
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryController

    private var playlist: Playlist? {
        library.playlists.first { $0.id == library.selectedPlaylistID }
    }

    var body: some View {
        if let playlist {
            TrackTableView(title: playlist.displayName)
                .toolbar {
                    ToolbarItemGroup {
                        Button(L10n.t("track.remove_from_playlist")) {
                            library.removeSelectionFromCurrentPlaylist()
                        }
                        .disabled(library.selection.isEmpty || playlist.isMaster)
                    }
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(VTTheme.amber)
                Text(L10n.t("playlists.empty_title"))
                    .font(VTTheme.displayFont(size: 22))
                Text(L10n.t("playlists.empty_body"))
                    .foregroundStyle(VTTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct VideosView: View {
    @EnvironmentObject private var library: LibraryController
    @State private var isTargeted = false

    var body: some View {
        Group {
            if library.videoTracks.isEmpty {
                emptyState
            } else {
                TrackTableView(title: L10n.t("section.videos"))
            }
        }
        .background(Color.clear)
        .overlay(alignment: .topTrailing) {
            if isTargeted {
                Text(L10n.t("videos.drop_hint"))
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                    .foregroundStyle(VTTheme.amber)
                    .padding(16)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.importDroppedVideos(urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .toolbar {
            ToolbarItemGroup {
                Button(L10n.t("videos.add")) {
                    library.chooseVideosToImport()
                }
                Button(L10n.t("track.delete_from_ipod"), role: .destructive) {
                    library.requestDeleteSelectedTracks()
                }
                .disabled(library.selection.isEmpty)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(VTTheme.amber)
            Text(L10n.t("videos.empty_title"))
                .font(VTTheme.displayFont(size: 22))
            Text(L10n.t("videos.empty_body"))
                .font(.custom("Avenir Next", size: 13))
                .foregroundStyle(VTTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text(L10n.t("videos.ffmpeg_required"))
                .font(.custom("Avenir Next", size: 11))
                .foregroundStyle(VTTheme.textSecondary.opacity(0.85))
            Button(L10n.t("videos.add")) {
                library.chooseVideosToImport()
            }
            .buttonStyle(.borderedProminent)
            .tint(VTTheme.amber)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct PhotosView: View {
    @EnvironmentObject private var library: LibraryController
    @State private var isTargeted = false

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if library.photos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(library.photos) { photo in
                            photoCell(photo)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            library.importPhotos(urls: urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .toolbar {
            ToolbarItemGroup {
                Button(L10n.t("photos.add")) {
                    library.choosePhotosToImport()
                }
                Button(L10n.t("common.delete"), role: .destructive) {
                    library.deleteSelectedPhotos()
                }
                .disabled(library.photoSelection.isEmpty)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(library.photoAlbumName)
                    .font(VTTheme.displayFont(size: 24))
                    .foregroundStyle(VTTheme.textPrimary)
                Text(library.photos.count == 1
                        ? L10n.t("photos.count_one")
                        : L10n.tf("photos.count_many", library.photos.count))
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(VTTheme.textSecondary)
            }
            Spacer()
            if isTargeted {
                Text(L10n.t("photos.drop_hint"))
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                    .foregroundStyle(VTTheme.amber)
            }
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(VTTheme.amber)
            Text(L10n.t("photos.empty_title"))
                .font(VTTheme.displayFont(size: 22))
            Text(L10n.t("photos.empty_body"))
                .font(.custom("Avenir Next", size: 13))
                .foregroundStyle(VTTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(L10n.t("photos.add")) {
                library.choosePhotosToImport()
            }
            .buttonStyle(.borderedProminent)
            .tint(VTTheme.amber)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func photoCell(_ photo: DevicePhoto) -> some View {
        let selected = library.photoSelection.contains(photo.id)
        return Button {
            if library.photoSelection.contains(photo.id) {
                library.photoSelection.remove(photo.id)
            } else {
                library.photoSelection.insert(photo.id)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VTTheme.panel)
                    if let data = photo.previewJPEG, let ns = NSImage(data: data) {
                        Image(nsImage: ns)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(VTTheme.textSecondary)
                    }
                }
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? VTTheme.amber : Color.clear, lineWidth: 2)
                )

                Text(photo.title)
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(VTTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.t("common.delete"), role: .destructive) {
                library.photoSelection = [photo.id]
                library.deleteSelectedPhotos()
            }
        }
    }
}

struct DropImportView: View {
    @EnvironmentObject private var library: LibraryController
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.t("dropzone.title"))
                .font(VTTheme.displayFont(size: 28))

            Text(L10n.t("dropzone.body"))
                .font(.custom("Avenir Next", size: 14))
                .foregroundStyle(VTTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        VTTheme.amber.opacity(isTargeted ? 0.95 : 0.35),
                        style: StrokeStyle(lineWidth: 2, dash: [10, 8])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(VTTheme.amber.opacity(isTargeted ? 0.12 : 0.04))
                    )
                    .frame(maxWidth: 560, minHeight: 260)

                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(VTTheme.amber)
                        .symbolEffect(.pulse, options: .repeating, isActive: isTargeted)
                    Text(isTargeted ? L10n.t("dropzone.release_to_sync") : L10n.t("dropzone.files_or_folders"))
                        .font(.custom("Avenir Next", size: 16).weight(.semibold))
                    Text(L10n.t("dropzone.formats"))
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(VTTheme.textSecondary)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                library.importDroppedURLs(urls)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }

            Button {
                library.chooseFolderToImport()
            } label: {
                Label(L10n.t("dropzone.choose_folder"), systemImage: "folder")
                    .font(.custom("Avenir Next", size: 14).weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(VTTheme.amber)
            .disabled(library.connectedDevice == nil)

            Text(L10n.t("dropzone.playlist_hint"))
                .font(.custom("Avenir Next", size: 12))
                .foregroundStyle(VTTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct SettingsWindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryController
    @EnvironmentObject private var settings: AppSettings
    @State private var deviceNameDraft = ""

    var body: some View {
        Form {
            Section(L10n.t("language.section")) {
                Picker(L10n.t("language.section"), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                Text(L10n.t("language.help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.t("language.restart_hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.appearance")) {
                Picker(L10n.t("settings.theme"), selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(L10n.t("settings.theme_help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.ipod_access")) {
                Text(L10n.t("settings.signing_help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.t("settings.removable_volumes_help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.sync")) {
                Picker(L10n.t("settings.sync_mode"), selection: $settings.syncMode) {
                    ForEach(SyncMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.syncMode) { _, mode in
                    library.refreshAutoSyncWatching()
                    if mode == .automatic {
                        library.checkAutoSync()
                    }
                }

                if settings.syncMode == .automatic {
                    HStack(spacing: 8) {
                        TextField(
                            L10n.t("settings.sync_folder_placeholder"),
                            text: Binding(
                                get: { settings.syncFolderDisplayPath ?? "" },
                                set: { newValue in
                                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if trimmed.isEmpty {
                                        settings.clearSyncFolder()
                                        library.refreshAutoSyncWatching()
                                    }
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .help(L10n.t("settings.sync_folder_help"))

                        Button(L10n.t("settings.browse")) {
                            // Aspetta il ciclo UI: un NSOpenPanel dentro Settings altrimenti fallisce spesso.
                            DispatchQueue.main.async {
                                if settings.chooseSyncFolder() {
                                    library.refreshAutoSyncWatching()
                                    library.checkAutoSync()
                                }
                            }
                        }
                        .help(L10n.t("settings.choose_sync_folder_help"))
                    }

                    if settings.hasSyncFolder {
                        HStack {
                            Spacer()
                            Button(L10n.t("settings.remove_folder"), role: .destructive) {
                                settings.clearSyncFolder()
                                library.refreshAutoSyncWatching()
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Text(L10n.t("settings.sync_folder_empty_help"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Text(L10n.t("settings.sync_watch_help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("settings.sync_manual_help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("settings.device")) {
                if let device = library.connectedDevice {
                    HStack(spacing: 8) {
                        TextField(L10n.t("settings.device_name"), text: $deviceNameDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyDeviceName() }
                        Button(L10n.t("settings.rename")) {
                            applyDeviceName()
                        }
                        .disabled(
                            deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == device.name
                        )
                    }
                    Text(L10n.t("settings.rename_help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    LabeledContent(L10n.t("settings.model"), value: device.modelHint)
                    LabeledContent(
                        L10n.t("settings.firmware"),
                        value: device.isSimulated
                            ? L10n.t("settings.firmware_simulated")
                            : (device.firmwareMode == .rockbox
                                ? L10n.t("device.firmware_rockbox")
                                : L10n.t("settings.firmware_stock_apple"))
                    )
                    LabeledContent(
                        L10n.t("settings.database"),
                        value: device.hasDatabase
                            ? L10n.t("settings.database_present")
                            : L10n.t("settings.database_absent")
                    )
                    if device.isSimulated {
                        Button(L10n.t("settings.reset_demo")) { library.startDemo(reset: true) }
                        Button(L10n.t("settings.show_demo_folder")) { library.revealDemoFolder() }
                    }
                    Button(L10n.t("settings.show_converted")) { library.revealConvertedFolder() }
                    Button(L10n.t("settings.show_ipod_music")) { library.revealMusicFolder() }
                    Button(L10n.t("settings.repair_metadata")) {
                        library.repairLibraryPlaybackMetadata()
                    }
                    .disabled(library.isImportRunning || library.isEjecting)
                    Text(L10n.t("settings.repair_metadata_help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("settings.no_device"))
                    Button(L10n.t("settings.start_demo")) { library.startDemo() }
                }
            }

            Section(L10n.t("settings.backup_restore")) {
                Text(L10n.t("settings.backup_help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.t("settings.full_backup")) {
                    DispatchQueue.main.async {
                        library.createFullVolumeBackup()
                    }
                }
                .disabled(library.connectedDevice == nil || library.connectedDevice?.isSimulated == true || library.isImportRunning || library.isEjecting)

                Button(L10n.t("settings.full_restore"), role: .destructive) {
                    DispatchQueue.main.async {
                        library.chooseFullVolumeRestore()
                    }
                }
                .disabled(library.connectedDevice == nil || library.connectedDevice?.isSimulated == true || library.isImportRunning || library.isEjecting)

                Text(L10n.t("settings.restore_help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.audio_formats")) {
                Text(L10n.t("settings.formats_supported"))
                    .foregroundStyle(.secondary)
                Text(L10n.t("settings.formats_unsupported"))
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.audio_conversion")) {
                Picker(L10n.t("settings.ask_conversion"), selection: $settings.flacConversionAskMode) {
                    ForEach(FlacConversionAskMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.flacConversionAskMode.helpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker(L10n.t("settings.conversion_format"), selection: $settings.flacConversionFormat) {
                    ForEach(FlacConversionFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Text(
                    settings.flacConversionAskMode == .always
                        ? L10n.t("settings.conversion_always_detail")
                        : settings.flacConversionAskMode == .ask
                            ? L10n.t("settings.conversion_ask_detail")
                            : L10n.t("settings.conversion_never_detail")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.notes")) {
                Text(L10n.t("settings.notes_body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 800)
        .background(SettingsWindowTitleSetter(title: L10n.t("settings.window_title")))
        .onAppear { syncDeviceNameDraft() }
        .onChange(of: library.connectedDevice?.id) { _, _ in syncDeviceNameDraft() }
        .onChange(of: library.connectedDevice?.name) { _, _ in syncDeviceNameDraft() }
        .confirmationDialog(
            L10n.t("restore.confirm_title"),
            isPresented: Binding(
                get: { library.pendingRestore != nil },
                set: { if !$0 { library.cancelPendingRestore() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("restore.confirm_action"), role: .destructive) {
                library.confirmFullVolumeRestore()
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                library.cancelPendingRestore()
            }
        } message: {
            if let pending = library.pendingRestore {
                Text(L10n.tf("restore.confirm_message", pending.summary))
            }
        }
    }

    private func syncDeviceNameDraft() {
        deviceNameDraft = library.connectedDevice?.name ?? ""
    }

    private func applyDeviceName() {
        library.renameConnectedDevice(to: deviceNameDraft)
        syncDeviceNameDraft()
    }
}

struct TrackEditSheet: View {
    @EnvironmentObject private var library: LibraryController
    @FocusState private var focusedField: Field?
    @State private var isLoadingCoverFromURL = false

    private enum Field: Hashable {
        case title, artist, album, genre, trackNumber, year, cover
    }

    private var draft: TrackEditDraft? { library.trackEditDraft }
    private var isMulti: Bool { draft?.isMulti == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(VTTheme.displayFont(size: 20))
                Spacer()
            }
            .padding(20)

            Divider().opacity(0.2)

            if let draft {
                Form {
                    if !draft.isMulti {
                        TextField(L10n.t("track_edit.field_title"), text: draftBinding(\.title))
                            .focused($focusedField, equals: .title)
                    }

                    TextField(
                        L10n.t("track_edit.field_artist"),
                        text: draftBinding(\.artist),
                        prompt: prompt(mixed: draft.mixedArtist, current: draft.artist)
                    )
                    .focused($focusedField, equals: .artist)

                    TextField(
                        L10n.t("track_edit.field_album"),
                        text: draftBinding(\.album),
                        prompt: prompt(mixed: draft.mixedAlbum, current: draft.album)
                    )
                    .focused($focusedField, equals: .album)

                    TextField(
                        L10n.t("track_edit.field_genre"),
                        text: draftBinding(\.genre),
                        prompt: prompt(mixed: draft.mixedGenre, current: draft.genre)
                    )
                    .focused($focusedField, equals: .genre)

                    TextField(
                        L10n.t("track_edit.field_track_number"),
                        text: draftBinding(\.trackNumber),
                        prompt: prompt(mixed: draft.mixedTrackNumber, current: draft.trackNumber)
                    )
                    .focused($focusedField, equals: .trackNumber)

                    TextField(
                        L10n.t("track_edit.field_year"),
                        text: draftBinding(\.year),
                        prompt: prompt(mixed: draft.mixedYear, current: draft.year)
                    )
                    .focused($focusedField, equals: .year)

                    LabeledContent(L10n.t("track_edit.field_rating")) {
                        HStack(spacing: 10) {
                            if draft.mixedRating {
                                Text(L10n.t("track_edit.mixed_values"))
                                    .font(.custom("Avenir Next", size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            StarRatingControl(
                                stars: draft.mixedRating ? 0 : draft.starRating,
                                size: 16,
                                interactive: true
                            ) { stars in
                                library.trackEditDraft?.starRating = stars
                                library.trackEditDraft?.mixedRating = false
                            }
                            if !draft.mixedRating, draft.starRating > 0 {
                                Button(L10n.t("track_edit.clear_rating")) {
                                    library.trackEditDraft?.starRating = 0
                                    library.trackEditDraft?.mixedRating = false
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    LabeledContent(L10n.t("track_edit.artwork")) {
                        HStack(alignment: .center, spacing: 12) {
                            coverThumbnail(for: draft)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(
                                            focusedField == .cover ? VTTheme.amber : Color.primary.opacity(0.12),
                                            lineWidth: focusedField == .cover ? 2.5 : 1
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .focusable()
                                .focused($focusedField, equals: .cover)
                                .onTapGesture {
                                    focusedField = .cover
                                }
                                .accessibilityLabel(L10n.t("track_edit.artwork"))
                                .accessibilityHint(L10n.t("track_edit.artwork_a11y_hint"))
                                .onPasteCommand(of: [.url, .text, .plainText]) { providers in
                                    guard focusedField == .cover else { return }
                                    handlePasteProviders(providers)
                                }

                            VStack(alignment: .leading, spacing: 6) {
                                if isLoadingCoverFromURL {
                                    Text(L10n.t("track_edit.downloading_image"))
                                        .font(.custom("Avenir Next", size: 12))
                                        .foregroundStyle(.secondary)
                                } else if let name = draft.coverFileName, draft.coverImageData != nil, !draft.removeManualCover {
                                    Text(name)
                                        .font(.custom("Avenir Next", size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(L10n.t("track_edit.cover_priority_hint"))
                                        .font(.custom("Avenir Next", size: 10))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text(draft.isMulti
                                          ? L10n.t("track_edit.same_cover_multi")
                                          : L10n.t("track_edit.no_custom_cover"))
                                        .font(.custom("Avenir Next", size: 12))
                                        .foregroundStyle(.secondary)
                                    Text(L10n.t("track_edit.paste_url_hint"))
                                        .font(.custom("Avenir Next", size: 10))
                                        .foregroundStyle(.tertiary)
                                }

                                HStack(spacing: 10) {
                                    Button(L10n.t("track_edit.choose_file")) {
                                        focusedField = .cover
                                        pickCoverImage()
                                    }
                                    .buttonStyle(.borderless)

                                    if draft.coverImageData != nil, !draft.removeManualCover {
                                        Button(L10n.t("common.remove")) {
                                            library.trackEditDraft?.coverImageData = nil
                                            library.trackEditDraft?.coverFileName = nil
                                            library.trackEditDraft?.removeManualCover = true
                                            library.trackEditDraft?.coverDidChange = true
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .padding(.horizontal, 8)
            }

            HStack {
                Spacer()
                Button(L10n.t("common.cancel")) {
                    library.cancelTrackEdit()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.t("common.save")) {
                    library.saveTrackEdit()
                }
                .buttonStyle(.borderedProminent)
                .tint(VTTheme.amber)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 460, height: isMulti ? 460 : 500)
        .onAppear {
            focusedField = isMulti ? .artist : .title
        }
        .onKeyPress(keys: [.init("v")], phases: .down) { press in
            guard focusedField == .cover, press.modifiers.contains(.command) else {
                return .ignored
            }
            pasteCoverFromClipboard()
            return .handled
        }
    }

    @ViewBuilder
    private func coverThumbnail(for draft: TrackEditDraft) -> some View {
        if !draft.removeManualCover, let data = draft.coverImageData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(VTTheme.controlFill)
                Image(systemName: "music.note")
                    .foregroundStyle(VTTheme.textSecondary.opacity(0.55))
            }
        }
    }

    private func pasteCoverFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first {
            Task { await applyCover(from: url) }
            return
        }
        let raw = (pb.string(forType: .URL) ?? pb.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            library.setStatus(.failure(L10n.t("track_edit.clipboard_no_url")))
            return
        }
        Task { await applyCover(from: url) }
    }

    private func handlePasteProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    Task { @MainActor in
                        await applyCover(from: url)
                    }
                }
                return
            }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { object, _ in
                    guard let raw = (object as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          let url = URL(string: raw) else { return }
                    Task { @MainActor in
                        await applyCover(from: url)
                    }
                }
                return
            }
        }
    }

    @MainActor
    private func applyCover(from url: URL) async {
        isLoadingCoverFromURL = true
        defer { isLoadingCoverFromURL = false }

        do {
            let data: Data
            if url.isFileURL {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                data = try Data(contentsOf: url)
            } else {
                let (downloaded, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    library.setStatus(.failure(L10n.tf("track_edit.download_failed", http.statusCode)))
                    return
                }
                data = downloaded
            }
            guard !data.isEmpty, NSImage(data: data) != nil else {
                library.setStatus(.failure(L10n.t("track_edit.invalid_image_url")))
                return
            }
            library.trackEditDraft?.coverImageData = data
            library.trackEditDraft?.coverFileName = url.lastPathComponent.isEmpty
                ? L10n.t("track_edit.from_url")
                : url.lastPathComponent
            library.trackEditDraft?.removeManualCover = false
            library.trackEditDraft?.coverDidChange = true
            focusedField = .cover
        } catch {
            library.setStatus(.failure(L10n.t("track_edit.load_image_failed")))
        }
    }

    private func pickCoverImage() {
        // NSOpenPanel in un foglio a volte fallisce nello stesso ciclo runloop.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .gif]
            panel.prompt = L10n.t("track_edit.panel_prompt")
            panel.message = L10n.t("track_edit.panel_message")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await applyCover(from: url) }
        }
    }

    private var headerTitle: String {
        guard let draft else { return L10n.t("track_edit.title") }
        if draft.isMulti {
            return L10n.tf("track_edit.title_multi", draft.trackIDs.count)
        }
        return L10n.t("track_edit.title")
    }

    private func prompt(mixed: Bool, current: String) -> Text? {
        guard isMulti, mixed, current.isEmpty else { return nil }
        return Text(L10n.t("track_edit.mixed_values"))
    }

    private func draftBinding(_ keyPath: WritableKeyPath<TrackEditDraft, String>) -> Binding<String> {
        Binding(
            get: { library.trackEditDraft?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard library.trackEditDraft != nil else { return }
                library.trackEditDraft![keyPath: keyPath] = newValue
            }
        )
    }
}

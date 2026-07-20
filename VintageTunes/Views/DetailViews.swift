import SwiftUI
import AppKit

struct DetailContainer: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        Group {
            switch library.selectedSection {
            case .songs:
                TrackTableView(title: "Canzoni")
            case .artists:
                ArtistsBrowserView()
            case .albums:
                AlbumsBrowserView()
            case .genres:
                GenresBrowserView()
            case .playlists:
                PlaylistDetailView()
            case .dropZone:
                DropImportView()
            }
        }
        .background(Color.clear)
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
                        cornerRadius: 4
                    )
                    .frame(width: 28, height: 28)
                }
                .width(36)

                TableColumn("Titolo") { track in
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

                TableColumn("Artista") { track in
                    Text(track.displayArtist)
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(min: 120, ideal: 160)

                TableColumn("Album") { track in
                    Text(track.displayAlbum)
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(min: 120, ideal: 160)

                TableColumn("Genere") { track in
                    Text(track.displayGenre)
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(min: 90, ideal: 120)

                TableColumn("Anno") { track in
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

                TableColumn("Ascolti") { track in
                    Text(track.displayPlayCount)
                        .monospacedDigit()
                        .foregroundStyle(VTTheme.textSecondary)
                }
                .width(56)

                TableColumn("Durata") { track in
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
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .background(VTTheme.tableBackground)
            .foregroundStyle(VTTheme.textPrimary)
            .onNativeTableDoubleClick { row in
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
                library.importDroppedURLs(urls)
                return true
            }
            .contextMenu(forSelectionType: Track.ID.self) { ids in
                if !ids.isEmpty {
                    Button("Riproduci") {
                        if let id = ids.first, let track = library.tracks.first(where: { $0.id == id }) {
                            library.playTrack(track)
                        }
                    }
                    Button("Modifica informazioni…") {
                        library.beginEditingTracks(ids: Array(ids))
                    }
                    Menu("Valutazione") {
                        Button("Nessuna stella") {
                            library.setStarRating(0, for: Array(ids))
                        }
                        ForEach(1...5, id: \.self) { stars in
                            Button(String(repeating: "★", count: stars)) {
                                library.setStarRating(stars, for: Array(ids))
                            }
                        }
                    }
                    Button("Ricarica copertina") {
                        library.refreshArtwork(for: Array(ids))
                    }
                    Button("Mostra in Finder") {
                        library.selection = Set(ids)
                        library.revealSelectedTracksInFinder()
                    }
                    Menu("Aggiungi a playlist") {
                        ForEach(library.playlists.filter { !$0.isMaster }) { playlist in
                            Button(playlist.name) {
                                library.selection = Set(ids)
                                library.addSelectionToPlaylist(playlist.id)
                            }
                        }
                    }
                    Button("Elimina dall'iPod", role: .destructive) {
                        library.selection = Set(ids)
                        library.deleteSelectedTracks()
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
        }
    }

    private var header: some View {
        HStack {
            if showsBackButton {
                Button {
                    library.browseBack()
                } label: {
                    Label("Indietro", systemImage: "chevron.left")
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
            Spacer()
            TextField("Cerca", text: $library.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .padding(16)
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
                subtitle: "\(library.albums(forArtist: artist).count) album",
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
                title: "Album",
                subtitle: "\(library.albums.count) album",
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
                subtitle: "\(library.artists(forGenre: genre).count) artisti",
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
    var title: String = "Artisti"
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
                        Label("Indietro", systemImage: "chevron.left")
                            .font(.custom("Avenir Next", size: 13).weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(VTTheme.amber)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(VTTheme.displayFont(size: 24))
                        .foregroundStyle(VTTheme.textPrimary)
                    Text(subtitle ?? "\(rows.count) artisti")
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(VTTheme.textSecondary)
                }
                Spacer()
                TextField("Cerca", text: $library.searchText)
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
                    Text("Generi")
                        .font(VTTheme.displayFont(size: 24))
                        .foregroundStyle(VTTheme.textPrimary)
                    Text("\(filteredGenres.count) generi")
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(VTTheme.textSecondary)
                }
                Spacer()
                TextField("Cerca", text: $library.searchText)
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
                    Text("Nessun genere nei brani")
                        .font(.custom("Avenir Next", size: 14).weight(.medium))
                        .foregroundStyle(VTTheme.textSecondary)
                    Text("I generi compaiono qui quando i tag delle canzoni li contengono.")
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
                Text("\(genre.artistCount) artisti · \(LibraryStats.trackCountLabel(genre.trackCount))")
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
                        Label("Indietro", systemImage: "chevron.left")
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
                TextField("Cerca", text: $library.searchText)
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
        artwork.request(artist: artist, album: album, fileURL: fileURL)
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryController

    private var playlist: Playlist? {
        library.playlists.first { $0.id == library.selectedPlaylistID }
    }

    var body: some View {
        if let playlist {
            TrackTableView(title: playlist.name)
                .toolbar {
                    ToolbarItemGroup {
                        Button("Rimuovi dalla playlist") {
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
                Text("Crea o seleziona una playlist")
                    .font(VTTheme.displayFont(size: 22))
                Text("Usa il + nella sidebar. Poi trascina le canzoni o aggiungile dal menu contestuale.")
                    .foregroundStyle(VTTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DropImportView: View {
    @EnvironmentObject private var library: LibraryController
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Aggiungi musica")
                .font(VTTheme.displayFont(size: 28))

            Text("Trascina file o cartelle qui (o sulla lista canzoni).\nVerranno cercati tutti i file audio, anche nelle sottocartelle.")
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
                    Text(isTargeted ? "Rilascia per sincronizzare" : "File o cartelle")
                        .font(.custom("Avenir Next", size: 16).weight(.semibold))
                    Text("mp3 · m4a · wav · aiff · flac (conversione) · …")
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
                Label("Scegli cartella…", systemImage: "folder")
                    .font(.custom("Avenir Next", size: 14).weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(VTTheme.amber)
            .disabled(library.connectedDevice == nil)

            if library.selectedSection == .playlists || library.selectedPlaylistID != nil {
                Text("Le nuove tracce possono essere aggiunte anche alla playlist selezionata.")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(VTTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryController
    @EnvironmentObject private var settings: AppSettings
    @State private var deviceNameDraft = ""

    var body: some View {
        Form {
            Section("Aspetto") {
                Picker("Tema", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Automatica segue le impostazioni di sistema di macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sincronizzazione") {
                Picker("Modalità", selection: $settings.syncMode) {
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
                            "Seleziona una cartella…",
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
                        .help("Cartella osservata per le nuove canzoni")

                        Button("Sfoglia…") {
                            // Aspetta il ciclo UI: un NSOpenPanel dentro Settings altrimenti fallisce spesso.
                            DispatchQueue.main.async {
                                if settings.chooseSyncFolder() {
                                    library.refreshAutoSyncWatching()
                                    library.checkAutoSync()
                                }
                            }
                        }
                        .help("Scegli la cartella di sincronizzazione")
                    }

                    if settings.hasSyncFolder {
                        HStack {
                            Spacer()
                            Button("Rimuovi cartella", role: .destructive) {
                                settings.clearSyncFolder()
                                library.refreshAutoSyncWatching()
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Text("Scegli una cartella: con l’iPod collegato verranno proposte le canzoni mancanti.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Text("Le nuove canzoni nella cartella vengono rilevate anche mentre l’app è aperta.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("In modalità manuale importa con trascina-e-rilascia o da File → Importa cartella.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dispositivo") {
                if let device = library.connectedDevice {
                    HStack(spacing: 8) {
                        TextField("Nome iPod", text: $deviceNameDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyDeviceName() }
                        Button("Rinomina") {
                            applyDeviceName()
                        }
                        .disabled(
                            deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == device.name
                        )
                    }
                    Text("Come in iTunes: cambia il nome del volume (visibile anche in Finder).")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    LabeledContent("Modello", value: device.modelHint)
                    LabeledContent(
                        "Firmware",
                        value: device.isSimulated
                            ? "Simulato (demo)"
                            : (device.firmwareMode == .rockbox ? "Rockbox" : "Stock Apple")
                    )
                    LabeledContent("Database", value: device.hasDatabase ? "iTunesDB presente" : "Assente")
                    if device.isSimulated {
                        Button("Azzera demo") { library.startDemo(reset: true) }
                        Button("Mostra cartella demo") { library.revealDemoFolder() }
                    }
                    Button("Mostra file convertiti (M4A)") { library.revealConvertedFolder() }
                    Button("Mostra musica sull'iPod") { library.revealMusicFolder() }
                } else {
                    Text("Nessun iPod collegato")
                    Button("Avvia modalità demo") { library.startDemo() }
                }
            }
            Section("Formati audio") {
                Text("Stock iPod: MP3, M4A/AAC, WAV, AIFF, ALAC")
                    .foregroundStyle(.secondary)
                Text("Non supportati: FLAC, OGG, WMA (il 5.5 stock non li riproduce)")
                    .foregroundStyle(.secondary)
            }
            Section("Note") {
                Text("Su firmware stock, VintageTunes scrive iTunesDB. Prima di modifiche importanti viene creato un backup iTunesDB.vintagebackup. Su Rockbox le playlist sono file .m3u.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .onAppear { syncDeviceNameDraft() }
        .onChange(of: library.connectedDevice?.id) { _, _ in syncDeviceNameDraft() }
        .onChange(of: library.connectedDevice?.name) { _, _ in syncDeviceNameDraft() }
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

    private enum Field: Hashable {
        case title, artist, album, genre, trackNumber, year
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
                        TextField("Titolo", text: draftBinding(\.title))
                            .focused($focusedField, equals: .title)
                    }

                    TextField(
                        "Artista",
                        text: draftBinding(\.artist),
                        prompt: prompt(mixed: draft.mixedArtist, current: draft.artist)
                    )
                    .focused($focusedField, equals: .artist)

                    TextField(
                        "Album",
                        text: draftBinding(\.album),
                        prompt: prompt(mixed: draft.mixedAlbum, current: draft.album)
                    )
                    .focused($focusedField, equals: .album)

                    TextField(
                        "Genere",
                        text: draftBinding(\.genre),
                        prompt: prompt(mixed: draft.mixedGenre, current: draft.genre)
                    )
                    .focused($focusedField, equals: .genre)

                    TextField(
                        "Numero traccia",
                        text: draftBinding(\.trackNumber),
                        prompt: prompt(mixed: draft.mixedTrackNumber, current: draft.trackNumber)
                    )
                    .focused($focusedField, equals: .trackNumber)

                    TextField(
                        "Anno",
                        text: draftBinding(\.year),
                        prompt: prompt(mixed: draft.mixedYear, current: draft.year)
                    )
                    .focused($focusedField, equals: .year)

                    LabeledContent("Valutazione") {
                        HStack(spacing: 10) {
                            if draft.mixedRating {
                                Text("Valori diversi")
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
                                Button("Nessuna") {
                                    library.trackEditDraft?.starRating = 0
                                    library.trackEditDraft?.mixedRating = false
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .padding(.horizontal, 8)
            }

            HStack {
                Spacer()
                Button("Annulla") {
                    library.cancelTrackEdit()
                }
                .keyboardShortcut(.cancelAction)

                Button("Salva") {
                    library.saveTrackEdit()
                }
                .buttonStyle(.borderedProminent)
                .tint(VTTheme.amber)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 440, height: isMulti ? 400 : 440)
        .onAppear {
            focusedField = isMulti ? .artist : .title
        }
    }

    private var headerTitle: String {
        guard let draft else { return "Modifica informazioni" }
        if draft.isMulti {
            return "Modifica \(draft.trackIDs.count) brani"
        }
        return "Modifica informazioni"
    }

    private func prompt(mixed: Bool, current: String) -> Text? {
        guard isMulti, mixed, current.isEmpty else { return nil }
        return Text("Valori diversi")
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

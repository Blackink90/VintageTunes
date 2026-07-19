import SwiftUI

struct DetailContainer: View {
    @EnvironmentObject private var library: LibraryController

    var body: some View {
        Group {
            switch library.selectedSection {
            case .songs:
                TrackTableView(title: "Canzoni")
            case .artists:
                GroupedListView(
                    title: "Artisti",
                    rows: library.artists.map { .init(id: $0.name, title: $0.name, subtitle: "\($0.count) brani") }
                )
            case .albums:
                GroupedListView(
                    title: "Album",
                    rows: library.albums.map { .init(id: "\($0.name)-\($0.artist)", title: $0.name, subtitle: $0.artist) }
                )
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            Table(of: Track.self, selection: $library.selection) {
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

                TableColumn("Tempo") { track in
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
            .background(Color(red: 0.11, green: 0.12, blue: 0.14))
            .foregroundStyle(VTTheme.textPrimary)
            .onNativeTableDoubleClick { row in
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom("New York", size: 24).weight(.semibold))
                    .foregroundStyle(VTTheme.textPrimary)
                Text("\(library.filteredTracks.count) brani")
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

struct GroupedRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
}

struct GroupedListView: View {
    let title: String
    let rows: [GroupedRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.custom("New York", size: 24).weight(.semibold))
                .padding(16)
            List(rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.custom("Avenir Next", size: 14).weight(.medium))
                        Text(row.subtitle)
                            .font(.custom("Avenir Next", size: 12))
                            .foregroundStyle(VTTheme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
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
                    .font(.custom("New York", size: 22).weight(.semibold))
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
                .font(.custom("New York", size: 28).weight(.semibold))

            Text("Trascina mp3 / m4a / aac / wav / aiff su questa area\noppure sulla lista canzoni. FLAC non è supportato sul firmware stock.")
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
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(VTTheme.amber)
                        .symbolEffect(.pulse, options: .repeating, isActive: isTargeted)
                    Text(isTargeted ? "Rilascia per sincronizzare" : "Drop zone")
                        .font(.custom("Avenir Next", size: 16).weight(.semibold))
                    Text("Sincronizzazione diretta · senza Music.app")
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

    var body: some View {
        Form {
            Section("Dispositivo") {
                if let device = library.connectedDevice {
                    LabeledContent("Nome", value: device.name)
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
        .frame(width: 480, height: 360)
    }
}

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryController
    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandMark()
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if let device = library.connectedDevice {
                DeviceCard(device: device)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            List {
                Section {
                    ForEach(LibrarySection.allCases.filter { $0 != .playlists }) { section in
                        sidebarRow(
                            title: section.rawValue,
                            systemImage: section.systemImage,
                            selected: library.selectedSection == section
                        ) {
                            library.selectedSection = section
                        }
                    }
                } header: {
                    Text("LIBRERIA")
                        .font(.custom("Avenir Next", size: 11).weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.55))
                }

                Section {
                    ForEach(library.playlists.filter { !$0.isMaster }) { playlist in
                        sidebarRow(
                            title: playlist.name,
                            systemImage: "music.note.list",
                            badge: "\(playlist.songCount)",
                            selected: library.selectedSection == .playlists && library.selectedPlaylistID == playlist.id
                        ) {
                            library.selectedSection = .playlists
                            library.selectedPlaylistID = playlist.id
                        }
                        .contextMenu {
                            Button("Elimina playlist", role: .destructive) {
                                library.deletePlaylist(playlist.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("PLAYLIST")
                            .font(.custom("Avenir Next", size: 11).weight(.bold))
                            .foregroundStyle(Color.white.opacity(0.55))
                        Spacer()
                        Button {
                            showingNewPlaylist = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(VTTheme.amber)
                        }
                        .buttonStyle(.borderless)
                        .help("Nuova playlist")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .listRowSeparator(.hidden)

            HStack(spacing: 14) {
                Button {
                    library.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .help("Ricarica")

                Button {
                    library.eject()
                } label: {
                    Image(systemName: "eject")
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .help("Espelli")
                .disabled(library.connectedDevice == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .background(VTTheme.panel)
        .environment(\.colorScheme, .dark)
        .alert("Nuova playlist", isPresented: $showingNewPlaylist) {
            TextField("Nome", text: $newPlaylistName)
            Button("Crea") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                library.createPlaylist(named: name)
                newPlaylistName = ""
            }
            Button("Annulla", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("La playlist viene scritta direttamente sull'iPod.")
        }
    }

    private func sidebarRow(
        title: String,
        systemImage: String,
        badge: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? VTTheme.amber : Color.white.opacity(0.7))
                    .frame(width: 18)
                Text(title)
                    .font(.custom("Avenir Next", size: 13).weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? VTTheme.amberSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
    }
}

struct DeviceCard: View {
    let device: iPodDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "ipod")
                    .foregroundStyle(VTTheme.amber)
                Text(device.name)
                    .font(.custom("Avenir Next", size: 13).weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                Spacer()
                Text(device.firmwareMode == .rockbox ? "Rockbox" : (device.isSimulated ? "Demo" : "Stock"))
                    .font(.custom("Avenir Next", size: 10).weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(VTTheme.amberSoft, in: Capsule())
                    .foregroundStyle(VTTheme.amber)
            }

            Text(device.modelHint)
                .font(.custom("Avenir Next", size: 11))
                .foregroundStyle(Color.white.opacity(0.55))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(VTTheme.amber)
                        .frame(width: max(4, geo.size.width * device.usedFraction))
                }
            }
            .frame(height: 6)

            Text("\(ByteCountFormatter.string(fromByteCount: device.usedBytes, countStyle: .file)) di \(ByteCountFormatter.string(fromByteCount: device.capacityBytes, countStyle: .file))")
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(VTTheme.panelStroke)
                )
        )
    }
}

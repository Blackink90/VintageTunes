import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryController
    @Environment(\.openSettings) private var openSettings
    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                BrandMark()
                HStack(spacing: 8) {
                    sidebarActionButton(
                        systemImage: "arrow.clockwise",
                        help: "Ricarica",
                        disabled: false
                    ) {
                        library.refresh()
                    }
                    sidebarActionButton(
                        systemImage: "eject",
                        help: "Espelli",
                        disabled: library.connectedDevice == nil
                    ) {
                        library.eject()
                    }
                    sidebarActionButton(
                        systemImage: "gearshape",
                        help: "Impostazioni",
                        disabled: false
                    ) {
                        openSettings()
                    }
                    Spacer(minLength: 0)
                }
            }
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
                    ForEach(LibrarySection.allCases.filter { section in
                        if section == .playlists { return false }
                        if section == .photos {
                            return library.connectedDevice?.supportsPhotos == true
                        }
                        return true
                    }) { section in
                        sidebarRow(
                            title: section.rawValue,
                            systemImage: section.systemImage,
                            selected: library.selectedSection == section
                        ) {
                            library.selectSection(section)
                        }
                    }
                } header: {
                    Text("LIBRERIA")
                        .font(.custom("Avenir Next", size: 11).weight(.bold))
                        .foregroundStyle(VTTheme.textSecondary)
                }

                Section {
                    ForEach(library.playlists.filter { !$0.isMaster }) { playlist in
                        let count = playlist.resolvedSongCount(using: library.tracks)
                        sidebarRow(
                            title: playlist.name,
                            systemImage: "music.note.list",
                            badge: count > 0 ? "\(count)" : nil,
                            selected: library.selectedSection == .playlists && library.selectedPlaylistID == playlist.id
                        ) {
                            library.selectSection(.playlists)
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
                            .foregroundStyle(VTTheme.textSecondary)
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
        }
        .background(VTTheme.panel)
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

    private func sidebarActionButton(
        systemImage: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VTTheme.textPrimary.opacity(disabled ? 0.35 : 0.85))
                .frame(width: 28, height: 28)
                .background(VTTheme.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
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
                    .foregroundStyle(selected ? VTTheme.amber : VTTheme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.custom("Avenir Next", size: 13).weight(.medium))
                    .foregroundStyle(VTTheme.textPrimary)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))
                        .foregroundStyle(VTTheme.textSecondary.opacity(0.8))
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
                    .foregroundStyle(VTTheme.textPrimary)
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
                .foregroundStyle(VTTheme.textSecondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(VTTheme.controlFill)
                    Capsule()
                        .fill(VTTheme.amber)
                        .frame(width: max(4, geo.size.width * device.usedFraction))
                }
            }
            .frame(height: 6)

            Text("\(ByteCountFormatter.string(fromByteCount: device.usedBytes, countStyle: .file)) di \(ByteCountFormatter.string(fromByteCount: device.capacityBytes, countStyle: .file))")
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(VTTheme.textSecondary.opacity(0.85))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VTTheme.elevatedFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(VTTheme.panelStroke)
                )
        )
    }
}

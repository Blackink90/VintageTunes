import SwiftUI

@main
struct VintageTunesApp: App {
    @StateObject private var library = LibraryController()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(settings)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("iPod") {
                Button("Ricarica iPod") {
                    library.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Espelli iPod") {
                    library.eject()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(library.connectedDevice == nil)

                Divider()

                Button(library.playback.isPlaying ? "Pausa" : "Riproduci") {
                    library.playSelectedOrToggle()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Stop") {
                    library.playback.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(library.playback.nowPlaying == nil)

                Button("Rimuovi duplicati") {
                    library.removeLibraryDuplicates()
                }
                .disabled(library.connectedDevice == nil)

                Divider()

                Button("Importa cartella…") {
                    library.chooseFolderToImport()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(library.connectedDevice == nil)

                Divider()

                Button("Avvia modalità demo") {
                    library.startDemo()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Azzera demo") {
                    library.startDemo(reset: true)
                }
                .disabled(!(library.connectedDevice?.isSimulated ?? true))

                Button("Mostra cartella demo") {
                    library.revealDemoFolder()
                }

                Button("Mostra file convertiti") {
                    library.revealConvertedFolder()
                }

                Button("Mostra musica sull'iPod") {
                    library.revealMusicFolder()
                }
                .disabled(library.connectedDevice == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(settings)
                .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
        }
    }
}

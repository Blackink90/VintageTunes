import SwiftUI
import AppKit

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
                .id(settings.appLanguage)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(L10n.t("menu.settings")) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandMenu(L10n.t("menu.ipod")) {
                Button(L10n.t("menu.reload_ipod")) {
                    library.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button(L10n.t("menu.eject_ipod")) {
                    library.eject()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(library.connectedDevice == nil)

                Divider()

                Button(library.playback.isPlaying ? L10n.t("menu.pause") : L10n.t("menu.play")) {
                    library.playSelectedOrToggle()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button(L10n.t("menu.stop")) {
                    library.playback.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(library.playback.nowPlaying == nil)

                Button(L10n.t("menu.remove_duplicates")) {
                    library.removeLibraryDuplicates()
                }
                .disabled(library.connectedDevice == nil)

                Divider()

                Button(L10n.t("menu.import_folder")) {
                    library.chooseFolderToImport()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(library.connectedDevice == nil)

                Divider()

                Button(L10n.t("menu.start_demo")) {
                    library.startDemo()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(L10n.t("menu.reset_demo")) {
                    library.startDemo(reset: true)
                }
                .disabled(!(library.connectedDevice?.isSimulated ?? true))

                Button(L10n.t("menu.show_demo_folder")) {
                    library.revealDemoFolder()
                }

                Button(L10n.t("menu.show_converted")) {
                    library.revealConvertedFolder()
                }

                Button(L10n.t("menu.show_ipod_music")) {
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
                .id(settings.appLanguage)
        }
    }
}

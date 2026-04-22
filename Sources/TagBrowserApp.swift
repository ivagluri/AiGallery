import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard NSApp.modalWindow == nil, NSApp.keyWindow == nil else { return }
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
}

@main
struct AiGalleryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var library: LibraryStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: LibraryStore(appSettings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 1500, height: 920)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Image Root…") {
                    library.chooseRootFolder()
                }
                .keyboardShortcut("o")
            }

            CommandMenu("Image") {
                Button("Move to Trash") {
                    guard let id = library.selectedImageID,
                          let image = library.allImages.first(where: { $0.id == id })
                    else { return }
                    library.trashImage(image)
                }
                .keyboardShortcut(.delete)
                .disabled(library.selectedImageID == nil)
            }

            CommandMenu("Mode") {
                Toggle(
                    "TagExplorer Legacy Mode",
                    isOn: Binding(
                        get: { settings.appMode == .tagExplorerLegacy },
                        set: { isEnabled in
                            library.setAppMode(isEnabled ? .tagExplorerLegacy : .general)
                        }
                    )
                )
            }
        }
    }
}

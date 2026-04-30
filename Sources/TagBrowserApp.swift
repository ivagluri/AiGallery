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
        guard !SlideshowWindowController.shared.isPresented else { return }
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
}

@main
struct AiGalleryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()
    @AppStorage("imageSortOrder") private var imageSortOrderRawValue = ImageSortOrder.alphabeticalAscending.rawValue
    @AppStorage("imageSortToggleMode") private var imageSortToggleModeRawValue = ImageSortToggleMode.cycleAll.rawValue
    @AppStorage("showHiddenFolders") private var showHiddenFolders: Bool = false

    private var imageSortOrder: ImageSortOrder {
        get { ImageSortOrder(rawValue: imageSortOrderRawValue) ?? .alphabeticalAscending }
        nonmutating set { imageSortOrderRawValue = newValue.rawValue }
    }

    private var imageSortToggleMode: ImageSortToggleMode {
        get { ImageSortToggleMode(rawValue: imageSortToggleModeRawValue) ?? .cycleAll }
        nonmutating set { imageSortToggleModeRawValue = newValue.rawValue }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 640)
                .onAppear {
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .defaultSize(width: 1500, height: 920)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Root Folder…") {
                    library.addRootFolder()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Start Slideshow") {
                    SlideshowCoordinator.shared.requestLaunch()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("View") {
                Toggle(isOn: $showHiddenFolders) {
                    Text("Show Hidden Folders")
                }
            }

            CommandMenu("Sort") {
                Button("Cycle All Sort Modes") {
                    imageSortToggleMode = .cycleAll
                    imageSortOrder = imageSortOrder.next
                }

                Divider()

                ForEach(ImageSortOrder.allCases) { order in
                    Button {
                        imageSortOrder = order
                        imageSortToggleMode = ImageSortToggleMode.explicitMode(for: order)
                    } label: {
                        Label(order.menuTitle, systemImage: order == imageSortOrder ? "checkmark" : order.systemImage)
                    }
                }
            }
        }

        Settings {
            PreferencesView(library: library)
        }
    }
}

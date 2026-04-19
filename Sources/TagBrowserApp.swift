import SwiftUI

@main
struct AiGalleryApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 1100, minHeight: 700)
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
        }
    }
}

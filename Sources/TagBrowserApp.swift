import SwiftUI

@main
struct TagBrowserApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 1100, minHeight: 700)
        }
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

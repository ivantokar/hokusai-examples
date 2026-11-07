import AppKit
import PlaygroundModel
import SwiftUI

@main
struct HokusaiPlaygroundApp: App {
    @State private var playground = Playground()

    init() {
        // Lets `swift run` show a normal window and Dock icon; an Xcode app target does this itself.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Hokusai Playground") {
            ContentView()
                .environment(playground)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { playground.undo() }.keyboardShortcut("z").disabled(!playground.canUndo)
                Button("Redo") { playground.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!playground.canRedo)
            }
        }
    }
}

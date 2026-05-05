import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SketchyBarStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SketchyBarStore()

    var body: some Scene {
        WindowGroup("SketchyBar Studio", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save All Changed Files") {
                    store.saveAllChangedFiles()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button("Reload Configs") {
                    store.reload()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Apply to SketchyBar") {
                    store.applySketchyBarReload()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

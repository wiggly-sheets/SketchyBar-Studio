import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app so the delegate can check for unsaved work.
    weak var store: SketchyBarStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Repair an install that a crash interrupted before the app touches
        // any config.
        SafeFileReplacer().recoverPendingInstalls()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Asks before quitting while drafts are still in memory.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasUnsavedChanges else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Save your edits to your SketchyBar config before quitting SketchyBar Studio?"
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.saveAllChangedFiles()
            NSApp.reply(toApplicationShouldTerminate: !store.hasUnsavedChanges)
        case .alertSecondButtonReturn:
            NSApp.reply(toApplicationShouldTerminate: true)
        default:
            NSApp.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }

    /// Keeps the app alive when the last window closes while drafts exist.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(store?.hasUnsavedChanges ?? false)
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
                .onAppear { appDelegate.store = store }
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save All Changed Files") {
                    store.saveAllChangedFiles()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button("Reload Configs") {
                    store.reloadAsync()
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

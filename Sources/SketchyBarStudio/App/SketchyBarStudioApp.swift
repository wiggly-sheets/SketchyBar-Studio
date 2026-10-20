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
            NSApp.reply(toApplicationShouldTerminate: saveAllAndMayTerminate())
        case .alertSecondButtonReturn:
            NSApp.reply(toApplicationShouldTerminate: true)
        default:
            NSApp.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }

    /// Saves every change and reports whether the app may quit. A draft
    /// that could not be saved, such as the draft of a file that is missing
    /// from disk, keeps the app open and is named in the status message.
    @MainActor
    func saveAllAndMayTerminate() -> Bool {
        guard let store else { return true }
        store.saveAllChangedFiles()
        return !store.hasUnsavedChanges
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
    @StateObject private var quickOpen = QuickOpenPresenter()

    var body: some Scene {
        WindowGroup("SketchyBar Studio", id: "main") {
            ContentView(store: store, quickOpen: quickOpen)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { appDelegate.store = store }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoTitle.map { "Undo \($0)" } ?? "Undo") {
                    store.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)

                Button(store.redoTitle.map { "Redo \($0)" } ?? "Redo") {
                    store.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
            }

            CommandGroup(after: .newItem) {
                Button("Quick Open…") {
                    quickOpen.isPresented = true
                }
                .keyboardShortcut("p", modifiers: .command)
            }

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
                .preferredColorScheme(.dark)
        }
    }
}

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SketchyBarStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
        } detail: {
            DetailView(store: store)
        }
        .tint(store.appTheme.accent)
        .preferredColorScheme(.dark)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search files and values")
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = sidebarIsVisible ? .detailOnly : .all
                } label: {
                    Label(sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .help(sidebarIsVisible ? "Hide the left sidebar" : "Show the left sidebar")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $store.showModifiedOnly) {
                    Label("Changed Only", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show only changed values")

                Button {
                    store.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }

                Button {
                    store.saveSelectedFile()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(store.selectedFile == nil || !store.selectedHasUnsavedChanges)

                Button {
                    store.saveAllChangedFiles()
                } label: {
                    Label("Save All", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(store.unsavedFileCount == 0)

                Button {
                    store.applySketchyBarReload()
                } label: {
                    Label("Apply", systemImage: "bolt")
                }

                Button {
                    store.saveAllAndApply()
                } label: {
                    Label("Save & Apply", systemImage: "checkmark.circle")
                }
                .disabled(store.unsavedFileCount == 0)
            }
        }
    }

    private var sidebarIsVisible: Bool {
        columnVisibility != .detailOnly
    }
}

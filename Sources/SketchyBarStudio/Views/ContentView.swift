import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SketchyBarStore
    @ObservedObject var quickOpen: QuickOpenPresenter
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsReachability = false
    @State private var showsDiagnostics = false
    @State private var showsDuplicates = false
    @State private var showsAddItem = false

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
                    showsAddItem = true
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
                .help("Create a new bar item")

                Button {
                    store.reloadAsync()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }

                Button {
                    store.saveSelectedFile()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(store.selectedFile == nil || !store.selectedHasUnsavedChanges || store.selectedHasLoadError)

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

                Button {
                    showsReachability = true
                } label: {
                    Label("Reachability", systemImage: "checklist")
                }
                .help("Show which config files are loaded and which ones are dead")

                Button {
                    showsDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .help("Check the config for problems SketchyBar ignores")

                Button {
                    showsDuplicates = true
                } label: {
                    Label("Duplicates", systemImage: "square.on.square")
                }
                .help("Find item files that are nearly the same")
            }
        }
        .sheet(isPresented: $showsReachability) {
            ReachabilityView(rootURL: store.configRoot)
        }
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsView(rootURL: store.configRoot)
        }
        .sheet(isPresented: $showsDuplicates) {
            DuplicatesView(rootURL: store.configRoot)
        }
        .sheet(isPresented: $showsAddItem) {
            AddItemWizard(store: store)
        }
        .sheet(isPresented: $quickOpen.isPresented) {
            QuickOpenView(store: store)
        }
    }

    private var sidebarIsVisible: Bool {
        columnVisibility != .detailOnly
    }
}

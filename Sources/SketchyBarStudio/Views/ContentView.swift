import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SketchyBarStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            DetailView(store: store)
        }
        .tint(store.appTheme.accent)
        .preferredColorScheme(.dark)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search files and values")
        .toolbar {
            ToolbarItemGroup {
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
                .disabled(store.selectedFile == nil)

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
}

import Foundation

struct ConfigLibraryService {
    private let fileManager = FileManager.default

    private var libraryURL: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("SketchyBarStudio")
            .appendingPathComponent("config-library.json")
    }

    func load(defaultConfigRoot: URL) -> [ConfigWorkspace] {
        guard let data = try? Data(contentsOf: libraryURL),
              let configs = try? JSONDecoder().decode([ConfigWorkspace].self, from: data),
              !configs.isEmpty else {
            return [ConfigWorkspace(id: "default", name: "Default", path: defaultConfigRoot.path, createdAt: .now)]
        }
        return configs
    }

    func save(_ configs: [ConfigWorkspace]) throws {
        try fileManager.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(configs)
        try data.write(to: libraryURL, options: .atomic)
    }
}

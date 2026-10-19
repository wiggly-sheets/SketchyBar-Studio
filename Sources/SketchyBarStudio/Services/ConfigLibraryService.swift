import Foundation

struct ConfigLibraryService {
    private let fileManager: FileManager
    private let libraryURL: URL

    init(fileManager: FileManager = .default, libraryURL: URL? = nil) {
        self.fileManager = fileManager
        self.libraryURL = libraryURL ?? Self.defaultLibraryURL(fileManager: fileManager)
    }

    private static func defaultLibraryURL(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("SketchyBarStudio")
            .appendingPathComponent("config-library.json")
    }

    /// Loads the saved config list. A missing file yields the default config.
    /// A corrupt file is reported and left untouched.
    func load(defaultConfigRoot: URL) throws -> [ConfigWorkspace] {
        guard let configs = try readConfigs(), !configs.isEmpty else {
            return [ConfigWorkspace(id: "default", name: "Default", path: defaultConfigRoot.path, createdAt: .now)]
        }
        return configs
    }

    func save(_ configs: [ConfigWorkspace]) throws {
        // A library file the app cannot read is never overwritten.
        if fileManager.fileExists(atPath: libraryURL.path) {
            _ = try readConfigs()
        }
        try fileManager.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(configs)
        try data.write(to: libraryURL, options: .atomic)
    }

    /// Reads the stored configs, or nil when no library file exists yet.
    private func readConfigs() throws -> [ConfigWorkspace]? {
        guard fileManager.fileExists(atPath: libraryURL.path) else { return nil }
        let data = try Data(contentsOf: libraryURL)
        do {
            return try JSONDecoder().decode([ConfigWorkspace].self, from: data)
        } catch {
            throw ConfigLibraryError.corrupt(libraryURL.path)
        }
    }
}

enum ConfigLibraryError: LocalizedError {
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .corrupt(let path):
            return "The config library file is unreadable and was left unchanged: \(path)"
        }
    }
}

import Foundation

struct ConfigWorkspace: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var path: String
    var createdAt: Date

    var url: URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    static func make(name: String, url: URL) -> ConfigWorkspace {
        ConfigWorkspace(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.lastPathComponent : name,
            path: url.path,
            createdAt: .now
        )
    }
}

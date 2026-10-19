import Foundation

/// A loader line that points at another file in the config.
struct ConfigGraphEdge: Hashable {
    let from: URL
    let to: URL
    let line: Int
    let text: String
}

/// A loader line that points at a file that is not in the config.
struct ConfigGraphMissingTarget: Hashable {
    let from: URL
    let line: Int
    let target: String
}

/// What the load graph of a config looks like: which files the entrypoints
/// reach, which files nothing loads, and which loader lines point at files
/// that are gone.
struct ConfigGraphReport {
    var entrypoints: [URL] = []
    var edges: [ConfigGraphEdge] = []
    var reachableFiles: [URL] = []
    var orphanFiles: [URL] = []
    var missingTargets: [ConfigGraphMissingTarget] = []
    var cycles: [[URL]] = []
    /// The files that require a name they compute at runtime. They can load
    /// more files than the graph can see.
    var dynamicRequireFiles: [URL] = []
}

extension ConfigGraphMissingTarget: Identifiable {
    var id: String { "\(from.path):\(line):\(target)" }
}

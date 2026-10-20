import Foundation

/// Finds the item files of a config that are nearly the same.
///
/// The finder only reads the config. It never writes, moves or deletes a
/// file.
///
/// A file is described by the keys of its item tables, such as
/// `icon.font.size`, and by the literal values of those keys. A value that
/// is built by an expression, such as `colors.red`, is not a literal, so it
/// is left out of the comparison.
struct DuplicateFinder: Sendable {
    /// The item tables of one file.
    struct ItemSignature: Sendable, Hashable {
        /// The file the signature was read from.
        let fileURL: URL
        /// The path of the file inside the config.
        let relativePath: String
        /// The aliases of the items of the file, joined with ", ". It is
        /// nil when the file declares no alias.
        let alias: String?
        /// The key paths of the item tables and their literal values.
        ///
        /// A file can hold more than one item. Their keys are merged into
        /// one map, so a key that both items set keeps the value of the
        /// item that comes last.
        let properties: [String: String]
    }

    /// Two files that look like copies of each other.
    struct Pair: Identifiable, Sendable {
        /// The two files, so the same pair is only listed once.
        let id: String
        /// The file with the shorter path.
        let first: ItemSignature
        /// The other file.
        let second: ItemSignature
        /// How much the two files look alike, from 0 to 1.
        let score: Double
        /// The keys both files set.
        let sharedKeys: [String]
        /// The keys only the first file sets.
        let onlyInFirst: [String]
        /// The keys only the second file sets.
        let onlyInSecond: [String]
        /// The keys both files set to a different value.
        let differingValues: [String]
    }

    /// The score a pair needs to be reported.
    static let defaultThreshold = 0.8

    /// How many files are read at most, so a huge config cannot slow the
    /// app down.
    private static let maximumFiles = 1000

    /// How many other files one file is compared with at most.
    private static let maximumCandidatesPerFile = 256

    /// How many pairs are compared at most.
    private static let maximumComparisons = 100_000

    // MARK: - Files

    /// The item signatures of the config at the given root.
    ///
    /// Only the files that declare an item are read. The backups of the
    /// app, hidden files and hidden folders are left out.
    func signatures(in rootURL: URL) -> [ItemSignature] {
        let root = rootURL.standardizedFileURL
        var result: [ItemSignature] = []

        for file in SketchyBarConfigLocator().configFiles(in: root) {
            guard file.pathExtension.lowercased() == "lua" else { continue }
            guard result.count < Self.maximumFiles else { break }

            let relativePath = Self.relativePath(of: file, from: root)
            guard !Self.isExcluded(relativePath) else { continue }

            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard let signature = Self.signature(
                of: file,
                relativePath: relativePath,
                contents: contents
            ) else { continue }

            result.append(signature)
        }

        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// The signature of one file, or nil when the file declares no item.
    private static func signature(
        of file: URL,
        relativePath: String,
        contents: String
    ) -> ItemSignature? {
        let items = SbarLuaItemParser.items(in: contents)
        guard !items.isEmpty else { return nil }

        var properties: [String: String] = [:]
        for item in items {
            for value in item.values {
                properties[value.keyPath] = value.rawValue
            }
        }

        let aliases = items.map(\.alias).filter { !$0.isEmpty }
        let alias = aliases.isEmpty ? nil : aliases.joined(separator: ", ")

        return ItemSignature(
            fileURL: file,
            relativePath: relativePath,
            alias: alias,
            properties: properties
        )
    }

    // MARK: - Pairs

    /// The pairs of files that look alike, from the most alike to the
    /// least.
    ///
    /// A pair is only reported when its score is at least the threshold.
    func findDuplicates(in rootURL: URL, threshold: Double) -> [Pair] {
        pairs(in: signatures(in: rootURL), threshold: threshold)
    }

    /// The pairs of the given files that look alike.
    ///
    /// The score of a pair is the mean of two parts: the Jaccard
    /// similarity of the key sets and the share of the shared keys whose
    /// values are equal.
    ///
    ///     score = 0.5 * (shared keys / all keys)
    ///           + 0.5 * (shared keys with the same value / shared keys)
    ///
    /// The first part says how much of the item the two files describe is
    /// the same. The second part says how much of that part has not
    /// drifted apart yet.
    func pairs(in signatures: [ItemSignature], threshold: Double) -> [Pair] {
        let files = signatures.sorted { $0.relativePath < $1.relativePath }
        guard files.count > 1 else { return [] }

        // The files that use a key. Only the files that share a key can
        // reach the threshold, so the other pairs are never compared.
        var postings: [String: [Int]] = [:]
        for (index, file) in files.enumerated() {
            for key in file.properties.keys {
                postings[key, default: []].append(index)
            }
        }

        var found: [Pair] = []
        var comparisons = 0

        for (index, file) in files.enumerated() {
            // The keys that few files use come first, because they point at
            // the files that look alike.
            let keys = file.properties.keys.sorted {
                (postings[$0]?.count ?? 0, $0) < (postings[$1]?.count ?? 0, $1)
            }

            var candidates: Set<Int> = []
            for key in keys {
                for other in postings[key] ?? [] where other > index {
                    candidates.insert(other)
                    if candidates.count >= Self.maximumCandidatesPerFile { break }
                }
                if candidates.count >= Self.maximumCandidatesPerFile { break }
            }

            for other in candidates.sorted() {
                guard comparisons < Self.maximumComparisons else { break }
                comparisons += 1

                guard Self.canReach(first: file, second: files[other], threshold: threshold) else {
                    continue
                }
                guard let pair = Self.pair(file, files[other], threshold: threshold) else { continue }
                found.append(pair)
            }

            if comparisons >= Self.maximumComparisons { break }
        }

        return found.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.first.relativePath != rhs.first.relativePath {
                return lhs.first.relativePath < rhs.first.relativePath
            }
            return lhs.second.relativePath < rhs.second.relativePath
        }
    }

    /// True when the two files can reach the threshold at all.
    ///
    /// The score is the mean of two parts that are at most 1, so the keys
    /// of the two files have to overlap enough for the first part to carry
    /// the score.
    private static func canReach(
        first: ItemSignature,
        second: ItemSignature,
        threshold: Double
    ) -> Bool {
        let smaller = min(first.properties.count, second.properties.count)
        let larger = max(first.properties.count, second.properties.count)
        guard larger > 0 else { return false }

        let neededJaccard = max(0, 2 * threshold - 1)
        return Double(smaller) >= neededJaccard * Double(larger) - 0.000_001
    }

    /// The pair of two files, or nil when the score is below the
    /// threshold.
    private static func pair(
        _ first: ItemSignature,
        _ second: ItemSignature,
        threshold: Double
    ) -> Pair? {
        let firstKeys = Set(first.properties.keys)
        let secondKeys = Set(second.properties.keys)
        let shared = firstKeys.intersection(secondKeys)
        let union = firstKeys.union(secondKeys)

        let jaccard = union.isEmpty ? 0 : Double(shared.count) / Double(union.count)

        var equal = 0
        var differing: [String] = []
        for key in shared {
            if normalized(first.properties[key] ?? "") == normalized(second.properties[key] ?? "") {
                equal += 1
            } else {
                differing.append(key)
            }
        }
        let valueScore = shared.isEmpty ? 0 : Double(equal) / Double(shared.count)
        let score = 0.5 * jaccard + 0.5 * valueScore

        guard score >= threshold else { return nil }

        return Pair(
            id: "\(first.relativePath)|\(second.relativePath)",
            first: first,
            second: second,
            score: score,
            sharedKeys: shared.sorted(),
            onlyInFirst: firstKeys.subtracting(secondKeys).sorted(),
            onlyInSecond: secondKeys.subtracting(firstKeys).sorted(),
            differingValues: differing.sorted()
        )
    }

    /// The value as it is compared. The quotes of a string do not make two
    /// values different.
    private static func normalized(_ value: String) -> String {
        SketchyBarValueRules.unquoted(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Paths

    /// The path of a file inside the config.
    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }

    /// True when the file sits in a folder the finder does not read, such
    /// as the backups of the app or a hidden folder.
    private static func isExcluded(_ relativePath: String) -> Bool {
        for component in relativePath.split(separator: "/") {
            if component == "backups" { return true }
            if component.hasPrefix(".") { return true }
        }
        return false
    }
}

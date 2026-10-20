import Foundation

/// Searches a whole SketchyBar config for files and options.
///
/// The search engine is pure: it only reads the files it is given, it never
/// touches the disk and it never changes the config.
enum QuickOpenSearch {
    /// What a result points at.
    enum ResultKind: Hashable {
        case file
        case value
    }

    /// One hit of the search.
    struct Result: Identifiable, Hashable {
        let id: String
        let kind: ResultKind
        let fileID: ConfigFile.ID
        let fileName: String
        let lineNumber: Int?
        let keyPath: String?
        let valueText: String
    }

    /// How a candidate matched, from the strongest to the weakest.
    private enum MatchRank: Int {
        /// The candidate is the query.
        case exact = 0
        /// The candidate starts with the query.
        case prefix = 1
        /// The candidate holds the query as one block.
        case substring = 2
        /// The candidate only holds the query as a subsequence.
        case fuzzy = 3
    }

    /// The file name endings that mark a query as the name of a file.
    private static let fileExtensions = ["lua", "sh", "bash", "zsh", "sketchybarrc"]

    /// Searches every file for the query.
    ///
    /// Files are matched with a fuzzy subsequence match on their name, and
    /// values with a case insensitive substring match on their key path and
    /// their text. The list is capped at `limit` and it is the same on every
    /// run, because the results are sorted with a total order.
    static func search(query: String, in files: [ConfigFile], limit: Int = 100) -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let needle = trimmed.lowercased()
        let fileFirst = looksLikeFileName(needle)

        var best = BestResults(limit: limit)
        for file in files {
            // The name of the file is built once, because building it walks
            // the path of the file.
            let displayName = file.displayName
            if let match = fileMatch(query: needle, file: file) {
                best.add(Scored(
                    group: fileFirst ? 0 : 1,
                    category: match.rank,
                    kindRank: 0,
                    score: match.score,
                    fileID: file.id,
                    displayName: displayName,
                    lineNumber: nil,
                    keyPath: nil,
                    valueText: "",
                    valueID: nil
                ))
            }
            for value in file.values {
                guard let match = valueMatch(query: needle, value: value) else { continue }
                best.add(Scored(
                    group: 1,
                    category: match.rank,
                    kindRank: 1,
                    score: match.score,
                    fileID: file.id,
                    displayName: displayName,
                    lineNumber: value.lineNumber,
                    keyPath: value.keyPath,
                    valueText: value.draftValue,
                    valueID: value.id
                ))
            }
        }

        // The result is built after the order is known, so a big config does
        // not pay for thousands of results nobody sees.
        return best.results
    }

    /// Scores a fuzzy match of a query against a candidate name.
    ///
    /// The query must be a subsequence of the candidate, compared without
    /// case. Anything else returns nil. The score adds:
    /// - 1000 when the candidate holds the query as one contiguous block,
    /// - 500 when the candidate starts with the query,
    /// - 200 when the first matched character sits at the start of the name,
    /// - 50 when the first matched character sits at a word boundary, which
    ///   is the start of the name or a place after "/", ".", "_" or "-",
    /// - 10 for every character between the first and the last match, so a
    ///   scattered match scores lower than a contiguous one,
    /// - 2 for every character before the first match, so an early match
    ///   scores higher than a late one.
    ///
    /// The function is pure: the same query and the same candidate always
    /// give the same score.
    static func fuzzyScore(query: String, candidate: String) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let haystack = candidate.lowercased()
        guard !needle.isEmpty, !haystack.isEmpty, needle.count <= haystack.count else { return nil }

        var matched: [Int] = []
        var needleIndex = needle.startIndex
        var haystackIndex = haystack.startIndex
        while needleIndex < needle.endIndex, haystackIndex < haystack.endIndex {
            if haystack[haystackIndex] == needle[needleIndex] {
                matched.append(haystack.distance(from: haystack.startIndex, to: haystackIndex))
                needleIndex = needle.index(after: needleIndex)
            }
            haystackIndex = haystack.index(after: haystackIndex)
        }
        guard needleIndex == needle.endIndex, let first = matched.first, let last = matched.last else { return nil }

        var score = 0
        if haystack.contains(needle) { score += 1000 }
        if haystack.hasPrefix(needle) { score += 500 }
        if first == 0 { score += 200 }
        if isWordBoundary(haystack, at: first) { score += 50 }
        // The characters that sit between the matches make the match weaker.
        score -= ((last - first + 1) - needle.count) * 10
        score -= first * 2
        return score
    }

    // MARK: - Matches

    /// Keeps the best hits of the search.
    ///
    /// The list holds the best `limit` hits in order. A hit that is worse
    /// than the last one in the list is dropped right away, so a config with
    /// many matches does not sort thousands of results.
    private struct BestResults {
        private let limit: Int
        private var items: [Scored] = []

        init(limit: Int) {
            self.limit = limit
            items.reserveCapacity(limit)
        }

        mutating func add(_ item: Scored) {
            if items.count == limit, !QuickOpenSearch.isOrderedBefore(item, items[items.count - 1]) {
                return
            }
            let index = items.firstIndex { QuickOpenSearch.isOrderedBefore(item, $0) } ?? items.count
            items.insert(item, at: index)
            if items.count > limit {
                items.removeLast()
            }
        }

        var results: [Result] { items.map(\.result) }
    }

    /// A hit of the search with the numbers that decide its place in the
    /// list.
    private struct Scored {
        /// Files come first when the query looks like the name of a file.
        let group: Int
        /// The match kind, from the strongest to the weakest.
        let category: Int
        /// Files come before values inside one match kind.
        let kindRank: Int
        let score: Int
        let fileID: ConfigFile.ID
        let displayName: String
        let lineNumber: Int?
        let keyPath: String?
        let valueText: String
        /// The id of the value. It is empty for a file.
        let valueID: String?

        var result: Result {
            guard let valueID else {
                return Result(
                    id: "file::\(fileID)",
                    kind: .file,
                    fileID: fileID,
                    fileName: displayName,
                    lineNumber: nil,
                    keyPath: nil,
                    valueText: ""
                )
            }
            return Result(
                id: "value::\(fileID)::\(valueID)",
                kind: .value,
                fileID: fileID,
                fileName: displayName,
                lineNumber: lineNumber,
                keyPath: keyPath,
                valueText: valueText
            )
        }
    }

    private static func fileMatch(query: String, file: ConfigFile) -> (rank: Int, score: Int)? {
        var bestScore: Int?
        var bestRank = MatchRank.fuzzy.rawValue
        for candidate in fileNameCandidates(for: file) {
            guard let score = fuzzyScore(query: query, candidate: candidate) else { continue }
            let rank = matchRank(of: candidate, query: query)
            if bestScore == nil || score > bestScore! {
                bestScore = score
            }
            bestRank = min(bestRank, rank.rawValue)
        }
        guard let score = bestScore else { return nil }
        return (bestRank, score)
    }

    private static func valueMatch(query: String, value: LuaEditableValue) -> (rank: Int, score: Int)? {
        // The key path is the better hit, so it is looked at first and the
        // text of the value is only read when the key path does not match.
        let keyPath = value.keyPath.lowercased()
        if keyPath.contains(query) {
            return (valueRank(of: keyPath, query: query).rawValue, 1000)
        }
        let text = value.draftValue.lowercased()
        guard text.contains(query) else { return nil }
        return (valueRank(of: text, query: query).rawValue, 500)
    }

    /// The match kind of a value that is known to hold the query.
    private static func valueRank(of text: String, query: String) -> MatchRank {
        if text == query { return .exact }
        if text.hasPrefix(query) { return .prefix }
        return .substring
    }

    /// True when the query looks like the name of a file: it has a path
    /// separator or a file name ending.
    static func looksLikeFileName(_ query: String) -> Bool {
        let needle = query.lowercased()
        if needle.contains("/") { return true }
        let ext = (needle as NSString).pathExtension.lowercased()
        return fileExtensions.contains(ext)
    }

    /// The names a file can be found by: its path, its path without the
    /// file name ending, its file name and its file name without the
    /// ending.
    private static func fileNameCandidates(for file: ConfigFile) -> [String] {
        let displayName = file.displayName.lowercased()
        let component = (displayName as NSString).lastPathComponent.lowercased()
        var candidates = [displayName, component]
        let pathStem = (displayName as NSString).deletingPathExtension.lowercased()
        let componentStem = (component as NSString).deletingPathExtension.lowercased()
        if !pathStem.isEmpty { candidates.append(pathStem) }
        if !componentStem.isEmpty { candidates.append(componentStem) }
        return candidates
    }

    /// How a candidate matched the query.
    private static func matchRank(of candidate: String, query: String) -> MatchRank {
        if candidate == query { return .exact }
        if candidate.hasPrefix(query) { return .prefix }
        if candidate.contains(query) { return .substring }
        return .fuzzy
    }

    /// True when the character sits at the start of the name or right after
    /// a separator.
    private static func isWordBoundary(_ text: String, at index: Int) -> Bool {
        guard index > 0 else { return true }
        let separators: Set<Character> = ["/", ".", "_", "-"]
        let before = text[text.index(text.startIndex, offsetBy: index - 1)]
        return separators.contains(before)
    }

    /// The order of the results: the group first, then the match kind, then
    /// files before values, then the score, the file name and the line.
    /// The id at the end makes the order total, so the list never changes
    /// between two runs.
    private static func isOrderedBefore(_ lhs: Scored, _ rhs: Scored) -> Bool {
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        let lhsLine = lhs.lineNumber ?? 0
        let rhsLine = rhs.lineNumber ?? 0
        if lhsLine != rhsLine { return lhsLine < rhsLine }
        let lhsKey = lhs.keyPath ?? ""
        let rhsKey = rhs.keyPath ?? ""
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return (lhs.valueID ?? lhs.fileID) < (rhs.valueID ?? rhs.fileID)
    }
}

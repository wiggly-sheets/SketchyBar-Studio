import Foundation

/// A line based diff of two texts, in the shape of a unified diff.
///
/// The engine is pure: it takes two strings and returns the hunks. It never
/// reads or writes a file, so a view can show a diff without changing
/// anything.
enum DiffEngine {
    /// One line of a diff.
    struct Line: Equatable {
        /// What the line does to the old text.
        enum Kind: Equatable {
            /// The line is in both texts.
            case context
            /// The line is only in the new text.
            case added
            /// The line is only in the old text.
            case removed
        }

        let text: String
        let kind: Kind
    }

    /// A group of changed lines with the context around them.
    struct Hunk: Identifiable, Equatable {
        let id: Int
        /// The first old line of the hunk, counted from 1.
        let oldStart: Int
        /// The number of old lines the hunk covers.
        let oldCount: Int
        /// The first new line of the hunk, counted from 1.
        let newStart: Int
        /// The number of new lines the hunk covers.
        let newCount: Int
        let lines: [Line]

        /// The lines the hunk adds.
        var addedCount: Int { lines.filter { $0.kind == .added }.count }
        /// The lines the hunk removes.
        var removedCount: Int { lines.filter { $0.kind == .removed }.count }
    }

    /// What a save would change.
    ///
    /// The hunks hold the changed lines. A difference that holds no changed
    /// line, such as a trailing newline that was added, is held by the note.
    struct Difference: Equatable {
        let hunks: [Hunk]
        /// What changed when no line changed.
        let note: String?
    }

    /// The diff of two texts, as hunks with context around every change.
    ///
    /// The comparison ignores the line ending, so a text that uses CRLF and
    /// the same text that uses LF hold the same lines. A text that does not
    /// end with a newline holds the same lines as the same text with one.
    static func diff(old: String, new: String, contextLines: Int = 3) -> [Hunk] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        let rows = rows(old: oldLines, new: newLines)
        return hunks(from: rows, contextLines: max(0, contextLines))
    }

    /// The difference between two texts.
    ///
    /// The lines are compared without the line ending, so a text that uses
    /// CRLF and the same text that uses LF hold the same lines. The bytes
    /// are compared as well: a text that does not end with a newline and
    /// the same text with one are different files, so the difference holds
    /// a note and the review never says that nothing changed.
    static func difference(old: String, new: String, contextLines: Int = 3) -> Difference {
        guard old != new else { return Difference(hunks: [], note: nil) }
        let hunks = diff(old: old, new: new, contextLines: contextLines)
        guard hunks.isEmpty else { return Difference(hunks: hunks, note: nil) }
        return Difference(hunks: [], note: lineEndingNote(old: old, new: new))
    }

    /// A short description of what the hunks change.
    static func summary(for hunks: [Hunk]) -> String {
        let added = hunks.reduce(0) { $0 + $1.addedCount }
        let removed = hunks.reduce(0) { $0 + $1.removedCount }
        let changed = added + removed
        guard changed > 0 else { return "No changes" }
        return "\(changed) \(changed == 1 ? "line" : "lines") changed, \(added) added, \(removed) removed"
    }

    /// A short description of what the difference changes.
    static func summary(for difference: Difference) -> String {
        if let note = difference.note { return note }
        return summary(for: difference.hunks)
    }

    // MARK: - Text

    /// The lines of a text.
    ///
    /// A trailing newline does not add an empty line, and a CRLF ending is
    /// the same line ending as a LF.
    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// The note for a difference that holds no changed line.
    ///
    /// The lines are the same, so the difference is in the line endings.
    private static func lineEndingNote(old: String, new: String) -> String {
        if old.hasSuffix("\n") != new.hasSuffix("\n") {
            return "Only the trailing newline changed."
        }
        return "Only the line endings changed."
    }

    // MARK: - Rows

    /// One row of the diff, with the line numbers it holds.
    private struct Row {
        let kind: Line.Kind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }

    /// The rows of the diff, in order.
    private static func rows(old: [String], new: [String]) -> [Row] {
        var rows: [Row] = []
        for op in operations(old: old, new: new) {
            switch op {
            case .equal(let oldIndex, let newIndex):
                rows.append(Row(
                    kind: .context,
                    text: old[oldIndex],
                    oldNumber: oldIndex + 1,
                    newNumber: newIndex + 1
                ))
            case .removed(let oldIndex):
                rows.append(Row(
                    kind: .removed,
                    text: old[oldIndex],
                    oldNumber: oldIndex + 1,
                    newNumber: nil
                ))
            case .added(let newIndex):
                rows.append(Row(
                    kind: .added,
                    text: new[newIndex],
                    oldNumber: nil,
                    newNumber: newIndex + 1
                ))
            }
        }
        return rows
    }

    // MARK: - Hunks

    /// The hunks of the diff.
    ///
    /// The changed rows are grouped, and two groups that are close enough
    /// share one hunk. Every hunk holds the context lines around its
    /// change and the line numbers of the old and the new text.
    private static func hunks(from rows: [Row], contextLines: Int) -> [Hunk] {
        guard !rows.isEmpty else { return [] }

        let regions = changeRegions(in: rows)
        guard !regions.isEmpty else { return [] }

        let oldBefore = oldLineCounts(before: rows)
        let newBefore = newLineCounts(before: rows)

        var hunks: [Hunk] = []
        for region in merged(regions, contextLines: contextLines) {
            let lower = max(0, region.lowerBound - contextLines)
            let upper = min(rows.count - 1, region.upperBound + contextLines)
            let hunkRows = rows[lower...upper]
            let oldNumbers = hunkRows.compactMap(\.oldNumber)
            let newNumbers = hunkRows.compactMap(\.newNumber)
            hunks.append(Hunk(
                id: hunks.count + 1,
                oldStart: oldNumbers.isEmpty ? oldBefore[lower] : oldNumbers[0],
                oldCount: oldNumbers.count,
                newStart: newNumbers.isEmpty ? newBefore[lower] : newNumbers[0],
                newCount: newNumbers.count,
                lines: hunkRows.map { Line(text: $0.text, kind: $0.kind) }
            ))
        }
        return hunks
    }

    /// The ranges of the rows that changed.
    private static func changeRegions(in rows: [Row]) -> [ClosedRange<Int>] {
        var regions: [ClosedRange<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if row.kind == .context {
                if let first = start {
                    regions.append(first...index - 1)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let first = start {
            regions.append(first...rows.count - 1)
        }
        return regions
    }

    /// The regions that share one hunk, because their context lines touch.
    private static func merged(_ regions: [ClosedRange<Int>], contextLines: Int) -> [ClosedRange<Int>] {
        var merged: [ClosedRange<Int>] = []
        for region in regions {
            if let last = merged.last, region.lowerBound <= last.upperBound + contextLines * 2 + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, region.upperBound)
            } else {
                merged.append(region)
            }
        }
        return merged
    }

    /// The number of old lines in front of every row.
    private static func oldLineCounts(before rows: [Row]) -> [Int] {
        var counts = [Int](repeating: 0, count: rows.count + 1)
        for (index, row) in rows.enumerated() {
            counts[index + 1] = counts[index] + (row.oldNumber == nil ? 0 : 1)
        }
        return counts
    }

    /// The number of new lines in front of every row.
    private static func newLineCounts(before rows: [Row]) -> [Int] {
        var counts = [Int](repeating: 0, count: rows.count + 1)
        for (index, row) in rows.enumerated() {
            counts[index + 1] = counts[index] + (row.newNumber == nil ? 0 : 1)
        }
        return counts
    }

    // MARK: - Matching

    /// One step of the edit script.
    private enum Operation {
        case equal(oldIndex: Int, newIndex: Int)
        case removed(oldIndex: Int)
        case added(newIndex: Int)
    }

    /// The edit script of the two texts.
    ///
    /// The common start and the common end are taken first, so a file with
    /// a small change only has to match a few lines.
    private static func operations(old: [String], new: [String]) -> [Operation] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        let middleOld = Array(old[prefix..<(old.count - suffix)])
        let middleNew = Array(new[prefix..<(new.count - suffix)])
        let matches = matchingPairs(middleOld, middleNew)

        var operations: [Operation] = []
        for index in 0..<prefix {
            operations.append(.equal(oldIndex: index, newIndex: index))
        }
        var oldIndex = 0
        var newIndex = 0
        for (oldMatch, newMatch) in matches {
            while oldIndex < oldMatch {
                operations.append(.removed(oldIndex: prefix + oldIndex))
                oldIndex += 1
            }
            while newIndex < newMatch {
                operations.append(.added(newIndex: prefix + newIndex))
                newIndex += 1
            }
            operations.append(.equal(oldIndex: prefix + oldMatch, newIndex: prefix + newMatch))
            oldIndex += 1
            newIndex += 1
        }
        while oldIndex < middleOld.count {
            operations.append(.removed(oldIndex: prefix + oldIndex))
            oldIndex += 1
        }
        while newIndex < middleNew.count {
            operations.append(.added(newIndex: prefix + newIndex))
            newIndex += 1
        }
        for index in 0..<suffix {
            operations.append(.equal(
                oldIndex: old.count - suffix + index,
                newIndex: new.count - suffix + index
            ))
        }
        return operations
    }

    /// The lines of the two texts that are the same, in order.
    private static func matchingPairs(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        if let pairs = myersPairs(old, new) { return pairs }
        return anchorPairs(old, new)
    }

    /// The common lines of two texts, found with the Myers algorithm.
    ///
    /// The search is bounded by `maxDifferences`. When the texts have more
    /// differences than that, the search gives up and the anchors are used
    /// instead, so a very different pair of texts cannot take long.
    private static func myersPairs(_ old: [String], _ new: [String], maxDifferences: Int = 800) -> [(Int, Int)]? {
        let oldCount = old.count
        let newCount = new.count
        let offset = maxDifferences + 1
        var furthest = [Int](repeating: 0, count: 2 * maxDifferences + 3)
        var trace: [[Int]] = []
        trace.reserveCapacity(maxDifferences + 1)

        for differences in 0...maxDifferences {
            trace.append(furthest)
            var diagonal = -differences
            while diagonal <= differences {
                var x: Int
                if diagonal == -differences
                    || (diagonal != differences && furthest[diagonal - 1 + offset] < furthest[diagonal + 1 + offset]) {
                    x = furthest[diagonal + 1 + offset]
                } else {
                    x = furthest[diagonal - 1 + offset] + 1
                }
                var y = x - diagonal
                while x < oldCount, y < newCount, old[x] == new[y] {
                    x += 1
                    y += 1
                }
                furthest[diagonal + offset] = x
                if x >= oldCount, y >= newCount {
                    return backtrack(
                        trace: trace,
                        differences: differences,
                        offset: offset,
                        oldCount: oldCount,
                        newCount: newCount
                    )
                }
                diagonal += 2
            }
        }
        return nil
    }

    /// The common lines of the Myers search, read back from its trace.
    private static func backtrack(
        trace: [[Int]],
        differences: Int,
        offset: Int,
        oldCount: Int,
        newCount: Int
    ) -> [(Int, Int)] {
        // The search ended at the end of both texts.
        var x = oldCount
        var y = newCount
        var pairs: [(Int, Int)] = []

        var step = differences
        while step > 0 {
            let furthest = trace[step]
            let diagonal = x - y
            let previousDiagonal: Int
            if diagonal == -step
                || (diagonal != step && furthest[diagonal - 1 + offset] < furthest[diagonal + 1 + offset]) {
                previousDiagonal = diagonal + 1
            } else {
                previousDiagonal = diagonal - 1
            }
            let previousX = furthest[previousDiagonal + offset]
            let previousY = previousX - previousDiagonal
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                pairs.append((x, y))
            }
            x = previousX
            y = previousY
            step -= 1
        }
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            pairs.append((x, y))
        }
        return Array(pairs.reversed())
    }

    /// The common lines of two very different texts.
    ///
    /// The lines that appear exactly once in both texts are the anchors.
    /// The longest run of anchors that keeps the order of both texts is the
    /// common part, so the result is always a valid common subsequence.
    private static func anchorPairs(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        var oldCounts: [String: Int] = [:]
        for line in old { oldCounts[line, default: 0] += 1 }
        var newCounts: [String: Int] = [:]
        for line in new { newCounts[line, default: 0] += 1 }

        var newIndex: [String: Int] = [:]
        for (index, line) in new.enumerated() where newCounts[line] == 1 {
            newIndex[line] = index
        }

        var candidates: [(Int, Int)] = []
        for (index, line) in old.enumerated() where oldCounts[line] == 1 {
            if let match = newIndex[line] {
                candidates.append((index, match))
            }
        }
        guard !candidates.isEmpty else { return [] }
        return longestIncreasingRun(candidates)
    }

    /// The longest run of candidates that keeps the order of both texts.
    private static func longestIncreasingRun(_ candidates: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []
        var tailCandidates: [Int] = []
        var previous = [Int](repeating: -1, count: candidates.count)

        for (index, candidate) in candidates.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if candidates[tails[middle]].1 < candidate.1 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            previous[index] = low > 0 ? tailCandidates[low - 1] : -1
            if low == tails.count {
                tails.append(index)
                tailCandidates.append(index)
            } else {
                tails[low] = index
                tailCandidates[low] = index
            }
        }

        guard let last = tailCandidates.last else { return [] }
        var run: [(Int, Int)] = []
        var index = last
        while index >= 0 {
            run.append(candidates[index])
            index = previous[index]
        }
        return run.reversed()
    }
}

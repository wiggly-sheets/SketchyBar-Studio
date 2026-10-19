import Foundation

/// One problem the validator found in a config.
///
/// A diagnostic is a plain value. It names the problem, says where the
/// problem is, and never changes the config.
struct ConfigDiagnostic: Identifiable, Hashable {
    /// How bad the problem is. The errors come first in a report.
    enum Severity: Int, Comparable {
        case error
        case warning
        case info

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The kind of problem. The name of the kind is part of the id of the
    /// diagnostic, so it must not change.
    enum Kind: String {
        case unknownOption
        case invalidValue
        case duplicateAlias
        case missingTarget
        case orphanFile
        case unbalancedTable
        case noItemDeclaration
        case duplicateKey
    }

    /// The id of the diagnostic. It is the same for the same problem in
    /// every run, so a report does not jump around.
    let id: String
    let severity: Severity
    let kind: Kind
    /// One short line that names the problem.
    let title: String
    /// A second line that explains the problem.
    let detail: String?
    /// The file the problem is in.
    let fileURL: URL?
    /// The line of the file the problem is on.
    let line: Int?
    /// The option or the alias the problem is about.
    let keyPath: String?
}

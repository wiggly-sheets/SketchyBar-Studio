import Foundation

/// What a catalogue entry installs into.
enum StoreEntryKind: String, Codable, CaseIterable, Identifiable {
    case plugin
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plugin:
            return "Plugins"
        case .setup:
            return "Setups"
        }
    }
}

/// Licences the catalogue accepts. Anything else is not installable, so an
/// entry that cannot be verified never reaches this type.
enum StoreLicence: String, Codable, CaseIterable {
    case mit = "MIT"
    case apache2 = "Apache-2.0"
    case bsd2 = "BSD-2-Clause"
    case bsd3 = "BSD-3-Clause"
    case isc = "ISC"
    case unlicense = "Unlicense"
    case cc0 = "CC0-1.0"

    static let permissive: Set<StoreLicence> = [.mit, .apache2, .bsd2, .bsd3, .isc, .unlicense, .cc0]

    var isPermissive: Bool {
        Self.permissive.contains(self)
    }
}

/// One curated repository file or tree.
///
/// `ref` is a tag or a commit, never a branch: a branch moves, so a pinned
/// entry would silently start installing different code.
struct StoreEntry: Identifiable, Hashable {
    let id: String
    let kind: StoreEntryKind
    let name: String
    let author: String
    /// `owner/repo`.
    let repository: String
    /// File path for a plugin, subdirectory for a setup, empty for the whole
    /// repository.
    let path: String
    let ref: String
    /// Missing when no licence was verified. Such an entry is listed as not
    /// installable and every fetch refuses it.
    let licence: StoreLicence?
    let licenceURL: String
    let summary: String
    let tags: [String]

    var rawFileURLString: String {
        let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "https://raw.githubusercontent.com/\(repository)/\(ref)/\(escapedPath)"
    }

    var archiveURLString: String {
        "https://codeload.github.com/\(repository)/tar.gz/\(ref)"
    }

    var repositoryIsWellFormed: Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return parts.allSatisfy { part in
            !part.isEmpty
                && part != "."
                && part != ".."
                && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    /// Branches move, so they are not pinned refs.
    var hasPinnedRef: Bool {
        guard !ref.isEmpty, !ref.contains(where: \.isWhitespace) else { return false }
        let branchNames = ["main", "master", "head", "develop", "development", "dev", "trunk", "latest"]
        return !branchNames.contains(ref.lowercased()) && !ref.lowercased().hasPrefix("refs/heads/")
    }

    /// Rejects absolute paths, `..` components and backslashes. An empty path
    /// is the whole repository, which is only meaningful for a setup.
    var hasSafePath: Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    var isInstallable: Bool {
        guard let licence, licence.isPermissive else { return false }
        guard !licenceURL.isEmpty else { return false }
        guard repositoryIsWellFormed, hasPinnedRef, hasSafePath else { return false }
        switch kind {
        case .plugin:
            return !path.isEmpty && !path.hasSuffix("/")
        case .setup:
            return true
        }
    }
}

enum StoreCatalogue {
    /// Every entry below was checked by fetching the repository `LICENSE` at
    /// the pinned ref, and by confirming the entry path answers at that ref.
    /// Entries without a verified permissive licence do not belong here.
    static let entries: [StoreEntry] = [
        StoreEntry(
            id: "aimuzov-sketchybar-items-datetime",
            kind: .plugin,
            name: "Date & Time",
            author: "aimuzov",
            repository: "aimuzov/sketchybar-items",
            path: "items/datetime.lua",
            ref: "2a1d04a5f1812a971a64b59c1c9506c75e2dc69e",
            licence: .mit,
            licenceURL: "https://github.com/aimuzov/sketchybar-items/blob/2a1d04a5f1812a971a64b59c1c9506c75e2dc69e/LICENSE",
            summary: "A clock item for SbarLua configs. It watches nothing and needs no external tool, so it draws on any machine.",
            tags: ["lua", "sbar-lua", "clock"]
        ),
        StoreEntry(
            id: "wthrajat-sketchybar-now-playing-item",
            kind: .plugin,
            name: "Now Playing",
            author: "wthrajat",
            repository: "wthrajat/sketchybar-now-playing",
            path: "items/now_playing.lua",
            ref: "v0.4.3",
            licence: .mit,
            licenceURL: "https://github.com/wthrajat/sketchybar-now-playing/blob/v0.4.3/LICENSE",
            summary: "Shows the track that is playing in any media app. It needs the helper binary from the same repository on PATH.",
            tags: ["lua", "sbar-lua", "media"]
        ),
        StoreEntry(
            id: "tissak-sketchybar-zai-quota",
            kind: .plugin,
            name: "Z.ai Quota",
            author: "tissak",
            repository: "tissak/sketchybar-zai-quota",
            path: "plugins/zai-quota/zai-quota.sh",
            ref: "cd21c64db6098e57cd053c8e0013ebd142ce973d",
            licence: .mit,
            licenceURL: "https://github.com/tissak/sketchybar-zai-quota/blob/cd21c64db6098e57cd053c8e0013ebd142ce973d/LICENSE",
            summary: "A shell item that shows token use of a Z.ai GLM coding plan. It needs curl and jq, and keeps its API key outside the config.",
            tags: ["shell", "quota", "api"]
        ),
        StoreEntry(
            id: "walshg3-sketchybar-islands",
            kind: .setup,
            name: "SketchyBar Islands",
            author: "walshg3",
            repository: "walshg3/sketchybar-islands",
            path: "",
            ref: "v1.0.0",
            licence: .mit,
            licenceURL: "https://github.com/walshg3/sketchybar-islands/blob/v1.0.0/LICENSE",
            summary: "Three Catppuccin islands driven by AeroSpace and SbarLua. Installs as a new profile, apart from the config you use.",
            tags: ["lua", "sbar-lua", "aerospace", "catppuccin"]
        ),
        StoreEntry(
            id: "g-udi-gaudi-sketchybar",
            kind: .setup,
            name: "Gaudi SketchyBar",
            author: "g-udi",
            repository: "g-udi/gaudi-sketchybar",
            path: "",
            ref: "ea5ecd4a7fa43d42bd22d7f473a43ddb711da094",
            licence: .mit,
            licenceURL: "https://github.com/g-udi/gaudi-sketchybar/blob/ea5ecd4a7fa43d42bd22d7f473a43ddb711da094/LICENSE",
            summary: "A shell setup with a top notification bar and a bottom status bar, built from small plugins under lib/plugins.",
            tags: ["shell", "two-bars", "notifications"]
        ),
        StoreEntry(
            id: "crissnb-dynamic-island-sketchybar",
            kind: .setup,
            name: "Dynamic Island",
            author: "crissNb",
            repository: "crissNb/Dynamic-Island-Sketchybar",
            path: "",
            ref: "alpha-05",
            licence: .mit,
            licenceURL: "https://github.com/crissNb/Dynamic-Island-Sketchybar/blob/alpha-05/LICENSE",
            summary: "A Dynamic Island style notch bar with music, volume, brightness, wifi and power islands.",
            tags: ["shell", "notch", "media"]
        )
    ]
}

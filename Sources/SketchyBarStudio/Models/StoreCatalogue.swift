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

/// An external tool an entry needs before it can run. `required` is true
/// when the entry cannot work without it; a font dep is needed for the
/// glyphs the entry draws, not for the file to load.
struct StoreDependency: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case formula
        case cask
        case command
        case font
        case sketchybar
    }

    let kind: Kind
    let name: String
    let required: Bool
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
    /// Additional files (relative to repository root, same ref) that must be
    /// copied alongside the entry file. For single-file plugins this is empty.
    let files: [String]
    let ref: String
    /// Missing when no licence was verified. Such an entry is listed as not
    /// installable and every fetch refuses it.
    let licence: StoreLicence?
    let licenceURL: String
    let summary: String
    let tags: [String]
    /// External tools the entry needs. Empty when the entry needs nothing
    /// or the requirement could not be verified from the entry's own
    /// repository, so an empty list never means "nothing is needed".
    let dependencies: [StoreDependency]

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
            files: [],
            ref: "2a1d04a5f1812a971a64b59c1c9506c75e2dc69e",
            licence: .mit,
            licenceURL: "https://github.com/aimuzov/sketchybar-items/blob/2a1d04a5f1812a971a64b59c1c9506c75e2dc69e/LICENSE",
            summary: "A clock item for SbarLua configs. It watches nothing and needs no external tool, so it draws on any machine.",
            tags: ["lua", "sbar-lua", "clock"],
            dependencies: []
        ),
        StoreEntry(
            id: "wthrajat-sketchybar-now-playing-item",
            kind: .plugin,
            name: "Now Playing",
            author: "wthrajat",
            repository: "wthrajat/sketchybar-now-playing",
            path: "items/now_playing.lua",
            files: [],
            ref: "v0.4.3",
            licence: .mit,
            licenceURL: "https://github.com/wthrajat/sketchybar-now-playing/blob/v0.4.3/LICENSE",
            summary: "Shows the track that is playing in any media app. It needs the helper binary from the same repository on PATH.",
            tags: ["lua", "sbar-lua", "media"],
            dependencies: [
                StoreDependency(kind: .command, name: "sketchybar-now-playing", required: true)
            ]
        ),
        StoreEntry(
            id: "tissak-sketchybar-zai-quota",
            kind: .plugin,
            name: "Z.ai Quota",
            author: "tissak",
            repository: "tissak/sketchybar-zai-quota",
            path: "plugins/zai-quota/zai-quota.sh",
            files: [],
            ref: "cd21c64db6098e57cd053c8e0013ebd142ce973d",
            licence: .mit,
            licenceURL: "https://github.com/tissak/sketchybar-zai-quota/blob/cd21c64db6098e57cd053c8e0013ebd142ce973d/LICENSE",
            summary: "A shell item that shows token use of a Z.ai GLM coding plan. It needs curl and jq, and keeps its API key outside the config.",
            tags: ["shell", "quota", "api"],
            dependencies: [
                StoreDependency(kind: .command, name: "curl", required: true),
                StoreDependency(kind: .command, name: "jq", required: true)
            ]
        ),
        StoreEntry(
            id: "walshg3-sketchybar-islands",
            kind: .setup,
            name: "SketchyBar Islands",
            author: "walshg3",
            repository: "walshg3/sketchybar-islands",
            path: "",
            files: [],
            ref: "v1.0.0",
            licence: .mit,
            licenceURL: "https://github.com/walshg3/sketchybar-islands/blob/v1.0.0/LICENSE",
            summary: "Three Catppuccin islands driven by AeroSpace and SbarLua. Installs as a new profile, apart from the config you use.",
            tags: ["lua", "sbar-lua", "aerospace", "catppuccin"],
            dependencies: [
                StoreDependency(kind: .command, name: "lua", required: true),
                StoreDependency(kind: .command, name: "SwitchAudioSource", required: true),
                StoreDependency(kind: .command, name: "stats_provider", required: true),
                StoreDependency(kind: .command, name: "python3", required: true),
                StoreDependency(kind: .command, name: "bash", required: true),
                StoreDependency(kind: .font, name: "SF Pro", required: true),
                StoreDependency(kind: .font, name: "SF Mono", required: true),
                StoreDependency(kind: .font, name: "Symbols Nerd Font", required: true),
                StoreDependency(kind: .font, name: "sketchybar-app-font", required: true)
            ]
        ),
        StoreEntry(
            id: "g-udi-gaudi-sketchybar",
            kind: .setup,
            name: "Gaudi SketchyBar",
            author: "g-udi",
            repository: "g-udi/gaudi-sketchybar",
            path: "",
            files: [],
            ref: "ea5ecd4a7fa43d42bd22d7f473a43ddb711da094",
            licence: .mit,
            licenceURL: "https://github.com/g-udi/gaudi-sketchybar/blob/ea5ecd4a7fa43d42bd22d7f473a43ddb711da094/LICENSE",
            summary: "A shell setup with a top notification bar and a bottom status bar, built from small plugins under lib/plugins.",
            tags: ["shell", "two-bars", "notifications"],
            dependencies: [
                StoreDependency(kind: .sketchybar, name: "sketchybar", required: true),
                StoreDependency(kind: .command, name: "jq", required: true),
                StoreDependency(kind: .command, name: "python3", required: true),
                StoreDependency(kind: .command, name: "osascript", required: true),
                StoreDependency(kind: .command, name: "bash", required: true),
                StoreDependency(kind: .command, name: "icalBuddy", required: false),
                StoreDependency(kind: .command, name: "yabai", required: false),
                StoreDependency(kind: .command, name: "gh", required: false),
                StoreDependency(kind: .command, name: "stats_provider", required: false),
                StoreDependency(kind: .command, name: "macmon", required: false),
                StoreDependency(kind: .font, name: "MesloLGS NF", required: true),
                StoreDependency(kind: .font, name: "sketchybar-app-font", required: true)
            ]
        ),
        StoreEntry(
            id: "crissnb-dynamic-island-sketchybar",
            kind: .setup,
            name: "Dynamic Island",
            author: "crissNb",
            repository: "crissNb/Dynamic-Island-Sketchybar",
            path: "",
            files: [],
            ref: "alpha-05",
            licence: .mit,
            licenceURL: "https://github.com/crissNb/Dynamic-Island-Sketchybar/blob/alpha-05/LICENSE",
            summary: "A Dynamic Island style notch bar with music, volume, brightness, wifi and power islands.",
            tags: ["shell", "notch", "media"],
            dependencies: [
                StoreDependency(kind: .command, name: "jq", required: true),
                StoreDependency(kind: .command, name: "cava", required: false),
                StoreDependency(kind: .cask, name: "sf-symbols", required: true),
                StoreDependency(kind: .cask, name: "background-music", required: false)
            ]
        ),
        StoreEntry(
            id: "aserranoni-sketchybar-brightness",
            kind: .plugin,
            name: "Brightness Slider",
            author: "aserranoni",
            repository: "aserranoni/sketchybar-brightness",
            path: "items/brightness.sh",
            files: [
                "plugins/brightness.sh",
                "plugins/brightness_click.sh",
                "plugins/brightness_trigger.sh"
            ],
            ref: "92f2194dba72b7c4bd6854dd37d84192904174c5",
            licence: .mit,
            licenceURL: "https://github.com/aserranoni/sketchybar-brightness/blob/92f2194dba72b7c4bd6854dd37d84192904174c5/LICENSE",
            summary: "A brightness slider and indicator. Needs the external `brightness` binary. Installs as a folder with the item and its plugins.",
            tags: ["shell", "brightness", "slider"],
            dependencies: [
                StoreDependency(kind: .command, name: "brightness", required: true),
                StoreDependency(kind: .command, name: "jq", required: true)
            ]
        ),
        StoreEntry(
            id: "aserranoni-sketchybar-system-monitoring",
            kind: .plugin,
            name: "System Monitoring",
            author: "aserranoni",
            repository: "aserranoni/sketchybar-system-monitoring",
            path: "items/ram.sh",
            files: [
                "items/battery_simple.sh",
                "items/cpu_simple.sh",
                "plugins/battery_simple.sh",
                "plugins/cpu_simple.sh",
                "plugins/ram.sh"
            ],
            ref: "7cdb3578aaa88344f48b11c00dd1c689281557fd",
            licence: .mit,
            licenceURL: "https://github.com/aserranoni/sketchybar-system-monitoring/blob/7cdb3578aaa88344f48b11c00dd1c689281557fd/LICENSE",
            summary: "Battery, CPU and memory items. Needs a system_stats event provider (e.g. sketchybar-system-stats). Installs the items and their plugins.",
            tags: ["shell", "battery", "cpu", "memory"],
            dependencies: [
                StoreDependency(kind: .command, name: "pmset", required: true),
                StoreDependency(kind: .command, name: "system_stats provider", required: true)
            ]
        ),
        StoreEntry(
            id: "lucasoesterbye-sketchybar-timewarrior",
            kind: .plugin,
            name: "Timewarrior Tracker",
            author: "LucasOesterbye",
            repository: "LucasOesterbye/sketchybar-timewarrior",
            path: "timewarrior/item.sh",
            files: [
                "timewarrior/action.sh",
                "timewarrior/away.sh",
                "timewarrior/config.sh",
                "timewarrior/hover.sh",
                "timewarrior/lib.sh",
                "timewarrior/menu.sh",
                "timewarrior/stats.py",
                "timewarrior/timew.sh"
            ],
            ref: "37f524c26fcd67adbf071c3a33edce61dee19c9c",
            licence: .mit,
            licenceURL: "https://github.com/LucasOesterbye/sketchybar-timewarrior/blob/37f524c26fcd67adbf071c3a33edce61dee19c9c/LICENSE",
            summary: "Timewarrior time tracker with live timer, dropdown menu and auto-pause. Needs timewarrior, python3 and a Nerd Font.",
            tags: ["shell", "timewarrior", "timer"],
            dependencies: [
                StoreDependency(kind: .command, name: "timew", required: true),
                StoreDependency(kind: .command, name: "python3", required: true)
            ]
        ),
        StoreEntry(
            id: "wthrajat-sketchybar-now-playing-shell",
            kind: .plugin,
            name: "Now Playing (Shell)",
            author: "wthrajat",
            repository: "wthrajat/sketchybar-now-playing",
            path: "items/now_playing.sh",
            files: [
                "plugins/now_playing.sh"
            ],
            ref: "ef2572ec23c700d77c4144d83d7eb5cd82203888",
            licence: .mit,
            licenceURL: "https://github.com/wthrajat/sketchybar-now-playing/blob/ef2572ec23c700d77c4144d83d7eb5cd82203888/LICENSE",
            summary: "Shell variant of the now playing item. Needs the sketchybar-now-playing binary on PATH.",
            tags: ["shell", "media"],
            dependencies: [
                StoreDependency(kind: .command, name: "sketchybar-now-playing", required: true)
            ]
        ),
        StoreEntry(
            id: "logicsec-sketchybar-setup",
            kind: .setup,
            name: "Logicsec SketchyBar",
            author: "logicsec",
            repository: "logicsec/sketchybar",
            path: "",
            files: [],
            ref: "9d95690eacda47ab029c633670545dfbb6b678f1",
            licence: .mit,
            licenceURL: "https://github.com/logicsec/sketchybar/blob/9d95690eacda47ab029c633670545dfbb6b678f1/LICENSE",
            summary: "A full Lua config with bar, items, widgets and C event providers. Installs as a new profile.",
            tags: ["lua", "sbar-lua", "metrics", "notifications", "media"],
            dependencies: [
                StoreDependency(kind: .command, name: "lua", required: true),
                StoreDependency(kind: .sketchybar, name: "sketchybar", required: true)
            ]
        ),
        StoreEntry(
            id: "dividendsolo-omarchy-sketchybar",
            kind: .setup,
            name: "Omarchy SketchyBar",
            author: "dividendsolo",
            repository: "dividendsolo/omarchy4mac",
            path: "sketchybar",
            files: [],
            ref: "a9a487acaa66ace120c247ea4e3ab1a3c3c902e1",
            licence: .mit,
            licenceURL: "https://github.com/dividendsolo/omarchy4mac/blob/a9a487acaa66ace120c247ea4e3ab1a3c3c902e1/LICENSE",
            summary: "A shell config with AeroSpace workspaces, media, indicators and theme switching. Installs as a new profile.",
            tags: ["shell", "aerospace", "media", "theme"],
            dependencies: [
                StoreDependency(kind: .command, name: "jq", required: true),
                StoreDependency(kind: .command, name: "aerospace", required: true),
                StoreDependency(kind: .command, name: "media-control", required: false),
                StoreDependency(kind: .command, name: "omarchy-tui", required: false),
                StoreDependency(kind: .command, name: "sketchybar", required: true),
                StoreDependency(kind: .font, name: "Hack Nerd Font", required: true)
            ]
        ),
        StoreEntry(
            id: "pranav-js-sketchybar-config",
            kind: .setup,
            name: "Pranav JS SketchyBar",
            author: "pranav-js",
            repository: "pranav-js/sketchybar-config",
            path: "",
            files: [],
            ref: "5af69628dd5262c1adbda6403f6642f67b876dc1",
            licence: .mit,
            licenceURL: "https://github.com/pranav-js/sketchybar-config/blob/5af69628dd5262c1adbda6403f6642f67b876dc1/LICENSE",
            summary: "A shell config with AeroSpace, system widgets and media. Installs as a new profile.",
            tags: ["shell", "aerospace", "cpu", "memory", "media"],
            dependencies: [
                StoreDependency(kind: .command, name: "jq", required: true),
                StoreDependency(kind: .command, name: "aerospace", required: true),
                StoreDependency(kind: .command, name: "sketchybar", required: true),
                StoreDependency(kind: .font, name: "Hack Nerd Font", required: true)
            ]
        )
    ]
}

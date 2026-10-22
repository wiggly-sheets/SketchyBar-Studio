import Foundation

enum StoreInstallLocation: String, Codable {
    case configFile
    case profile
}

/// A loader line this app added. Uninstall reverts exactly this line and
/// nothing else.
struct StoreLoaderEdit: Codable, Hashable {
    let entrypointPath: String
    let line: String
}

struct StoreInstallRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let entryID: String
    let kind: StoreEntryKind
    let name: String
    let author: String
    let licence: StoreLicence?
    let licenceURL: String
    let location: StoreInstallLocation
    /// Relative to the config root for a plugin, absolute for a profile.
    let installedPath: String
    let loaderEdit: StoreLoaderEdit?
    let installedAt: Date
}

struct StoreManifest: Codable {
    var version: Int
    var configRoot: String
    var configID: String
    var records: [StoreInstallRecord]
}

enum StoreInstallError: LocalizedError, Equatable {
    case manifestMismatch(String)
    case manifestTampered(String)
    case loaderEditChanged(String)

    var errorDescription: String? {
        switch self {
        case .manifestMismatch(let path):
            return "The install manifest belongs to another config folder. Refusing to use it for \(path)."
        case .manifestTampered(let reason):
            return "Refusing to uninstall from a manifest that does not match this config: \(reason)"
        case .loaderEditChanged(let path):
            return "The loader line changed on disk, so \(path) was not edited. Remove the line by hand if you still want it gone."
        }
    }
}

/// Reads and writes the install manifest under Application Support, keyed by
/// the config root. Uninstall trusts this file and nothing else.
struct StoreManifestStore {
    static let version = 1

    private let fileManager: FileManager
    private let appSupportRoot: URL

    init(fileManager: FileManager = .default, appSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        self.appSupportRoot = appSupportRoot ?? Self.defaultAppSupportRoot(fileManager: fileManager)
    }

    private static func defaultAppSupportRoot(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SketchyBarStudio")
    }

    func manifestURL(forConfigRoot root: URL) -> URL {
        appSupportRoot
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent(Self.key(for: root), isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    func load(configRoot: URL, configID: String) throws -> StoreManifest {
        let path = configRoot.standardizedFileURL.path
        let url = manifestURL(forConfigRoot: configRoot)
        guard fileManager.fileExists(atPath: url.path) else {
            return StoreManifest(version: Self.version, configRoot: path, configID: configID, records: [])
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(StoreManifest.self, from: data) else {
            throw StoreInstallError.manifestTampered("the manifest cannot be read")
        }
        guard manifest.configRoot == path else {
            throw StoreInstallError.manifestMismatch(path)
        }
        return manifest
    }

    func save(_ manifest: StoreManifest, configRoot: URL) throws {
        let url = manifestURL(forConfigRoot: configRoot)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    func append(_ record: StoreInstallRecord, configRoot: URL, configID: String) throws {
        var manifest = try load(configRoot: configRoot, configID: configID)
        manifest.records.append(record)
        try save(manifest, configRoot: configRoot)
    }

    func remove(recordID: UUID, configRoot: URL, configID: String) throws -> StoreInstallRecord {
        var manifest = try load(configRoot: configRoot, configID: configID)
        guard let index = manifest.records.firstIndex(where: { $0.id == recordID }) else {
            throw StoreInstallError.manifestTampered("the record is not in the manifest")
        }
        let record = manifest.records.remove(at: index)
        try save(manifest, configRoot: configRoot)
        return record
    }

    static func key(for root: URL) -> String {
        let path = root.standardizedFileURL.path
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }

        let name = root.standardizedFileURL.lastPathComponent
        let cleanName = String(name.map { character in
            character.isLetter || character.isNumber ? character : "-"
        }.prefix(40))
        return "\(cleanName.isEmpty ? "root" : cleanName)-\(String(hash, radix: 16))"
    }
}

enum StoreLoaderOutcome: Equatable {
    case inserted(entrypoint: String, line: String)
    case alreadyActive(line: String)
    /// The app did not edit a loader. The line is shown so the user can add
    /// it; an inert file is never left without saying so.
    case manual(line: String, reason: String)
}

struct StoreInstallOutcome {
    let record: StoreInstallRecord
    let installedURL: URL
    /// Nil for a setup: a profile has no loader line of its own.
    let loader: StoreLoaderOutcome?
}

struct StoreInstallService {
    static let pluginDirectoryName = "plugins"

    private let fileManager: FileManager
    private let replacer: SafeFileReplacer
    private let backup: ConfigBackupService
    private let activation: ConfigActivationService
    private let profiles: ProfileArchiveService
    private let manifest: StoreManifestStore

    init(fileManager: FileManager = .default, appSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        let supportRoot = appSupportRoot ?? Self.defaultAppSupportRoot(fileManager: fileManager)
        self.replacer = SafeFileReplacer(fileManager: fileManager, appSupportRoot: supportRoot)
        self.backup = ConfigBackupService(fileManager: fileManager)
        self.activation = ConfigActivationService()
        self.profiles = ProfileArchiveService(fileManager: fileManager, appSupportRoot: supportRoot)
        self.manifest = StoreManifestStore(fileManager: fileManager, appSupportRoot: supportRoot)
    }

    private static func defaultAppSupportRoot(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SketchyBarStudio")
    }

    func records(configRoot: URL, configID: String) throws -> [StoreInstallRecord] {
        try manifest.load(configRoot: configRoot, configID: configID).records
    }

    /// Writes the plugin file(s) into `plugins/<entry id>/`, then adds one loader line.
    /// The caller has already shown the bytes and collected the licence
    /// acknowledgement.
    func installPlugin(
        _ entry: StoreEntry,
        contents: Data,
        configRoot: URL,
        configID: String
    ) throws -> StoreInstallOutcome {
        guard entry.kind == .plugin, entry.isInstallable else {
            throw StoreError.licenceMissing
        }
        guard let entryFileName = Self.pluginFileName(from: entry.path) else {
            throw StoreError.invalidEntry("The plugin path has no safe file name.")
        }

        let root = configRoot.standardizedFileURL
        let isMultiFile = !entry.files.isEmpty
        let directory = isMultiFile
            ? root.appendingPathComponent(Self.pluginDirectoryName, isDirectory: true).appendingPathComponent(entry.id, isDirectory: true)
            : root.appendingPathComponent(Self.pluginDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let entryDestination = try replacer.containedChild(named: entryFileName, of: directory)
        let entryTarget = replacer.resolvedFileURL(for: entryDestination)

        var existingPermissions: NSNumber?
        if fileManager.fileExists(atPath: entryTarget.path) {
            existingPermissions = (try? fileManager.attributesOfItem(atPath: entryTarget.path))?[.posixPermissions] as? NSNumber
            _ = try backup.backup(fileURL: entryDestination, rootURL: root)
        }

        try contents.write(to: entryTarget, options: .atomic)
        if let existingPermissions {
            try? fileManager.setAttributes([.posixPermissions: existingPermissions], ofItemAtPath: entryTarget.path)
        }

        // Multi-file extras are written by the caller (StoreModel.install) after
        // this method returns. This method writes the primary file only.

        let relativePath = isMultiFile
            ? "\(Self.pluginDirectoryName)/\(entry.id)/\(entryFileName)"
            : "\(Self.pluginDirectoryName)/\(entryFileName)"
        let loader = insertLoaderLine(for: relativePath, root: root)

        let record = StoreInstallRecord(
            id: UUID(),
            entryID: entry.id,
            kind: .plugin,
            name: entry.name,
            author: entry.author,
            licence: entry.licence,
            licenceURL: entry.licenceURL,
            location: .configFile,
            installedPath: isMultiFile ? "\(Self.pluginDirectoryName)/\(entry.id)" : relativePath,
            loaderEdit: Self.loaderEdit(from: loader),
            installedAt: .now
        )
        try manifest.append(record, configRoot: root, configID: configID)
        return StoreInstallOutcome(record: record, installedURL: entryDestination, loader: loader)
    }

    /// Copies a fetched setup tree into a new profile. The live config is not
    /// touched, so the setup stays separate and fully editable.
    func installSetup(
        _ entry: StoreEntry,
        tree: URL,
        configRoot: URL,
        configID: String
    ) throws -> StoreInstallOutcome {
        guard entry.kind == .setup, entry.isInstallable else {
            throw StoreError.licenceMissing
        }

        let profileName = uniqueProfileName(entry.name, configID: configID)
        try profiles.saveProfile(named: profileName, from: tree, configID: configID)
        let profileURL = profiles.profilesRoot(for: configID).appendingPathComponent(profileName, isDirectory: true)

        let record = StoreInstallRecord(
            id: UUID(),
            entryID: entry.id,
            kind: .setup,
            name: entry.name,
            author: entry.author,
            licence: entry.licence,
            licenceURL: entry.licenceURL,
            location: .profile,
            installedPath: profileURL.standardizedFileURL.path,
            loaderEdit: nil,
            installedAt: .now
        )
        let root = configRoot.standardizedFileURL
        try manifest.append(record, configRoot: root, configID: configID)
        return StoreInstallOutcome(record: record, installedURL: profileURL, loader: nil)
    }

    /// Removes exactly the recorded path and reverts exactly the recorded
    /// loader line. Every check runs before the first mutation.
    /// For multi-file plugins, removes the entire recorded folder.
    @discardableResult
    func uninstall(recordID: UUID, configRoot: URL, configID: String) throws -> [URL] {
        let root = configRoot.standardizedFileURL
        let manifestStore = manifest
        let record = try manifestStore.load(configRoot: root, configID: configID)
            .records
            .first { $0.id == recordID }
        guard let record else {
            throw StoreInstallError.manifestTampered("the record is not in the manifest")
        }

        switch record.location {
        case .configFile:
            let targetURL = try validatedRelativeURL(record.installedPath, root: root)
            let loaderPlan = try record.loaderEdit.map { edit in
                try loaderRevertPlan(edit, root: root)
            }

            if let loaderPlan {
                try backupRemoval(of: loaderPlan.url, root: root)
                try replacer.writeAtomicallyPreservingSymlinks(
                    loaderPlan.mark + loaderPlan.revertedContents,
                    to: loaderPlan.url
                )
            }
            var removed: [URL] = []
            if fileManager.fileExists(atPath: targetURL.path) {
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir)
                if isDir.boolValue {
                    _ = try backup.backup(fileURL: targetURL, rootURL: root)
                    try fileManager.removeItem(at: targetURL)
                } else {
                    _ = try backup.backup(fileURL: targetURL, rootURL: root)
                    try fileManager.removeItem(at: targetURL)
                }
                removed.append(targetURL)
            }
            _ = try manifestStore.remove(recordID: recordID, configRoot: root, configID: configID)
            if let loaderPlan {
                removed.append(loaderPlan.url)
            }
            return removed

        case .profile:
            let profileURL = try validatedProfileURL(record.installedPath, configID: configID)
            guard fileManager.fileExists(atPath: profileURL.path) else {
                throw StoreInstallError.manifestTampered("the profile does not exist")
            }
            try fileManager.removeItem(at: profileURL)
            _ = try manifestStore.remove(recordID: recordID, configRoot: root, configID: configID)
            return [profileURL]
        }
    }

    // MARK: - Loader line

    /// `require("plugins.datetime")` for a Lua file,
    /// `source "$CONFIG_DIR/plugins/x.sh"` for a shell file.
    static func loaderLine(forFileNamed fileName: String) -> String? {
        let nsName = fileName as NSString
        let base = nsName.deletingPathExtension
        switch nsName.pathExtension.lowercased() {
        case "lua":
            return "require(\"plugins.\(base)\")"
        case "sh", "bash", "zsh":
            return "source \"$CONFIG_DIR/plugins/\(fileName)\""
        default:
            return nil
        }
    }

    private func insertLoaderLine(for relativePath: String, root: URL) -> StoreLoaderOutcome {
        let fileName = (relativePath as NSString).lastPathComponent
        guard let line = Self.loaderLine(forFileNamed: fileName) else {
            return .manual(
                line: "No loader line is known for \(fileName).",
                reason: "The app only knows how to load .lua and shell plugin files."
            )
        }
        guard let entrypoint = entrypoint(in: root),
              let text = try? String(contentsOf: entrypoint, encoding: .utf8) else {
            return .manual(
                line: line,
                reason: "No init.lua or sketchybarrc entrypoint was found, so the line must be added by hand."
            )
        }

        let entrypointIsLua = LuaSourceDetection.isLua(text)
        let fileIsLua = (fileName as NSString).pathExtension.lowercased() == "lua"
        guard entrypointIsLua == fileIsLua else {
            return .manual(
                line: line,
                reason: "\(entrypoint.lastPathComponent) and \(fileName) use different languages, so the line was not added."
            )
        }

        do {
            try activation.insertLoaderLine(line, into: entrypoint, rootURL: root)
            return .inserted(entrypoint: entrypoint.lastPathComponent, line: line)
        } catch ActivationUpdateError.duplicateLoaderLine {
            return .alreadyActive(line: line)
        } catch {
            return .manual(line: line, reason: error.localizedDescription)
        }
    }

    private static func loaderEdit(from outcome: StoreLoaderOutcome) -> StoreLoaderEdit? {
        switch outcome {
        case .inserted(let entrypoint, let line):
            return StoreLoaderEdit(entrypointPath: entrypoint, line: line)
        case .alreadyActive, .manual:
            return nil
        }
    }

    private func entrypoint(in root: URL) -> URL? {
        ["init.lua", "sketchybarrc", ".sketchybarrc"]
            .map { root.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private struct LoaderRevertPlan {
        let url: URL
        let mark: String
        let revertedContents: String
    }

    private func loaderRevertPlan(_ edit: StoreLoaderEdit, root: URL) throws -> LoaderRevertPlan {
        let url = try validatedRelativeURL(edit.entrypointPath, root: root)
        let data = try Data(contentsOf: url)
        let mark = data.starts(with: [0xEF, 0xBB, 0xBF]) ? "\u{FEFF}" : ""
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreError.unsupportedContent
        }
        let contents = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let matches = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == edit.line.trimmingCharacters(in: .whitespaces)
        }
        guard matches.count == 1 else {
            throw StoreInstallError.loaderEditChanged(url.lastPathComponent)
        }
        lines.remove(at: matches[0])
        return LoaderRevertPlan(url: url, mark: mark, revertedContents: lines.joined(separator: "\n"))
    }

    private func backupRemoval(of url: URL, root: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            _ = try backup.backup(fileURL: url, rootURL: root)
        }
    }

    // MARK: - Path checks

    private func validatedRelativeURL(_ relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0") else {
            throw StoreInstallError.manifestTampered("an absolute or empty path")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains("..") else {
            throw StoreInstallError.manifestTampered("a path with .. components")
        }

        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard replacer.isDescendant(url, of: root) else {
            throw StoreInstallError.manifestTampered("a path outside the config folder")
        }
        return url
    }

    private func validatedProfileURL(_ absolutePath: String, configID: String) throws -> URL {
        guard absolutePath.hasPrefix("/") else {
            throw StoreInstallError.manifestTampered("a profile path that is not absolute")
        }
        let url = URL(fileURLWithPath: absolutePath).standardizedFileURL
        let profilesRoot = profiles.profilesRoot(for: configID).standardizedFileURL
        guard url.deletingLastPathComponent().pathComponents == profilesRoot.pathComponents else {
            throw StoreInstallError.manifestTampered("a profile path outside the profile folder")
        }
        return url
    }

    // MARK: - Helpers

    static func pluginFileName(from path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = (trimmed as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return name
    }

    private func uniqueProfileName(_ base: String, configID: String) -> String {
        let existing = Set(profiles.listProfiles(for: configID).map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }
}

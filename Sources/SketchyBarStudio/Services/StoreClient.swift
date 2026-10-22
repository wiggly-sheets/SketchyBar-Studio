import Foundation

enum StoreError: LocalizedError, Equatable, Sendable {
    case offline(String)
    case notFound
    case tooLarge
    case tooManyFiles
    case unsafeArchive(String)
    case licenceMissing
    case invalidEntry(String)
    case unsupportedContent

    var errorDescription: String? {
        switch self {
        case .offline(let reason):
            return "Cannot reach GitHub. Check the connection and try again. \(reason)"
        case .notFound:
            return "The file is not at the pinned ref. The entry may be out of date."
        case .tooLarge:
            return "The download is larger than the 20 MB limit."
        case .tooManyFiles:
            return "The archive holds more than 2000 files."
        case .unsafeArchive(let reason):
            return "Refusing an unsafe archive: \(reason)"
        case .licenceMissing:
            return "No verified permissive licence, so this entry cannot be installed."
        case .invalidEntry(let reason):
            return "Refusing an invalid catalogue entry: \(reason)"
        case .unsupportedContent:
            return "The file is not UTF-8 text."
        }
    }
}

/// The network layer. Tests use a fake transport, so they never hit GitHub.
protocol StoreTransport: Sendable {
    /// Returns at most `limit` bytes and throws `StoreError.tooLarge` past it.
    func fetch(_ url: URL, limit: Int) async throws -> Data
}

struct URLSessionStoreTransport: StoreTransport {
    static let timeout: TimeInterval = 30

    private let session: URLSession

    init(timeout: TimeInterval = URLSessionStoreTransport.timeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeout

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StoreError.offline("The server did not answer with HTTP.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw StoreError.notFound
            }
            guard http.expectedContentLength <= Int64(limit) else {
                throw StoreError.tooLarge
            }

            var data = Data()
            data.reserveCapacity(min(limit, 1 << 20))
            var chunk: [UInt8] = []
            chunk.reserveCapacity(1 << 16)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 1 << 16 {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    guard data.count <= limit else { throw StoreError.tooLarge }
                }
            }
            data.append(contentsOf: chunk)
            guard data.count <= limit else { throw StoreError.tooLarge }
            return data
        } catch let error as StoreError {
            throw error
        } catch let error as URLError {
            throw StoreError.offline(error.localizedDescription)
        }
    }
}

/// A fetched setup tree and the temporary folder that owns it.
struct StoreTree {
    let workingDirectory: URL
    /// The entry subtree inside `workingDirectory`.
    let contents: URL

    func remove() {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// Files of the staged subtree, relative and sorted, for the preview.
    func fileList(fileManager: FileManager = .default) throws -> [StoreStagedFile] {
        let rootComponents = contents.standardizedFileURL.pathComponents
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: contents,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return []
        }

        var files: [StoreStagedFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count else { continue }
            files.append(StoreStagedFile(
                path: components.dropFirst(rootComponents.count).joined(separator: "/"),
                size: Int64(values.fileSize ?? 0)
            ))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// One file in a staged setup.
struct StoreStagedFile: Identifiable, Equatable {
    let path: String
    let size: Int64

    var id: String { path }
}

/// A README fetched from the repository.
struct StoreReadme: Equatable {
    let text: String
    let url: URL
}

enum StoreReadmeResult: Equatable {
    case loaded(StoreReadme)
    /// The last URL that was tried, so the UI can name the source.
    case unavailable(url: String)
}

struct StoreClient {
    static let maxDownloadBytes = 20 * 1024 * 1024
    static let maxFiles = 2000
    static let maxExtractedBytes = 200 * 1024 * 1024
    static let maxReadmeBytes = 256 * 1024

    private final class ReadmeCache {
        var results: [String: StoreReadmeResult] = [:]
    }

    private let transport: any StoreTransport
    private let fileManager: FileManager
    private let downloadLimit: Int
    private let fileLimit: Int
    private let readmeCache = ReadmeCache()

    init(
        transport: any StoreTransport = URLSessionStoreTransport(),
        fileManager: FileManager = .default,
        downloadLimit: Int = StoreClient.maxDownloadBytes,
        fileLimit: Int = StoreClient.maxFiles
    ) {
        self.transport = transport
        self.fileManager = fileManager
        self.downloadLimit = downloadLimit
        self.fileLimit = fileLimit
    }

    /// Fetches the single file of a plugin. The bytes are returned as they
    /// arrived, so a byte-order mark and CRLF line endings survive the write.
    func fetchPluginFile(_ entry: StoreEntry) async throws -> Data {
        try requireInstallable(entry)
        guard entry.kind == .plugin, !entry.path.isEmpty, !entry.path.hasSuffix("/") else {
            throw StoreError.invalidEntry("A plugin needs a file path.")
        }
        guard let url = URL(string: entry.rawFileURLString) else {
            throw StoreError.invalidEntry("The raw URL is malformed.")
        }
        let data = try await transport.fetch(url, limit: downloadLimit)
        guard data.count <= downloadLimit else { throw StoreError.tooLarge }
        return data
    }

    /// Fetches an arbitrary file from the repository at the pinned ref.
    /// Used for multi-file plugins where the entry declares additional files.
    func fetchFile(_ entry: StoreEntry, path: String) async throws -> Data {
        try requireInstallable(entry)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
            throw StoreError.invalidEntry("The file path is unsafe.")
        }
        let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let urlString = "https://raw.githubusercontent.com/\(entry.repository)/\(entry.ref)/\(escapedPath)"
        guard let url = URL(string: urlString) else {
            throw StoreError.invalidEntry("The raw URL is malformed.")
        }
        let data = try await transport.fetch(url, limit: downloadLimit)
        guard data.count <= downloadLimit else { throw StoreError.tooLarge }
        return data
    }

    /// Fetches the whole repository as a tarball and returns only the entry
    /// subtree. The caller removes the working directory.
    func fetchSetupTree(_ entry: StoreEntry) async throws -> StoreTree {
        try requireInstallable(entry)
        guard entry.kind == .setup else {
            throw StoreError.invalidEntry("A tree fetch needs a setup entry.")
        }
        guard let url = URL(string: entry.archiveURLString) else {
            throw StoreError.invalidEntry("The archive URL is malformed.")
        }
        let data = try await transport.fetch(url, limit: downloadLimit)
        return try extractArchive(data, treePath: entry.path)
    }

    /// Fetches the README of an entry. The entry directory is tried first,
    /// so a setup that documents itself wins over the repository root.
    ///
    /// The result is cached per (entry id, ref). A failure is cached too, so
    /// re-selecting an entry does not hammer a dead URL.
    func readme(for entry: StoreEntry) async -> StoreReadmeResult {
        let key = "\(entry.id)@\(entry.ref)"
        if let cached = readmeCache.results[key] { return cached }

        var lastURL = entry.rawFileURLString
        for candidate in Self.readmeCandidates(for: entry) {
            guard let url = Self.rawURL(for: candidate, entry: entry) else { continue }
            lastURL = url.absoluteString
            do {
                let data = try await transport.fetch(url, limit: Self.maxReadmeBytes)
                guard data.count <= Self.maxReadmeBytes else {
                    let result = StoreReadmeResult.unavailable(url: url.absoluteString)
                    readmeCache.results[key] = result
                    return result
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    let result = StoreReadmeResult.unavailable(url: url.absoluteString)
                    readmeCache.results[key] = result
                    return result
                }
                let result = StoreReadmeResult.loaded(StoreReadme(text: text, url: url))
                readmeCache.results[key] = result
                return result
            } catch StoreError.notFound {
                continue
            } catch {
                let result = StoreReadmeResult.unavailable(url: url.absoluteString)
                readmeCache.results[key] = result
                return result
            }
        }

        let result = StoreReadmeResult.unavailable(url: lastURL)
        readmeCache.results[key] = result
        return result
    }

    /// The README paths to try, in order: the directory of the entry, then
    /// the repository root with the three common spellings.
    static func readmeCandidates(for entry: StoreEntry) -> [String] {
        var candidates: [String] = []
        let directory = readmeDirectory(for: entry)
        if !directory.isEmpty {
            candidates.append("\(directory)/README.md")
        }
        candidates.append(contentsOf: ["README.md", "readme.md", "README"])

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func readmeDirectory(for entry: StoreEntry) -> String {
        let trimmed = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        // A setup path is the tree itself; a plugin path is a file.
        if entry.kind == .setup { return trimmed }
        let directory = (trimmed as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    private static func rawURL(for path: String, entry: StoreEntry) -> URL? {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://raw.githubusercontent.com/\(entry.repository)/\(entry.ref)/\(escaped)")
    }

    /// Exposed for tests: validates and unpacks a tar.gz without the network.
    func extractArchive(_ data: Data, treePath: String) throws -> StoreTree {
        guard data.count <= downloadLimit else { throw StoreError.tooLarge }
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("SketchyBarStudio-Store-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        do {
            let archiveURL = workingDirectory.appendingPathComponent("archive.tar.gz")
            try data.write(to: archiveURL)

            // Name and type are checked before anything is written, and the
            // extracted tree is checked again afterwards. tar itself refuses
            // `..` members by default, but the app does not rely on that.
            let names = try tarNames(archiveURL, workingDirectory: workingDirectory)
            guard names.count <= fileLimit else { throw StoreError.tooManyFiles }
            for name in names where !Self.isSafeArchivePath(name) {
                throw StoreError.unsafeArchive("unsafe path \"\(name)\"")
            }
            let hasLinks = try tarListingHasLinks(archiveURL, workingDirectory: workingDirectory)
            guard !hasLinks else {
                throw StoreError.unsafeArchive("the archive contains a link")
            }

            let unpacked = workingDirectory.appendingPathComponent("unpacked", isDirectory: true)
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            _ = try runTar(["-xzf", archiveURL.path, "-C", unpacked.path], workingDirectory: workingDirectory)
            try validateExtractedTree(unpacked)

            let contents = try subtree(at: treePath, in: unpacked)
            return StoreTree(workingDirectory: workingDirectory, contents: contents)
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    static func isSafeArchivePath(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !name.contains("\\"),
              !name.contains("\0") else {
            return false
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    private func requireInstallable(_ entry: StoreEntry) throws {
        guard entry.repositoryIsWellFormed else {
            throw StoreError.invalidEntry("The repository is not owner/repo.")
        }
        guard entry.hasPinnedRef else {
            throw StoreError.invalidEntry("The ref is a branch, not a tag or commit.")
        }
        guard entry.hasSafePath else {
            throw StoreError.invalidEntry("The path is unsafe.")
        }
        guard let licence = entry.licence, licence.isPermissive, !entry.licenceURL.isEmpty else {
            throw StoreError.licenceMissing
        }
    }

    /// Takes only the requested subtree. An empty tree path keeps the single
    /// top-level folder of a GitHub tarball.
    private func subtree(at treePath: String, in unpacked: URL) throws -> URL {
        let trimmed = treePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            let children = try fileManager.contentsOfDirectory(
                at: unpacked,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            if children.count == 1,
               (try? children[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return children[0]
            }
            return unpacked
        }

        let candidate = unpacked.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.pathComponents.count > unpacked.pathComponents.count,
              candidate.pathComponents.starts(with: unpacked.pathComponents),
              fileManager.fileExists(atPath: candidate.path) else {
            throw StoreError.notFound
        }
        return candidate
    }

    /// Rejects links, counts files and caps the unpacked size.
    private func validateExtractedTree(_ root: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw StoreError.unsafeArchive("the tree cannot be read")
        }

        var fileCount = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw StoreError.unsafeArchive("link \"\(url.lastPathComponent)\"")
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            totalBytes += values.fileSize ?? 0
            guard fileCount <= fileLimit else { throw StoreError.tooManyFiles }
            guard totalBytes <= Self.maxExtractedBytes else { throw StoreError.tooLarge }
        }
    }

    private func tarNames(_ archiveURL: URL, workingDirectory: URL) throws -> [String] {
        let output = try runTar(["-tzf", archiveURL.path], workingDirectory: workingDirectory)
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The verbose listing starts with the mode, so a leading `l` or `h` is a
    /// symbolic or hard link. The mode is checked from the fixed column
    /// instead of parsing the file name, which may hold spaces.
    private func tarListingHasLinks(_ archiveURL: URL, workingDirectory: URL) throws -> Bool {
        let output = try runTar(["-tvzf", archiveURL.path], workingDirectory: workingDirectory)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            if first == "l" || first == "h" {
                return true
            }
        }
        return false
    }

    private func runTar(_ arguments: [String], workingDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderrURL = workingDirectory.appendingPathComponent("tar-stderr-\(UUID().uuidString).txt")
        _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)
        guard let stderr = FileHandle(forWritingAtPath: stderrURL.path) else {
            throw StoreError.unsafeArchive("cannot read the tar output")
        }
        defer { try? stderr.close() }
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw StoreError.unsafeArchive("tar did not start: \(error.localizedDescription)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? stderr.synchronize()
        let errorText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

        guard process.terminationStatus == 0 else {
            throw StoreError.unsafeArchive("tar failed: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

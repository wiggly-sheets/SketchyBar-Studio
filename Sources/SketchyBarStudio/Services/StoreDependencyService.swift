import Foundation
import SwiftUI

/// Whether the app may install a dependency without asking.
enum StoreDependencyPolicy: String, CaseIterable, Sendable, Identifiable {
    case never
    case ask
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .ask: return "Ask"
        case .automatic: return "Automatic"
        }
    }
}

/// Whether a dependency is available on this machine.
enum StoreDependencyPresence: Equatable, Sendable {
    /// The dependency was found.
    case present
    /// The dependency is not installed and can be checked.
    case missing
    /// brew is not on PATH, so a formula/cask dep cannot be checked.
    case unknownBecauseBrewAbsent
    /// fontconfig is not on PATH, so a font dep cannot be checked.
    case unknownBecauseFontconfigAbsent
    /// The `which`/`command -v` probe could not run for another reason.
    case unknown(String)
}

/// The result of an attempted install of a single dependency.
struct StoreDependencyInstallResult: Equatable, Sendable {
    let name: String
    let status: StoreDependencyPresence
    /// Nonzero when the install ran but did not succeed.
    let exitCode: Int32?
    let error: String?
}

/// Runs a command and waits for it. Tests provide a mock.
protocol CommandRunner: Sendable {
    /// The executable is looked up by name first.
    func run(_ command: String, _ args: [String]) async -> CommandOutcome
}

struct CommandOutcome: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs a command and streams its output.
protocol StreamingCommandRunner: Sendable {
    func runStreaming(_ command: String, _ args: [String], output: @escaping @Sendable (String) async -> Void) async -> CommandOutcome
}

/// Checks and installs the external dependencies of Store entries.
struct StoreDependencyService {
    static let shared = StoreDependencyService()

    /// Search paths for executable lookups.
    static let binSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    /// Test-only override for bin search paths.
    static var testBinSearchPaths: [String]?

    /// Test-only override for the PATH environment used by executable lookups.
    /// When nil, the process environment is used.
    static var pathEnvironment: [String: String]?

    private let runner: CommandRunner
    private let streamingRunner: StreamingCommandRunner?

    init(
        runner: CommandRunner? = nil,
        streamingRunner: StreamingCommandRunner? = nil,
        binSearchPaths: [String]? = nil
    ) {
        self.runner = runner ?? RealCommandRunner()
        self.streamingRunner = streamingRunner
        if let binSearchPaths {
            Self.testBinSearchPaths = binSearchPaths
        }
    }

    // MARK: - Presence

    /// Checks each dependency and returns one result per input, in order.
    ///
    /// The task group yields the results in completion order, so the index
    /// travels with the result. A caller reads the results side by side with
    /// its dependencies, and a reordered result would name the wrong state of
    /// the wrong dependency.
    func check(_ deps: [StoreDependency]) async -> [StoreDependencyPresence] {
        await withTaskGroup(of: (Int, StoreDependencyPresence).self) { group in
            for (index, dep) in deps.enumerated() {
                group.addTask {
                    (index, await presence(of: dep))
                }
            }
            var results = [StoreDependencyPresence?](repeating: nil, count: deps.count)
            for await (index, presence) in group {
                results[index] = presence
            }
            return results.map { $0 ?? .unknown("The dependency could not be checked.") }
        }
    }

    func presence(of dep: StoreDependency) async -> StoreDependencyPresence {
        switch dep.kind {
        case .formula, .cask:
            return await brewPresence(name: dep.name)
        case .command:
            return commandPresence(name: dep.name)
        case .font:
            return await fontPresence(name: dep.name)
        case .sketchybar:
            return commandPresence(name: "sketchybar")
        }
    }

    private func brewPresence(name: String) async -> StoreDependencyPresence {
        guard let brew = Self.binURL(for: "brew") else {
            return .unknownBecauseBrewAbsent
        }
        // `brew list <name>` reports 0 when the formula/cask is installed.
        let list = await runner.run(brew.lastPathComponent, ["list", "--versions", name])
        return list.status == 0 ? .present : .missing
    }

    private func commandPresence(name: String) -> StoreDependencyPresence {
        if Self.binURL(for: name) != nil {
            return .present
        }
        return .missing
    }

    private func fontPresence(name: String) async -> StoreDependencyPresence {
        guard let fcList = Self.binURL(for: "fc-list") else {
            return .unknownBecauseFontconfigAbsent
        }
        let outcome = await runner.run(fcList.lastPathComponent, [":spacing:lang=en", name])
        return outcome.status == 0 ? .present : .missing
    }

    static func binURL(for name: String) -> URL? {
        resolveURL(for: name) ?? fixedURL(for: name)
    }

    /// Scans PATH for an executable.
    static func resolveURL(for name: String) -> URL? {
        let path = pathEnvironment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Scans only the fixed search paths, never PATH.
    static func fixedURL(for name: String) -> URL? {
        let paths = testBinSearchPaths ?? binSearchPaths
        for dir in paths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - Install

    /// Installs one dependency using brew. The argument array is built here,
    /// never a shell string, and never with sudo or extra flags.
    func install(_ dep: StoreDependency, output: @escaping @Sendable (String) async -> Void) async -> StoreDependencyInstallResult {
        switch dep.kind {
        case .formula, .cask:
            break
        case .command, .font, .sketchybar:
            return StoreDependencyInstallResult(
                name: dep.name,
                status: .missing,
                exitCode: nil,
                error: "Dependency '\(dep.name)' is not a brew formula/cask."
            )
        }

        guard let brew = Self.binURL(for: "brew") else {
            return StoreDependencyInstallResult(
                name: dep.name,
                status: .unknownBecauseBrewAbsent,
                exitCode: nil,
                error: "Homebrew is not installed; cannot install '\(dep.name)'."
            )
        }

        var arguments: [String] = [brew.path, "install"]
        if dep.kind == .cask {
            arguments.append("--cask")
        }
        arguments.append(dep.name)

        await output("Installing \(dep.name) with: " + arguments.joined(separator: " "))
        let brewExec = brew.lastPathComponent
        let args = Array(arguments.dropFirst())
        let outcome: CommandOutcome
        if let streaming = streamingRunner {
            outcome = await streaming.runStreaming(brewExec, args, output: { @Sendable line in
                await output(line)
            })
        } else {
            // The runner reads the pipes on a background queue and waits
            // with a timeout there, so a long brew install does not block
            // the thread that started it.
            outcome = await self.runner.run(brewExec, args)
        }

        let status: StoreDependencyPresence
        if outcome.status == 0 {
            status = .present
        } else {
            status = .missing
        }
        let err = outcome.stderr.isEmpty ? nil : outcome.stderr
        return StoreDependencyInstallResult(
            name: dep.name,
            status: status,
            exitCode: outcome.status,
            error: err
        )
    }

    // MARK: - Re-check after install

    /// Re-checks a dependency after install.
    func recheck(_ dep: StoreDependency) async -> StoreDependencyPresence {
        await presence(of: dep)
    }
}

/// A thread-safe box for the output of a command.
///
/// The readers run on two queues. A command that stops and leaves a child
/// holding the pipe open must not make the caller read a value the reader
/// is still writing, and the caller must not wait forever for the drain.
private final class CommandDataBox {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    func finish(_ value: Data) {
        lock.lock()
        data = value
        finished = true
        lock.unlock()
    }

    /// The data when the reader finished, otherwise nil.
    func value() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return finished ? data : nil
    }
}

/// Default command runner that execs the system shell binaries.
struct RealCommandRunner: CommandRunner, Sendable {
    func run(_ command: String, _ args: [String]) async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.runBlocking(command, args))
            }
        }
    }

    /// Blocking variant used for the synchronous presence probes and the
    /// fallback install path when no streaming runner is injected.
    ///
    /// The pipes are drained on two background queues while the process
    /// runs. Reading them only after `waitUntilExit` deadlocks as soon as a
    /// child writes more than a pipe buffer, which `brew install` does.
    /// A command that runs past the timeout is terminated, so a stuck
    /// dependency install cannot block the app for good.
    func runBlocking(_ command: String, _ args: [String], timeout: TimeInterval = 900) -> CommandOutcome {
        let process = Process()
        if let url = StoreDependencyService.binURL(for: command) {
            process.executableURL = url
        } else {
            process.executableURL = URL(fileURLWithPath: command)
        }
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return CommandOutcome(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let group = DispatchGroup()
        let outBox = CommandDataBox()
        let errBox = CommandDataBox()
        group.enter()
        DispatchQueue.global().async {
            outBox.finish(stdout.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.finish(stderr.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // The drain is bounded: a child that the command left behind can
        // hold the pipe open, and the app must not wait for it forever.
        let drained = group.wait(timeout: .now() + 2) == .success
        let out = outBox.value() ?? Data()
        let err = errBox.value() ?? Data()

        let timedOut = Date() >= deadline && process.terminationStatus != 0
        var stderrText = String(decoding: err, as: UTF8.self)
        if timedOut {
            stderrText += "\nThe command did not finish within \(Int(timeout)) seconds."
        } else if !drained {
            stderrText += "\nThe command left a child process holding its output open."
        }
        return CommandOutcome(status: process.terminationStatus,
                              stdout: String(decoding: out, as: UTF8.self),
                              stderr: stderrText)
    }
}

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

    private let runner: CommandRunner
    private let streamingRunner: StreamingCommandRunner?

    init(
        runner: CommandRunner? = nil,
        streamingRunner: StreamingCommandRunner? = nil
    ) {
        self.runner = runner ?? RealCommandRunner()
        self.streamingRunner = streamingRunner
    }

    // MARK: - Presence

    /// Checks each dependency and returns one result per input, in order.
    func check(_ deps: [StoreDependency]) async -> [StoreDependencyPresence] {
        await withTaskGroup(of: StoreDependencyPresence.self) { group in
            for dep in deps {
                group.addTask {
                    await presence(of: dep)
                }
            }
            var results: [StoreDependencyPresence] = []
            for _ in deps {
                results.append(await group.next()!)
            }
            return results
        }
    }

    func presence(of dep: StoreDependency) async -> StoreDependencyPresence {
        switch dep.kind {
        case .formula, .cask:
            return await brewPresence(name: dep.name)
        case .command:
            return commandPresence(name: dep.name)
        case .font:
            return fontPresence(name: dep.name)
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
        let outcome = run(["/bin/sh", "-c", "command -v \(name)"])
        return outcome.status == 0 ? .present : .missing
    }

    private func fontPresence(name: String) -> StoreDependencyPresence {
        guard let fcList = Self.binURL(for: "fc-list") else {
            return .unknownBecauseFontconfigAbsent
        }
        let outcome = run([fcList.path, ":spacing:lang=en", name])
        return outcome.status == 0 ? .present : .missing
    }

    static func binURL(for name: String) -> URL? {
        for dir in binSearchPaths {
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
        } else if let runner = self.runner as? RealCommandRunner {
            outcome = runner.runBlocking(brewExec, args)
        } else {
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

    // MARK: - Process running

    /// Synchronous blocking runner used for quick presence probes.
    private func run(_ launch: [String]) -> CommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch[0])
        process.arguments = Array(launch.dropFirst())
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return CommandOutcome(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandOutcome(status: process.terminationStatus, stdout: out, stderr: err)
    }

    // MARK: - Re-check after install

    /// Re-checks a dependency after install.
    func recheck(_ dep: StoreDependency) async -> StoreDependencyPresence {
        await presence(of: dep)
    }
}

/// Default command runner that execs the system shell binaries.
struct RealCommandRunner: CommandRunner, Sendable {
    func run(_ command: String, _ args: [String]) async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
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
                    continuation.resume(returning: CommandOutcome(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: CommandOutcome(status: process.terminationStatus, stdout: out, stderr: err))
            }
        }
    }

    /// Blocking variant used for the synchronous presence probes and the
    /// fallback install path when no streaming runner is injected.
    func runBlocking(_ command: String, _ args: [String]) -> CommandOutcome {
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
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandOutcome(status: process.terminationStatus, stdout: out, stderr: err)
    }
}

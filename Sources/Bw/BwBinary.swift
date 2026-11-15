import Foundation

/// Bitwarden's command line client, wherever it is on this Mac. It is
/// Homebrew's, found and not bundled (D4).
struct BwBinary: Equatable {
    let url: URL
    let version: String

    static let homebrew = "/opt/homebrew/bin/bw"

    /// How a caller looks for the binary, given the path from settings.
    /// A test that needs there to be none passes a finder with no fallback.
    typealias Finder = (String?) -> URL?

    static let standardFinder: Finder = { find(preferred: $0) }

    /// A path from settings first, then `fallback` (Homebrew's, unless a test
    /// says otherwise), then whatever `PATH` has.
    static func find(preferred: String? = nil,
                     fallback: String? = homebrew,
                     path: String? = ProcessInfo.processInfo.environment["PATH"],
                     files: FileManager = .default) -> URL? {
        let onPath = (path ?? "").split(separator: ":").map { "\($0)/bw" }
        return ([preferred, fallback].compactMap { $0 } + onPath)
            .first { !$0.isEmpty && files.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Runs `--version`, which is node starting: over a second on this Mac.
    /// Throws `VaultError.noCLI` when there is nothing to run or it will not
    /// say what it is.
    static func locate(preferred: String? = nil, dataDirectory: URL) async throws -> BwBinary {
        guard let url = find(preferred: preferred) else { throw VaultError.noCLI }
        let said = await run(url, ["--version"], dataDirectory: dataDirectory)
        guard said.status == 0, !said.output.isEmpty else { throw VaultError.noCLI }
        return BwBinary(url: url, version: said.output)
    }

    /// One `bw` command, start to finish, for the things asked while no child
    /// is serving. Nothing secret goes in `arguments`, and there is no way
    /// here to put anything in its environment.
    static func run(_ url: URL, _ arguments: [String],
                    dataDirectory: URL) async -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = environment(dataDirectory: dataDirectory)
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                func text(_ pipe: Pipe) -> String {
                    String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continuation.resume(returning: (process.terminationStatus, text(output), text(errors)))
            }
            do { try process.run() } catch { continuation.resume(returning: (-1, "", "")) }
        }
    }

    /// What every `bw` this app starts is given, and nothing more: the
    /// environment is built, not inherited. `bw` names its own node in its
    /// first line, so `PATH` is only for what node itself may look for.
    ///
    /// Every `bw` but one is told never to ask anything, so a missing answer
    /// is a sentence and not a child sitting at a prompt. `asks` is for that
    /// one, the login, whose questions are the only way to give it a code
    /// that is not an argument (`LoginChild`).
    ///
    /// No `BW_SESSION`, for any of them (D7): another process of his can
    /// read an environment, and a child is opened by the password sent down
    /// its connection.
    static func environment(dataDirectory: URL, asks: Bool = false) -> [String: String] {
        var environment = [
            "BITWARDENCLI_APPDATA_DIR": dataDirectory.path,
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        if !asks { environment["BW_NOINTERACTION"] = "true" }
        return environment
    }
}

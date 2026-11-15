import Foundation

/// One `bw login`, from its start to its verdict, with whatever it asks in
/// between. It is the only `bw` this app lets ask anything.
///
/// Told not to ask, the CLI can be given a two-step code only as `--code`,
/// which is an argument and so is every user's to read with `ps`, and cannot
/// be given the code for a new device at all (`docs/notes.md`). Left free to
/// ask, it writes its question on standard error and reads the answer from
/// standard input, with no terminal needed. So the password is in the
/// child's environment, the code goes down a pipe, and the arguments carry
/// the email and nothing else of his.
///
/// It cannot outlive the app, the way `BwChild` cannot. At the end of its
/// input the CLI does not give up: it sits at its question for ever. So a
/// shell stands between the two, passes the lines on, and kills `bw` when
/// the app's end of the pipe closes, whether that was Cancel, a quit or a
/// crash.
final class LoginChild {
    /// What a `bw` given `--response` prints when it is done. A good login's
    /// envelope also carries a session, which is not read here.
    struct Verdict: Decodable, Equatable {
        let success: Bool
        var message: String?
    }

    private let binary: URL
    private let runDirectory: URL
    private let dataDirectory: URL
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var printed = Data()
    private var said = Data()
    private let lock = NSLock()

    private var pidFile: URL { runDirectory.appendingPathComponent("login.pid") }
    /// What the code travels through on its way to `bw`. A pipe with a name
    /// and no contents: nothing written to it is ever on the disk.
    private var answers: URL { runDirectory.appendingPathComponent("login.answers") }

    init(binary: URL, runDirectory: URL, dataDirectory: URL) {
        self.binary = binary
        self.runDirectory = runDirectory
        self.dataDirectory = dataDirectory
    }

    /// The CLI's own pid, while the shell has it written down.
    var pid: pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// `bw` reads a named pipe that the shell's reader writes to, and not a
    /// pipeline, because `wait` on one end of a pipeline waits for both: the
    /// shell would outlast `bw` by as long as the app kept its own pipe open.
    private static let script = """
    bin=$1; pidfile=$2; fifo=$3; shift 3
    exec 3<&0
    rm -f "$fifo"; mkfifo -m 600 "$fifo" || exit 127
    "$bin" "$@" <"$fifo" 3<&- &
    child=$!
    echo "$child" > "$pidfile"
    { while IFS= read -r line <&3; do printf '%s\\n' "$line"; done
      [ -s "$pidfile" ] && kill "$child"
      sleep 2
      [ -s "$pidfile" ] && kill -9 "$child"
    } >"$fifo" 2>/dev/null &
    wait "$child"
    status=$?
    rm -f "$pidfile" "$fifo"
    exit $status
    """

    /// `secrets` reach the child through its environment, under the names
    /// given, and nothing of them is in `arguments`.
    func start(arguments: [String], environment: [String: String] = [:],
               secrets: [String: SecretBytes]) throws {
        try FileManager.default.createDirectory(
            at: runDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: runDirectory.path)
        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(at: answers)

        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.script, "sh", binary.path, pidFile.path, answers.path] + arguments
        var all = BwBinary.environment(dataDirectory: dataDirectory, asks: true)
            .merging(environment) { $1 }
        for (name, secret) in secrets {
            all[name] = secret.withBytes { String(decoding: $0, as: UTF8.self) }
        }
        process.environment = all
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A line written after the shell has gone is an error to look at,
        // not a signal that ends the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Standard error is read as it comes, because a question is on it.
        // Standard output is one line at the very end, read then.
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.lock.withLock { self?.said.append(data) }
        }
        process.terminationHandler = { _ in
            // Lets go of the shell's reader, which is still sitting in `read`.
            try? input.fileHandleForWriting.close()
        }
        try process.run()
        self.process = process
        self.input = input
        self.output = output
        self.errors = errors
    }

    /// Everything the child has written on standard error, with the
    /// terminal's escapes taken out. The CLI repeats an answer after its
    /// question, so a code that was sent is in here: it is for reading a
    /// question out of and never for showing or logging.
    var heard: String {
        let text = lock.withLock { String(decoding: said, as: UTF8.self) }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "",
                                         options: .regularExpression)
    }

    /// An answer to what it asked, as a line down the pipe. The bytes are
    /// the caller's to wipe.
    func send(_ line: SecretBytes) {
        guard isRunning, let descriptor = input?.fileHandleForWriting.fileDescriptor else { return }
        line.withBytes { bytes in
            _ = write(descriptor, bytes.baseAddress, bytes.count)
        }
        _ = "\n".withCString { write(descriptor, $0, 1) }
    }

    /// What it printed, once it has exited: nil while it runs, and nil if it
    /// went without a verdict. What was read from it is overwritten here,
    /// because a good login prints a session beside its verdict.
    func verdict() -> Verdict? {
        guard let process, !process.isRunning else { return nil }
        // The shell and `bw` have both exited, so this read does not wait.
        if var rest = try? output?.fileHandleForReading.readToEnd() {
            lock.withLock { printed.append(rest) }
            rest.resetBytes(in: 0..<rest.count)
        }
        return lock.withLock {
            defer { printed.resetBytes(in: 0..<printed.count) }
            return printed.split(separator: UInt8(ascii: "\n")).reversed().lazy
                .compactMap { try? JSONDecoder().decode(Verdict.self, from: $0) }.first
        }
    }

    /// Closes the pipe, which is the shell's word to kill `bw`, and makes
    /// sure of it. Afterwards there is no process, and nothing it printed or
    /// was heard to say is kept.
    func stop() async {
        let child = pid
        try? input?.fileHandleForWriting.close()
        if let process {
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if process.isRunning {
                if let child = child ?? pid { kill(child, SIGKILL) }
                process.terminate()
                process.waitUntilExit()
            }
        }
        errors?.fileHandleForReading.readabilityHandler = nil
        lock.withLock {
            printed.resetBytes(in: 0..<printed.count)
            said.resetBytes(in: 0..<said.count)
            printed = Data()
            said = Data()
        }
        process = nil
        input = nil
        output = nil
        errors = nil
        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(at: answers)
    }
}

import Foundation

/// `ps`, run as any process of his could run it, for a test that has to see
/// a child from outside.
enum PS {
    static func run(_ arguments: [String]) throws -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = arguments
        let output = Pipe()
        ps.standardOutput = output
        try ps.run()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// One process's arguments and, after them, its environment.
    static func everything(of pid: pid_t) throws -> String {
        try run(["eww", "-o", "command=", "-p", String(pid)])
    }
}

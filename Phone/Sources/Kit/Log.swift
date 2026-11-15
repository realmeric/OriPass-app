import Foundation
import os

/// The phone's log, under the names the Mac's shared files write to. A line
/// interpolates a count, an id or a state and nothing else.
enum Log {
    static let app = Logger(subsystem: "com.meric.oripass.ios", category: "app")
    static let net = Logger(subsystem: "com.meric.oripass.ios", category: "net")
    static let fill = Logger(subsystem: "com.meric.oripass.ios", category: "fill")
    static let signposter = OSSignposter(subsystem: "com.meric.oripass.ios", category: "timing")
}

/// In a Debug build, lines appended to trace.log in the App Group, which a
/// test on the simulator reads; the extension's log lines did not reach
/// `log show` there. A line carries a state, a count or an error's name.
enum Trace {
    static func note(_ line: @autoclosure () -> String) {
        #if DEBUG
        guard let url = Shared.container?.appending(path: "trace.log") else { return }
        let text = "\(Date().timeIntervalSince1970) \(line())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        #endif
    }
}

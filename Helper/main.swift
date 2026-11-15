import AppKit
import Security

// Orion starts this once for each `sendNativeMessage`, with the extension's
// origin as the first argument: one message in, one answer out, and gone
// (`docs/notes.md`, "The host for Orion"). It is the only thing of the app's
// that Orion can start, so it holds nothing of the vault and reads no file.
//
// `BridgeHostTests` runs a copy of this binary in which `orion` and `app` say
// something else, the same length, so each of those stays one whole string.

/// Who may have started it. Anything of his can run this file, and
/// `allowed_origins` is not held to, so the door is told this and the
/// extension's origin and not what the message says.
let orion = #"anchor apple generic and certificate leaf[subject.OU] = "TFVG979488" and identifier "com.kagi.kagimacOS""#
let browser = "com.kagi.kagimacOS"
let app = "com.meric.oripass"

struct Hello: Encodable {
    var v = BridgeWire.version
    var type = "hello"
    let origin: String?
    let browser: String
}

/// By its pid, which is all a child has of its parent: it cannot be anyone
/// else's while `getppid` still names it, since a parent that goes leaves
/// this process to launchd.
func isStartedByOrion() -> Bool {
    let parent = getppid()
    var code: SecCode?
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(orion as CFString, [], &requirement) == errSecSuccess, let requirement,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: parent] as CFDictionary, [], &code) == errSecSuccess,
          let code
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess && getppid() == parent
}

/// The answer, overwritten behind it as `BridgeConnection` overwrites its own,
/// and the end of this process.
func say(_ answer: Data) -> Never {
    var answer = answer
    try? BridgeWire.write(answer, to: STDOUT_FILENO)
    answer.resetBytes(in: 0..<answer.count)
    exit(0)
}

/// With no door to ask, or one that closed without a word.
func sayThereIsNoDoor() -> Never {
    let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty
    say(Data(#"{"v":\#(BridgeWire.version),"type":"\#(isRunning ? "locked" : "closed")"}"#.utf8))
}

// A pipe that has gone is an error from `write`, and not a signal that ends
// this before it says anything.
signal(SIGPIPE, SIG_IGN)
// Whatever it is blocked on: the browser, the door, or a finger.
alarm(30)

guard isStartedByOrion(),
      var message = try? BridgeWire.read(from: STDIN_FILENO), BridgeWire.kind(of: message) != nil
else { exit(1) }

// Orion gone, there is nobody to answer. What it may still send is not read.
DispatchQueue.global().async {
    var rest: UInt8 = 0
    while read(STDIN_FILENO, &rest, 1) > 0 {}
    exit(1)
}

let home = FileManager.default.homeDirectoryForCurrentUser
let origin = CommandLine.arguments.dropFirst().first
let hello = try? JSONEncoder().encode(Hello(origin: origin, browser: browser))
let answer = hello.flatMap { BridgeWire.pass(message, saying: $0, to: BridgeWire.door(under: home)) }
message.resetBytes(in: 0..<message.count)
guard let answer else { sayThereIsNoDoor() }
say(answer)

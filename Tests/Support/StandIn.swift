import Foundation
import XCTest
@testable import OriPass

/// A directory holding a stand-in `bw` (`standin-bw.py`) and what it is told
/// to do, removed when the test is over.
final class StandIn {
    let directory: URL
    let binary: URL
    let run: URL
    let data: URL
    let log: URL

    /// `options` are the keys `standin-bw.py` documents. `changed` names
    /// fixtures to answer with other bytes than the ones in
    /// `Tests/Fixtures/`, by file name without its extension.
    init(_ options: [String: Any] = [:], changed: [String: Data] = [:]) throws {
        directory = URL(fileURLWithPath: "/tmp/op-\(UUID().uuidString.prefix(8))")
        binary = directory.appendingPathComponent("bw")
        run = directory.appendingPathComponent("run")
        data = directory.appendingPathComponent("data")
        log = directory.appendingPathComponent("requests.log")
        let bundle = Bundle(for: StandIn.self)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try XCTUnwrap(bundle.url(forResource: "standin-bw", withExtension: "py")), to: binary
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var config = options
        config["fixtures"] = bundle.resourceURL?.path
        if !changed.isEmpty {
            let own = directory.appendingPathComponent("fixtures")
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: try XCTUnwrap(bundle.resourceURL),
                                                                   includingPropertiesForKeys: nil)
            where url.pathExtension == "json" || url.pathExtension == "txt" {
                try FileManager.default.copyItem(at: url, to: own.appendingPathComponent(url.lastPathComponent))
            }
            for (name, data) in changed { try data.write(to: own.appendingPathComponent(name + ".json")) }
            config["fixtures"] = own.path
        }
        config["log"] = log.path
        self.config = config
        try write()
    }

    private var config: [String: Any]

    private func write() throws {
        try JSONSerialization.data(withJSONObject: config)
            .write(to: directory.appendingPathComponent("standin.json"))
    }

    /// Other options from the next start on: every child reads them as it
    /// starts, and a child is started for every unlock.
    func change(_ options: [String: Any]) throws {
        config.merge(options) { $1 }
        try write()
    }

    func child() -> BwChild {
        BwChild(binary: binary, runDirectory: run, dataDirectory: data)
    }

    /// A file beside the stand-in that changes what it does from the next
    /// request on: `mute`, `hang-up` or `short`.
    func leave(_ marker: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(marker).path, contents: nil)
    }

    /// What the run directory holds: `child.pid` while a child lives, and
    /// nothing otherwise.
    var left: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: run.path)) ?? []
    }

    /// Every socket file anywhere under the stand-in's directory. There is
    /// never one (D5).
    var sockets: [String] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (files?.allObjects as? [URL] ?? []).filter {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeSocket
        }.map(\.path)
    }

    /// One line per request the stand-in was sent: `METHOD PATH BODY`.
    var requests: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// What each start of the stand-in was given, a start a row.
    var arguments: [[String]] {
        let log = directory.appendingPathComponent("arguments.log")
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// Polls `condition` for up to `seconds`. For the tests that wait on another
/// process, which no expectation can be fulfilled from.
func eventually(within seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

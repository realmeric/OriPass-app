import Foundation
import XCTest
@testable import OriPass

/// What `bw serve` answers, from `Tests/Fixtures/`. Every value in them is
/// invented.
enum Fixture {
    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard let url = Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            XCTFail("no fixture named \(name)", file: file, line: line)
            return Data()
        }
        return data
    }

    /// A fixture that is not JSON: the icon server's answer for a site it
    /// has never heard of, as `curl` saved it.
    static func bytes(_ name: String, _ ext: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard let url = Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            XCTFail("no fixture named \(name).\(ext)", file: file, line: line)
            return Data()
        }
        return data
    }

    /// A fixture as a dictionary, changed by `change` and put back into
    /// bytes, for the test that wants `bw` to have answered differently.
    static func changed(_ name: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONValue(data: data(name))
    }

    /// The `data.data` array of a list fixture.
    static func items(_ name: String = "list-items") throws -> [Item] {
        try (json(name)["data"]?["data"]?.array ?? []).map(Item.init(json:))
    }

    static func item(named name: String) throws -> Item {
        try XCTUnwrap(items().first { $0.name == name })
    }
}

private final class FixtureBundle {}

import Foundation

/// JSON as it came, kept so that what this app does not model goes back
/// untouched. An item is written as the object it was read from with a few
/// keys replaced (`Item.patched`), and this is that object.
///
/// It holds whatever the item holds, secrets included, so it describes itself
/// as nothing.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return Int(value) }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// This value with the one at `path` replaced. A step through something
    /// that is not an object, a `null` where a payload will go, makes one.
    func setting(_ path: [String], to value: JSONValue) -> JSONValue {
        guard let key = path.first else { return value }
        var members = object ?? [:]
        members[key] = (members[key] ?? .null).setting(Array(path.dropFirst()), to: value)
        return .object(members)
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Keys sorted, so the same object is the same bytes every time.
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: Redacted {
    var redactedLabel: String { "JSONValue" }
}

extension JSONValue {
    init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
}

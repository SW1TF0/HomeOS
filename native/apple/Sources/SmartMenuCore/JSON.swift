import Foundation

/// Loosely typed JSON, for devices and saved homes where any field can be missing.
public enum JSON: Equatable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }
    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }

    public func text(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public subscript(key: String) -> JSON? { if case .object(let o) = self { return o[key] } else { return nil } }
    public subscript(index: Int) -> JSON? { if case .array(let a) = self, index >= 0, index < a.count { return a[index] } else { return nil } }

    public var object: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }
    public var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var int: Int? { double.map { Int($0.rounded()) } }
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }
    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return JSON.format(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }
    public var isNumber: Bool { if case .number = self { return true } else { return false } }
    /// The value as text, like a device would print it.
    public var description: String { string ?? (self == .null ? "null" : text()) }

    static func format(_ n: Double) -> String { n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n) }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSON {
    init(_ v: String?) { self = v.map { .string($0) } ?? .null }
    init(_ v: Double?) { self = v.map { .number($0) } ?? .null }
    init(_ v: Int?) { self = v.map { .number(Double($0)) } ?? .null }
    init(_ v: Bool?) { self = v.map { .bool($0) } ?? .null }
}

/// An object without its null values.
public func obj(_ pairs: [String: JSON?]) -> JSON {
    var o: [String: JSON] = [:]
    for (k, v) in pairs { if let v, v != .null { o[k] = v } }
    return .object(o)
}

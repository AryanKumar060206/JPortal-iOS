import Foundation

/// a loose json value. the portal mixes types freely (ids as numbers or strings,
/// null for blanks), so every accessor coerces instead of failing, the same as
/// the android client's lenient, coerce-input-values json settings.
enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(parsing data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: any)
    }

    init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    init(any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    /// back to foundation types for JSONSerialization. whole numbers go out as integers,
    /// ids the portal sent as numbers must come back looking the same
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 { return NSNumber(value: Int64(d)) }
            return NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .sortedKeys])
    }

    func text() -> String {
        (try? data()).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }

    /// the value as text, numbers without a trailing .0, null as nil
    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 { return String(Int64(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// text with blank as the default, the shape almost every portal field wants
    var str: String { string ?? "" }

    var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var dbl: Double { double ?? 0 }

    var int: Int? {
        guard let d = double, d.isFinite, abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }

    var long: Int64? {
        guard let d = double, d.isFinite, abs(d) < 9.0e15 else { return nil }
        return Int64(d)
    }

    var array: [JSON] {
        if case .array(let a) = self { return a }
        return []
    }

    var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }
}

extension JSON: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

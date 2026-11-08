import Foundation

/// Schlanker, Sendable-fähiger JSON-Wert für JMAP-Anfragen und -Antworten.
enum JSONWert: Codable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
               ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    case null
    case bool(Bool)
    case zahl(Double)
    case text(String)
    case liste([JSONWert])
    case objekt([String: JSONWert])

    init(stringLiteral value: String) { self = .text(value) }
    init(integerLiteral value: Int) { self = .zahl(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONWert...) { self = .liste(elements) }
    init(dictionaryLiteral elements: (String, JSONWert)...) {
        self = .objekt(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    init(nilLiteral: ()) { self = .null }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .zahl(d) }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else if let a = try? c.decode([JSONWert].self) { self = .liste(a) }
        else { self = .objekt(try c.decode([String: JSONWert].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .zahl(let d):
            if d == d.rounded(), abs(d) < 1e15 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .text(let s): try c.encode(s)
        case .liste(let a): try c.encode(a)
        case .objekt(let o): try c.encode(o)
        }
    }

    subscript(_ key: String) -> JSONWert {
        if case .objekt(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(_ i: Int) -> JSONWert {
        if case .liste(let a) = self, i >= 0, i < a.count { return a[i] }
        return .null
    }

    var string: String? { if case .text(let s) = self { return s }; return nil }
    var int: Int? { if case .zahl(let d) = self { return Int(d) }; return nil }
    var boolWert: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONWert] { if case .liste(let a) = self { return a }; return [] }
    var dict: [String: JSONWert] { if case .objekt(let o) = self { return o }; return [:] }
    var istNull: Bool { if case .null = self { return true }; return false }

    static func strings(_ s: [String]) -> JSONWert { .liste(s.map { .text($0) }) }
}

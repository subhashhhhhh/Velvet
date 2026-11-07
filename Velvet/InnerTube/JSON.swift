import Foundation

/// A small, Sendable JSON value used for InnerTube's huge, loosely-shaped responses.
///
/// YouTube's response layout shifts constantly, so parsers navigate it with
/// forgiving subscripts (missing keys yield `.null`) and recursive searches
/// rather than strict `Decodable` models.
nonisolated enum JSON: Sendable, Equatable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: Decoding / encoding

    init(data: Data) throws {
        self = JSON(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any: Any) {
        switch any {
        case let d as [String: Any]: self = .object(d.mapValues(JSON.init(any:)))
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .object(let o): o.mapValues(\.anyValue)
        case .array(let a): a.map(\.anyValue)
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        }
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue, options: [])
    }

    // MARK: Navigation

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSON] { if case .array(let a) = self { a } else { [] } }
    var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }
    var isNull: Bool { self == .null }

    /// Reads YouTube's text containers: `{simpleText}`, `{runs:[{text}]}`, `{content}` or a bare string.
    var text: String? {
        if let s = string { return s }
        if let s = self["simpleText"].string { return s }
        if let s = self["content"].string { return s }
        let runs = self["runs"].array
        if !runs.isEmpty {
            let joined = runs.compactMap { $0["text"].string }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    // MARK: Recursive search

    /// Every value stored under `key`, anywhere in the tree (depth-first, document order).
    /// Does not descend into matched values.
    func all(_ key: String) -> [JSON] {
        var out: [JSON] = []
        collect(key, into: &out)
        return out
    }

    /// First value stored under `key`, anywhere in the tree.
    func first(_ key: String) -> JSON? {
        switch self {
        case .object(let o):
            if let v = o[key] { return v }
            for v in o.values { if let hit = v.first(key) { return hit } }
            return nil
        case .array(let a):
            for v in a { if let hit = v.first(key) { return hit } }
            return nil
        default:
            return nil
        }
    }

    private func collect(_ key: String, into out: inout [JSON]) {
        switch self {
        case .object(let o):
            if let v = o[key] { out.append(v); return }
            // Dictionary order is unstable; sort keys so results keep a stable order.
            for k in o.keys.sorted() { o[k]!.collect(key, into: &out) }
        case .array(let a):
            for v in a { v.collect(key, into: &out) }
        default:
            break
        }
    }
}

// MARK: Literals (for building request bodies)

nonisolated extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
}

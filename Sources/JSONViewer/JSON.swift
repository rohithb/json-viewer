import Foundation

/// Order-preserving JSON value. Numbers keep their literal text so `1` stays `1` and big ints survive.
indirect enum JSON: Equatable {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func == (a: JSON, b: JSON) -> Bool { a.compact == b.compact }

    var isContainer: Bool {
        switch self { case .object, .array: true; default: false }
    }

    var childCount: Int {
        switch self { case .object(let o): o.count; case .array(let a): a.count; default: 0 }
    }

    var children: [(PathComponent, JSON)] {
        switch self {
        case .object(let o): o.map { (.key($0.0), $0.1) }
        case .array(let a): a.enumerated().map { (.index($0.offset), $0.element) }
        default: []
        }
    }

    func child(_ c: PathComponent) -> JSON? {
        switch (self, c) {
        case (.object(let o), .key(let k)): o.last(where: { $0.0 == k })?.1
        case (.array(let a), .index(let i)): a.indices.contains(i) ? a[i] : nil
        default: nil
        }
    }

    func value(at path: [PathComponent]) -> JSON? {
        var v: JSON? = self
        for c in path { v = v?.child(c) }
        return v
    }

    // MARK: Serialisation

    var compact: String { var s = ""; write(&s, indent: nil, level: 0); return s }
    var pretty: String { var s = ""; write(&s, indent: "  ", level: 0); return s }

    /// Primitive as shown in the tree/text views (strings quoted).
    var primitiveText: String {
        switch self {
        case .string(let s): JSON.quote(s)
        case .number(let n): n
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        default: compact
        }
    }

    private func write(_ out: inout String, indent: String?, level: Int) {
        let nl = indent == nil ? "" : "\n"
        let pad = { (l: Int) in indent.map { String(repeating: $0, count: l) } ?? "" }
        switch self {
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (i, (k, v)) in o.enumerated() {
                out += pad(level + 1) + JSON.quote(k) + (indent == nil ? ":" : ": ")
                v.write(&out, indent: indent, level: level + 1)
                out += (i < o.count - 1 ? "," : "") + nl
            }
            out += pad(level) + "}"
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, v) in a.enumerated() {
                out += pad(level + 1)
                v.write(&out, indent: indent, level: level + 1)
                out += (i < a.count - 1 ? "," : "") + nl
            }
            out += pad(level) + "]"
        default:
            out += primitiveText
        }
    }

    static func quote(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            case _ where u.value < 0x20: r += String(format: "\\u%04x", u.value)
            default: r.unicodeScalars.append(u)
            }
        }
        return r + "\""
    }
}

enum PathComponent: Hashable {
    case key(String)
    case index(Int)

    var label: String {
        switch self { case .key(let k): k; case .index(let i): "[\(i)]" }
    }
}

/// `.orders[0]["first name"]`
func jqPath(_ path: [PathComponent]) -> String {
    if path.isEmpty { return "." }
    return path.map { c -> String in
        switch c {
        case .index(let i): return "[\(i)]"
        case .key(let k):
            return k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil ? ".\(k)" : "[\(JSON.quote(k))]"
        }
    }.joined()
}

// MARK: - Parser

struct JSONParseError: Error, Equatable {
    var message: String
    var line: Int
    var column: Int
}

struct JSONParser {
    private let b: [UInt8]
    private var i = 0

    static func parse(_ text: String) throws -> JSON {
        var p = JSONParser(b: Array(text.utf8))
        p.ws()
        let v = try p.value(depth: 0)
        p.ws()
        if p.i < p.b.count { throw p.fail("Unexpected token \(p.tokenHere) after JSON") }
        return v
    }

    private init(b: [UInt8]) { self.b = b }

    private var tokenHere: String {
        guard i < b.count else { return "end of input" }
        return String(decoding: [b[i]], as: UTF8.self)
    }

    private func fail(_ msg: String) -> JSONParseError {
        var line = 1, col = 1
        for k in 0..<min(i, b.count) {
            if b[k] == 0x0A { line += 1; col = 1 } else if b[k] & 0xC0 != 0x80 { col += 1 }
        }
        return JSONParseError(message: msg, line: line, column: col)
    }

    private mutating func ws() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private mutating func expect(_ lit: String) throws {
        for c in lit.utf8 {
            guard i < b.count, b[i] == c else { throw fail("Unexpected token \(tokenHere)") }
            i += 1
        }
    }

    private mutating func value(depth: Int) throws -> JSON {
        guard depth < 512 else { throw fail("Nesting too deep") }
        guard i < b.count else { throw fail("Unexpected end of input") }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1; ws()
            var o: [(String, JSON)] = []
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                ws()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("Expected property name, found \(tokenHere)") }
                let k = try string()
                ws()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("Expected ':' after property name, found \(tokenHere)") }
                i += 1; ws()
                o.append((k, try value(depth: depth + 1)))
                ws()
                guard i < b.count else { throw fail("Unexpected end of input") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw fail("Expected ',' or '}', found \(tokenHere)")
            }
        case UInt8(ascii: "["):
            i += 1; ws()
            var a: [JSON] = []
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                ws()
                a.append(try value(depth: depth + 1))
                ws()
                guard i < b.count else { throw fail("Unexpected end of input") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                throw fail("Expected ',' or ']', found \(tokenHere)")
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
        default: throw fail("Unexpected token \(tokenHere)")
        }
    }

    private mutating func number() throws -> JSON {
        let start = i
        let digits = { (p: inout JSONParser) -> Int in
            let s = p.i
            while p.i < p.b.count, p.b[p.i] >= 0x30, p.b[p.i] <= 0x39 { p.i += 1 }
            return p.i - s
        }
        if b[i] == UInt8(ascii: "-") { i += 1 }
        if i < b.count, b[i] == UInt8(ascii: "0") { i += 1 } else if digits(&self) == 0 { throw fail("Invalid number") }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            if digits(&self) == 0 { throw fail("Invalid number") }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            if digits(&self) == 0 { throw fail("Invalid number") }
        }
        return .number(String(decoding: b[start..<i], as: UTF8.self))
    }

    private mutating func string() throws -> String {
        i += 1 // opening quote
        var bytes: [UInt8] = []
        while true {
            guard i < b.count else { throw fail("Unterminated string") }
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw fail("Bad control character in string") }
            if c != UInt8(ascii: "\\") { bytes.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { throw fail("Unterminated string") }
            let e = b[i]; i += 1
            switch e {
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "/"): bytes.append(0x2F)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "u"):
                var cp = try hex4()
                if (0xD800..<0xDC00).contains(cp), i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                    i += 2
                    let lo = try hex4()
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                }
                bytes.append(contentsOf: Array(String(Unicode.Scalar(cp).map(Character.init) ?? "\u{FFFD}").utf8))
            default: i -= 1; throw fail("Bad escape in string")
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw fail("Bad \\u escape in string")
        }
        i += 4
        return v
    }
}

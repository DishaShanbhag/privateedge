import Foundation

/// A JSON value with Python json.loads semantics: ints and floats stay distinct, a repeated key
/// keeps its LAST value (Foundation keeps the first), NaN and Infinity are accepted.
public indirect enum JV: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case float(Double)
    case str(String)
    case arr([JV])
    case obj(JObj)

    public var asString: String? { if case .str(let s) = self { return s }; return nil }
}

public struct JObj: Equatable {
    public private(set) var keys: [String] = []
    public private(set) var dict: [String: JV] = [:]
    public init() {}
    public init(_ pairs: [(String, JV)]) { for (k, v) in pairs { self[k] = v } }
    public subscript(_ k: String) -> JV? {
        get { dict[k] }
        set {
            if dict[k] == nil, newValue != nil { keys.append(k) }
            if newValue == nil { keys.removeAll { $0 == k } }
            dict[k] = newValue
        }
    }
}

public enum JSONError: Error { case bad(String) }

public func parseJSON(_ text: String) throws -> JV {
    var p = JSONParser(Array(text.unicodeScalars))
    p.ws()
    let v = try p.value()
    p.ws()
    if p.i != p.s.count { throw JSONError.bad("extra data") }
    return v
}

struct JSONParser {
    let s: [Unicode.Scalar]
    var i = 0
    init(_ s: [Unicode.Scalar]) { self.s = s }

    mutating func ws() { while i < s.count, [" ", "\t", "\n", "\r"].contains(s[i]) { i += 1 } }
    func peek() -> Unicode.Scalar? { i < s.count ? s[i] : nil }
    mutating func lit(_ w: String) -> Bool {
        let ws = Array(w.unicodeScalars)
        guard i + ws.count <= s.count, Array(s[i..<i + ws.count]) == ws else { return false }
        i += ws.count
        return true
    }

    mutating func value() throws -> JV {
        guard let c = peek() else { throw JSONError.bad("eof") }
        switch c {
        case "{": return try object()
        case "[": return try array()
        case "\"": return .str(try string())
        default:
            if lit("null") { return .null }
            if lit("true") { return .bool(true) }
            if lit("false") { return .bool(false) }
            if lit("NaN") { return .float(.nan) }
            if lit("Infinity") { return .float(.infinity) }
            if lit("-Infinity") { return .float(-.infinity) }
            return try number()
        }
    }

    mutating func object() throws -> JV {
        i += 1
        var o = JObj()
        ws()
        if peek() == "}" { i += 1; return .obj(o) }
        while true {
            ws()
            guard peek() == "\"" else { throw JSONError.bad("key") }
            let k = try string()
            ws()
            guard peek() == ":" else { throw JSONError.bad(":") }
            i += 1
            ws()
            o[k] = try value()
            ws()
            if peek() == "," { i += 1; continue }
            if peek() == "}" { i += 1; return .obj(o) }
            throw JSONError.bad("object")
        }
    }

    mutating func array() throws -> JV {
        i += 1
        var a: [JV] = []
        ws()
        if peek() == "]" { i += 1; return .arr(a) }
        while true {
            ws()
            a.append(try value())
            ws()
            if peek() == "," { i += 1; continue }
            if peek() == "]" { i += 1; return .arr(a) }
            throw JSONError.bad("array")
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else {
            throw JSONError.bad("\\u")
        }
        i += 4
        return v
    }

    mutating func string() throws -> String {
        i += 1
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek() else { throw JSONError.bad("unterminated string") }
            i += 1
            if c == "\"" { return String(out) }
            if c.value < 0x20 { throw JSONError.bad("control character") }
            if c != "\\" { out.append(c); continue }
            guard let e = peek() else { throw JSONError.bad("escape") }
            i += 1
            switch e {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{c}")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                var v = try hex4()
                if (0xD800...0xDBFF).contains(v), lit("\\u") {
                    let save = i
                    let lo = try hex4()
                    if (0xDC00...0xDFFF).contains(lo) { v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00) } else { i = save - 2 }
                }
                out.append(Unicode.Scalar(v) ?? "\u{FFFD}")  // Python keeps a lone surrogate; Swift cannot
            default: throw JSONError.bad("escape")
            }
        }
    }

    mutating func number() throws -> JV {
        let start = i
        if peek() == "-" { i += 1 }
        guard let d = peek(), ("0"..."9").contains(d) else { throw JSONError.bad("value") }
        if d == "0" { i += 1 } else { while let c = peek(), ("0"..."9").contains(c) { i += 1 } }
        var isFloat = false
        if peek() == ".", i + 1 < s.count, ("0"..."9").contains(s[i + 1]) {
            isFloat = true
            i += 1
            while let c = peek(), ("0"..."9").contains(c) { i += 1 }
        }
        if let e = peek(), e == "e" || e == "E" {
            var j = i + 1
            if j < s.count, s[j] == "+" || s[j] == "-" { j += 1 }
            if j < s.count, ("0"..."9").contains(s[j]) {
                isFloat = true
                i = j
                while let c = peek(), ("0"..."9").contains(c) { i += 1 }
            }
        }
        let txt = String(String.UnicodeScalarView(s[start..<i]))
        if !isFloat, let n = Int(txt) { return .int(n) }
        return .float(Double(txt)!)
    }
}

/// Serialize for the predictions file (keys in insertion order, like Python's json.dumps).
public func dumpJSON(_ v: JV) -> String {
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let n): return String(n)
    case .float(let d): return d.isFinite ? "\(d)" : (d.isNaN ? "NaN" : (d > 0 ? "Infinity" : "-Infinity"))
    case .str(let s):
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 || c.value > 0x7E {  // ensure_ascii, like json.dumps
                    if c.value > 0xFFFF {
                        let v = c.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", c.value)
                    }
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    case .arr(let a): return "[" + a.map(dumpJSON).joined(separator: ", ") + "]"
    case .obj(let o): return "{" + o.keys.map { dumpJSON(.str($0)) + ": " + dumpJSON(o[$0]!) }.joined(separator: ", ") + "}"
    }
}

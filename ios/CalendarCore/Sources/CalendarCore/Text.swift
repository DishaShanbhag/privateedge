import Foundation

// Small helpers so the port can follow the Python line by line. All string positions are UTF-16
// offsets (NSString), which is what NSRegularExpression and NSDataDetector use.

final class RX {
    let re: NSRegularExpression
    init(_ pattern: String, ci: Bool = false) {
        // A bad pattern is a programming error, caught by the parity run.
        re = try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }
    func all(_ s: String) -> [RM] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { RM($0, ns) }
    }
    func first(_ s: String) -> RM? {
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { RM($0, ns) }
    }
}

struct RM {
    let r: NSTextCheckingResult
    let ns: NSString
    init(_ r: NSTextCheckingResult, _ ns: NSString) { self.r = r; self.ns = ns }
    var start: Int { r.range.location }
    var end: Int { r.range.location + r.range.length }
    var text: String { ns.substring(with: r.range) }
    /// Python m.group(i); nil when the group did not take part. 0 is the whole match.
    func g(_ i: Int) -> String? {
        let x = r.range(at: i)
        return x.location == NSNotFound ? nil : ns.substring(with: x)
    }
    func g(_ name: String) -> String? {
        let x = r.range(withName: name)
        return x.location == NSNotFound ? nil : ns.substring(with: x)
    }
}

extension String {
    var u16: Int { (self as NSString).length }
    /// Python s[a:b] on UTF-16 offsets, clamped like Python slices.
    func sl(_ a: Int, _ b: Int) -> String {
        let n = u16, lo = max(0, min(a, n)), hi = max(lo, min(b, n))
        return (self as NSString).substring(with: NSRange(location: lo, length: hi - lo))
    }
    /// Python `sub in s` (code-unit match; the empty string is in every string).
    func pyContains(_ sub: String) -> Bool {
        sub.isEmpty || (self as NSString).range(of: sub, options: .literal).location != NSNotFound
    }
    /// Python s.find(sub) on UTF-16 offsets.
    func pyFind(_ sub: String) -> Int {
        if sub.isEmpty { return 0 }
        let r = (self as NSString).range(of: sub, options: .literal)
        return r.location == NSNotFound ? -1 : r.location
    }
    /// Python s.strip(chars) / s.rstrip(chars); with no chars, Python's whitespace set.
    func pyStrip(_ chars: String? = nil) -> String { pyLStrip(chars).pyRStrip(chars) }
    func pyRStrip(_ chars: String? = nil) -> String {
        var sc = Array(unicodeScalars)
        while let last = sc.last, Self.isStripped(last, chars) { sc.removeLast() }
        return String(String.UnicodeScalarView(sc))
    }
    func pyLStrip(_ chars: String? = nil) -> String {
        var sc = Array(unicodeScalars)[...]
        while let f = sc.first, Self.isStripped(f, chars) { sc = sc.dropFirst() }
        return String(String.UnicodeScalarView(Array(sc)))
    }
    private static func isStripped(_ c: Unicode.Scalar, _ chars: String?) -> Bool {
        if let chars { return chars.unicodeScalars.contains(c) }
        return c.properties.isWhitespace || (0x1C...0x1F).contains(c.value)
    }
    /// Python len(s): code points.
    var pyLen: Int { unicodeScalars.count }
    /// Python str.lower() (close enough: Foundation's full lowercase mapping).
    var pyLower: String { lowercased() }
}

/// Python's floor modulo.
@inline(__always) func pmod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

import Foundation

/// A calendar date with no time zone (Python `datetime.date`). Years 1-9999, like Python.
public struct Day: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let y: Int, m: Int, d: Int

    public init?(_ y: Int, _ m: Int, _ d: Int) {
        guard (1...9999).contains(y), (1...12).contains(m), d >= 1, d <= Day.daysIn(y, m) else { return nil }
        self.y = y; self.m = m; self.d = d
    }
    init(ordinal z: Int) {
        let (y, m, d) = civil(z)
        self.y = y; self.m = m; self.d = d
    }
    static func daysIn(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
    /// Days since 1970-01-01.
    public var ordinal: Int { daysFromCivil(y, m, d) }
    /// Python date.weekday(): Monday 0 ... Sunday 6.
    public var weekday: Int { pmod(ordinal + 3, 7) }
    public func adding(_ n: Int) -> Day { Day(ordinal: ordinal + n) }
    public var description: String { String(format: "%04d-%02d-%02d", y, m, d) }
    public static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }

    /// "YYYY-MM-DD" only.
    public static func parse(_ s: String) -> Day? {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              p.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return Day(y, m, d)
    }
}

// Howard Hinnant's civil-date algorithms (proleptic Gregorian, like Python).
func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

func civil(_ z0: Int) -> (Int, Int, Int) {
    let z = z0 + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
}

/// Hour and minute of a wall-clock time (Python `datetime.time`, seconds always 0 here).
public struct HM: Hashable, Sendable {
    public let h: Int, m: Int
    public init(h: Int, m: Int) { self.h = h; self.m = m }
}

/// A date-time with a fixed UTC offset (Python aware `datetime`).
public struct ZDT: Hashable, Sendable {
    public let day: Day
    public let h: Int, mi: Int, s: Int, micro: Int
    public let offset: Int  // seconds east of UTC

    /// Seconds since the epoch (exact; microseconds kept separately).
    public var epoch: Int { day.ordinal * 86400 + h * 3600 + mi * 60 + s - offset }

    /// Python datetime.isoformat() (the shape Pydantic and the resolver write).
    public var iso: String {
        var out = String(format: "%@T%02d:%02d:%02d", day.description, h, mi, s)
        if micro != 0 { out += String(format: ".%06d", micro) }
        let sign = offset < 0 ? "-" : "+", a = abs(offset)
        out += String(format: "%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
        if a % 60 != 0 { out += String(format: ":%02d", a % 60) }
        return out
    }

    /// The instant `epoch` seen in `tz`.
    public static func at(epoch: Int, in tz: TimeZone) -> ZDT {
        let off = tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epoch)))
        let wall = epoch + off
        let dayN = Int((Double(wall) / 86400).rounded(.down))
        let sec = wall - dayN * 86400
        return ZDT(day: Day(ordinal: dayN), h: sec / 3600, mi: (sec % 3600) / 60, s: sec % 60, micro: 0, offset: off)
    }

    /// Python datetime.fromisoformat for the shapes used here, and Pydantic's AwareDatetime input:
    /// YYYY-MM-DD[T t _ space]HH:MM[:SS[.ffffff]] then Z, z, +HH:MM or +HHMM (Pydantic rejects
    /// "+05"). Aware only.
    public static func parse(_ s: String) -> ZDT? {
        let rx = RX(#"^(\d{4}-\d{2}-\d{2})[Tt_ ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,6}))?)?(?:([Zz])|([+-])(\d{2}):?(\d{2}))$"#)
        guard s.allSatisfy(\.isASCII), let m = rx.first(s), let day = Day.parse(m.g(1)!) else { return nil }
        let h = Int(m.g(2)!)!, mi = Int(m.g(3)!)!, sec = Int(m.g(4) ?? "0")!
        guard h < 24, mi < 60, sec < 60 else { return nil }
        let frac = m.g(5).map { Int($0.padding(toLength: 6, withPad: "0", startingAt: 0))! } ?? 0
        var off = 0
        if m.g(6) == nil {
            guard let sign = m.g(7) else { return nil }
            let oh = Int(m.g(8)!)!, om = Int(m.g(9) ?? "0")!
            guard oh < 24, om < 60 else { return nil }
            off = (oh * 3600 + om * 60) * (sign == "-" ? -1 : 1)
        }
        return ZDT(day: day, h: h, mi: mi, s: sec, micro: frac, offset: off)
    }
}

/// Exact match on instant and on written offset (eval/score_calendar.py same_time).
public func sameTime(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b, !a.isEmpty, !b.isEmpty, let x = ZDT.parse(a), let y = ZDT.parse(b) else { return false }
    return x.epoch == y.epoch && x.micro == y.micro && x.offset == y.offset
}

func zone(_ tz: String) -> TimeZone {
    guard let z = TimeZone(identifier: tz) else { fatalError("unknown time zone \(tz)") }
    return z
}

/// The reference time as a local date-time in `tz` (resolver.local_ref).
public func localRef(_ referenceTime: String, _ tz: String) -> ZDT {
    guard let r = ZDT.parse(referenceTime) else { fatalError("bad reference_time \(referenceTime)") }
    return ZDT.at(epoch: r.epoch, in: zone(tz))
}

/// Local date + time in `tz` -> aware date-time (resolver.combine). A time skipped by DST
/// -> clarify(invalid_time); a repeated time (fall back) takes the first occurrence (fold=0).
public func combine(_ d: Day, _ t: HM, _ tz: String) -> Parse<ZDT> {
    let z = zone(tz)
    let wall = d.ordinal * 86400 + t.h * 3600 + t.m * 60
    var offs = Set<Int>()
    for probe in [wall - 86400, wall, wall + 86400] {
        offs.insert(z.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(probe))))
    }
    let valid = offs.map { wall - $0 }.filter {
        z.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval($0))) == wall - $0
    }
    guard let first = valid.min() else { return Parse(clarify: "invalid_time") }
    return Parse(value: ZDT.at(epoch: first, in: z))
}

import Foundation

/// First whole minute in `(from, from + minutes]` that matches a 5-field cron expression, or nil.
/// Fields: minute hour day-of-month month day-of-week; each supports `*`, `n`, `a-b`, lists and `/step`.
public func nextCronFire(_ expr: String, within minutes: Int, from: Date, calendar: Calendar = .current) -> Date? {
    let f = expr.split(separator: " ")
    guard f.count == 5,
          let minute = cronField(f[0], 0...59), let hour = cronField(f[1], 0...23),
          let dom = cronField(f[2], 1...31), let month = cronField(f[3], 1...12),
          let dowRaw = cronField(f[4], 0...7),
          let start = calendar.dateInterval(of: .minute, for: from)?.start else { return nil }
    let dow = Set(dowRaw.map { $0 % 7 })
    let eitherDay = f[2] != "*" && f[4] != "*"  // standard cron: both restricted means either may match
    for i in 1...max(minutes, 1) {
        guard let t = calendar.date(byAdding: .minute, value: i, to: start) else { return nil }
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
        guard let mi = c.minute, let h = c.hour, let d = c.day, let mo = c.month, let wd = c.weekday else { return nil }
        let domOK = dom.contains(d), dowOK = dow.contains(wd - 1)
        if minute.contains(mi), hour.contains(h), month.contains(mo), eitherDay ? (domOK || dowOK) : (domOK && dowOK) {
            return t
        }
    }
    return nil
}

private func cronField(_ field: Substring, _ range: ClosedRange<Int>) -> Set<Int>? {
    var values = Set<Int>()
    for part in field.split(separator: ",", omittingEmptySubsequences: false) {
        let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        var step = 1
        if pieces.count == 2 {
            guard let s = Int(pieces[1]), s > 0 else { return nil }
            step = s
        }
        let span: ClosedRange<Int>
        if pieces[0] == "*" {
            span = range
        } else {
            let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...2).contains(bounds.count), let lo = bounds.first ?? nil, let hi = bounds.last ?? nil,
                  lo <= hi, range.contains(lo), range.contains(hi) else { return nil }
            span = lo...hi
        }
        values.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
    }
    return values
}

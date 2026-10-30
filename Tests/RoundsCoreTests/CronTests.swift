import Foundation
import Testing
@testable import RoundsCore

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

@Test func everyFiveMinutes() {
    #expect(nextCronFire("*/5 * * * *", within: 15, from: at(2026, 10, 26, 10, 2), calendar: utc) == at(2026, 10, 26, 10, 5))
}

@Test func weekdaysOnlySkipsSaturday() {
    #expect(nextCronFire("0 9 * * 1-5", within: 15, from: at(2026, 10, 31, 8, 50), calendar: utc) == nil)
    #expect(nextCronFire("0 9 * * 1-5", within: 15, from: at(2026, 10, 30, 8, 50), calendar: utc) == at(2026, 10, 30, 9, 0))
}

@Test func crossesMidnight() {
    #expect(nextCronFire("5 0 * * *", within: 15, from: at(2026, 10, 26, 23, 55), calendar: utc) == at(2026, 10, 27, 0, 5))
}

@Test func oneShotDate() {
    #expect(nextCronFire("30 14 26 10 *", within: 15, from: at(2026, 10, 26, 14, 20), calendar: utc) == at(2026, 10, 26, 14, 30))
    #expect(nextCronFire("30 14 26 10 *", within: 15, from: at(2026, 10, 26, 14, 30), calendar: utc) == nil)
}

@Test func listsRangesStepsAndSunday() {
    #expect(nextCronFire("10-20/5,59 * * * 0", within: 15, from: at(2026, 11, 1, 10, 50), calendar: utc) == at(2026, 11, 1, 10, 59))
    #expect(nextCronFire("0 11 * * 7", within: 15, from: at(2026, 11, 1, 10, 50), calendar: utc) == at(2026, 11, 1, 11, 0))
}

@Test(arguments: ["x", "* * * *", "*/0 * * * *", "61 * * * *", "1-a * * * *"])
func invalidExpressionGivesNil(expr: String) {
    #expect(nextCronFire(expr, within: 15, from: at(2026, 10, 26, 10, 0), calendar: utc) == nil)
}

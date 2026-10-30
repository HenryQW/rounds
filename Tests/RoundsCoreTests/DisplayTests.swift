import Testing
@testable import RoundsCore

private let laptop = DisplayInfo(id: "A", name: "Built-in Retina Display", builtIn: true)
private let lg = DisplayInfo(id: "B", name: "LG UltraFine", builtIn: false)
private let dell = DisplayInfo(id: "C", name: "DELL U2723QE", builtIn: false)

@Test func uncheckedDisplaysGetNoPill() {
    #expect(pillDisplays([laptop, lg, dell], off: []) == [laptop, lg, dell])
    #expect(pillDisplays([laptop, lg, dell], off: ["A", "C"]) == [lg])
    // A display connected later (not in `off`) shows the pill.
    #expect(pillDisplays([laptop, lg], off: ["C"]) == [laptop, lg])
}

/// The pill is the only way into the app, so with every connected display unchecked it stays on the built-in one.
@Test func someDisplayAlwaysKeepsThePill() {
    #expect(pillDisplays([laptop, lg], off: ["A", "B"]) == [laptop])
    #expect(pillDisplays([lg, dell], off: ["B", "C"]) == [lg])
    #expect(pillDisplays([], off: []) == [])
}

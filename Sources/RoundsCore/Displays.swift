/// One connected display, as Settings lists it (spec 5.7). `id` is the display's UUID, stable across restarts.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let builtIn: Bool

    public init(id: String, name: String, builtIn: Bool) {
        (self.id, self.name, self.builtIn) = (id, name, builtIn)
    }
}

/// The displays that show a pill: every one the user did not uncheck, so a display connected later shows it too.
/// With every connected display unchecked, the built-in display (else the first) keeps the pill, since the pill is
/// the only way into the app.
public func pillDisplays(_ displays: [DisplayInfo], off: Set<String>) -> [DisplayInfo] {
    let shown = displays.filter { !off.contains($0.id) }
    if !shown.isEmpty { return shown }
    return (displays.first(where: \.builtIn) ?? displays.first).map { [$0] } ?? []
}

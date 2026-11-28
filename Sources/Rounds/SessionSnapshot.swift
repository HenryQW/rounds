import RoundsCore

/// Rows from one source and the classifier inputs from the same refresh.
struct SessionSnapshot: Equatable {
    let rows: [SessionRow]
    private let inputs: [String: StateInput]

    init<S: Sequence>(_ sessions: S, makeEntry: (S.Element) -> (SessionRow, StateInput?)) {
        var rows: [SessionRow] = []
        var inputs: [String: StateInput] = [:]
        rows.reserveCapacity(sessions.underestimatedCount)
        for session in sessions {
            let (row, input) = makeEntry(session)
            rows.append(row)
            inputs[row.id] = input
        }
        self.rows = rows
        self.inputs = inputs
    }

    init() {
        rows = []
        inputs = [:]
    }

    func input(for row: SessionRow) -> StateInput? {
        inputs[row.id]
    }

    // Observation tracks changes to the listed rows. Diagnostics read the latest inputs on demand.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows
    }
}

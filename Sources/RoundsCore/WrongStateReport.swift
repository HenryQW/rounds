import Foundation

/// A wrong-state report (Report Wrong State…, spec 2.10): the classifier input, redacted, so a test can run the
/// classifier again; the state Rounds showed, the explanation, and the state the user says is correct. It holds no
/// title, prompt, reply, branch, token or path; of a folder, only its last component.
public struct WrongStateReport: Codable, Sendable {
    public var version = 1
    public let savedAt: Date
    public let shown: SessionState
    /// Nil: the user is not sure.
    public let correct: SessionState?
    public let explanation: StateExplanation
    public let input: Input

    public init(input: StateInput, shown: SessionState, explanation: StateExplanation, correct: SessionState?, savedAt: Date) {
        (self.input, self.shown, self.explanation, self.correct, self.savedAt) = (Input(input), shown, explanation, correct, savedAt)
    }

    /// The classifier input again, for a replay; nil when the report is not valid.
    public var stateInput: StateInput? { input.stateInput }

    /// Dates as Unix milliseconds, as in the desktop session files, so the session part decodes as one.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// One field per source; only the report's source is set.
    public struct Input: Codable, Sendable {
        public var claude: Claude?
        public var codex: Codex?
        public var pi: Pi?
        public var herdr: Herdr?

        public struct Claude: Codable, Sendable {
            public let session: Session
            public let hookLines: [HookLineRecord]
            /// `LastMessage.code`; nil when the tail was not read.
            public let tail: String?
            public let claudeRunning: Bool
            public let claudeLaunchedAt: Date?
            public let now: Date
        }

        /// The desktop session fields the classifier reads, with the desktop file's keys, so the replay decodes it as a
        /// `DesktopSession`. Free text (the wrap-up question, the summary's step) is only "redacted" or absent.
        public struct Session: Codable, Sendable {
            let sessionId: String
            let cliSessionId: String
            /// The folder's last component.
            let cwd: String
            /// Required by the desktop format; always empty.
            let title: String
            let isArchived: Bool
            let lastActivityAt: Date
            let lastTurnEdgeAt: Date?
            let lastAssistantUuid: String?
            let turnWrapUp: WrapUp?
            let postTurnSummary: Summary?
            let errorAt: Date?
            let interruptedAwaitingPerson: Bool
            let sideSessionWakesSinceUserMessage: Int
            let lastFocusedAt: Date?
            /// "redacted" for a remote session, else absent.
            let sshConfig: String?

            struct WrapUp: Codable { let needsUser: String? }
            struct Summary: Codable {
                let status_category: String
                let needs_action: String
                let summarizes_uuid: String
            }
        }

        /// A hook line without the task descriptions.
        public struct HookLineRecord: Codable, Sendable {
            let at: Date
            let event: String
            /// The tool name, notification type or error kind.
            let detail: String
            let backgroundTasks: Int?
            let taskTypes: [String]
            let cronSchedules: [String]
        }

        public struct Turn: Codable, Sendable {
            let kind: String
            let at: Date
        }

        public struct Codex: Codable, Sendable {
            let id: String
            let folder: String
            let updatedAt: Date
            let hookLines: [HookLineRecord]
            let turn: Turn?
            let live: Bool
        }

        public struct Pi: Codable, Sendable {
            let id: String
            let folder: String
            let updatedAt: Date
            let turn: Turn?
            /// The extension's state word and its time; the detail and the session file are left out.
            let state: String?
            let stateAt: Date?
            let live: Bool
            let aged: Bool
        }

        public struct Herdr: Codable, Sendable {
            let status: String
            let since: Date
        }

        init(_ input: StateInput) {
            switch input {
            case .claude(let c):
                let s = c.session
                let session = Session(
                    sessionId: s.id, cliSessionId: s.cliSessionId, cwd: folderName(s.cwd), title: "", isArchived: s.isArchived,
                    lastActivityAt: s.lastActivityAt, lastTurnEdgeAt: s.lastTurnEdgeAt, lastAssistantUuid: s.lastAssistantUuid,
                    turnWrapUp: s.hasWrapUp ? Session.WrapUp(needsUser: s.wrapUpNeedsUser.map { _ in "redacted" }) : nil,
                    postTurnSummary: s.summary.map {
                        Session.Summary(status_category: $0.category, needs_action: $0.needsAction.isEmpty ? "" : "redacted", summarizes_uuid: $0.summarizesUuid)
                    },
                    errorAt: s.errorAt, interruptedAwaitingPerson: s.interruptedAwaitingPerson,
                    sideSessionWakesSinceUserMessage: s.sideSessionWakes, lastFocusedAt: s.lastFocusedAt, sshConfig: s.isRemote ? "redacted" : nil)
                claude = Claude(session: session, hookLines: records(c.hook), tail: c.tail?.code, claudeRunning: c.claudeRunning,
                                claudeLaunchedAt: c.claudeLaunchedAt, now: c.now)
            case .codex(let thread, let hook, let turn, let live):
                codex = Codex(id: thread.id, folder: folderName(thread.cwd), updatedAt: thread.updatedAt, hookLines: records(hook),
                              turn: turn.map { Turn(kind: $0.kind.rawValue, at: $0.at) }, live: live)
            case .pi(let session, let state, let live, let aged):
                pi = Pi(id: session.id, folder: folderName(session.cwd), updatedAt: session.updatedAt,
                        turn: session.turn.map { Turn(kind: $0.kind.rawValue, at: $0.at) }, state: state?.state, stateAt: state?.at,
                        live: live, aged: aged)
            case .herdr(let status, let since):
                herdr = Herdr(status: status, since: since)
            }
        }

        var stateInput: StateInput? {
            if let c = claude {
                guard let json = try? WrongStateReport.encoder().encode(c.session), let session = try? DesktopSession(json: json) else { return nil }
                return .claude(ClassifierInput(session: session, hook: hookState(c.hookLines), tail: c.tail.flatMap(LastMessage.init(code:)),
                                               claudeRunning: c.claudeRunning, claudeLaunchedAt: c.claudeLaunchedAt, now: c.now))
            }
            if let c = codex {
                let thread = CodexThread(id: c.id, title: "", cwd: c.folder, branch: nil, updatedAt: c.updatedAt, rolloutPath: "")
                let turn = c.turn.flatMap { t in CodexTurn.Kind(rawValue: t.kind).map { CodexTurn(kind: $0, at: t.at) } }
                return .codex(thread, hook: hookState(c.hookLines), turn: turn, live: c.live)
            }
            if let p = pi {
                let turn = p.turn.flatMap { t in PiTurn.Kind(rawValue: t.kind).map { PiTurn(kind: $0, at: t.at) } }
                let session = PiSession(id: p.id, path: "", cwd: p.folder, parentPath: nil, title: "", updatedAt: p.updatedAt, turn: turn)
                let state = p.state.flatMap { s in p.stateAt.map { PiState(at: $0, state: s, detail: "", pid: 0, sessionPath: "") } }
                return .pi(session, state: state, live: p.live, aged: p.aged)
            }
            return herdr.map { .herdr(status: $0.status, since: $0.since) }
        }
    }
}

private func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

/// The classifier reads the newest line only (`HookState.last`), so that is the one line a report keeps.
private func records(_ hook: HookState?) -> [WrongStateReport.Input.HookLineRecord] {
    hook.map { [$0.last] }?.map { l in
        WrongStateReport.Input.HookLineRecord(at: l.at, event: l.event, detail: l.detail, backgroundTasks: l.backgroundTasks,
                                              taskTypes: l.tasks.map(\.type), cronSchedules: l.cronSchedules)
    } ?? []
}

private func hookState(_ lines: [WrongStateReport.Input.HookLineRecord]) -> HookState? {
    lines.max { $0.at < $1.at }.map { l in
        HookState(last: HookLine(at: l.at, event: l.event, detail: l.detail, backgroundTasks: l.backgroundTasks, cronSchedules: l.cronSchedules,
                                 tasks: l.taskTypes.map { BackgroundTask(type: $0, description: "") }))
    }
}

/// `~/Library/Application Support/Rounds/reports`, next to the hook state folder.
public func reportsDirectory() -> URL {
    hookStateDirectory().deletingLastPathComponent().appending(path: "reports")
}

/// Writes the report to `dir/wrong-state-<yyyyMMdd-HHmmss>.json`, readable by the user only (mode 0600), and returns
/// the file. A second report in the same second gets "-2", "-3" and so on.
public func save(_ report: WrongStateReport, in dir: URL) throws -> URL {
    let data = try WrongStateReport.encoder().encode(report)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = report.savedAt.formatted(Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian)))
    for n in 1... {
        let url = dir.appending(path: "wrong-state-\(stamp)\(n == 1 ? "" : "-\(n)").json")
        // O_EXCL: never replace a report; the mode is set as the file is made.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            if errno == EEXIST { continue }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        return url
    }
    fatalError("unreachable")
}

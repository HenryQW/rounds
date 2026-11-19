import Darwin
import Foundation

/// The one way the Bouncer Window talks to the Bouncer: Pi RPC now, pi-durable later, demo data with `--demo`.
public protocol BouncerAdapter: Sendable {
    var events: AsyncStream<BouncerEvent> { get }
    func start() async throws
    func send(_ text: String) async throws
    /// Stops the current reply.
    func stop() async
    func answer(_ questionID: String, _ answer: BouncerAnswer) async throws
    func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws  // PiRPCBouncer: BouncerError.notAvailable
    func checkAgain() async
    /// "provider/id", or nil for the model that Pi started with.
    func setModel(_ id: String?) async throws
    func shutdown() async
}

/// `pi --mode rpc` as a child process. It starts and stops only its own child.
public actor PiRPCBouncer: BouncerAdapter {
    public nonisolated let events: AsyncStream<BouncerEvent>
    private let output: AsyncStream<BouncerEvent>.Continuation
    private let executable: URL, arguments: [String], folder: URL
    private var process: Process?
    private var input: FileHandle?
    private var framer = PiRPCFramer()
    private var stderrTail = Data()
    private var running = false, shuttingDown = false
    private var lastID = 0, stateID: String?, messagesID: String?
    private var pending: [String: CheckedContinuation<PiRPCRecord, Error>] = [:]
    private var questions: [String: BouncerQuestion] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var startModel: String?

    public init(executable: URL, arguments: [String], folder: URL) {
        (events, output) = AsyncStream.makeStream(of: BouncerEvent.self)
        (self.executable, self.arguments, self.folder) = (executable, arguments, folder)
    }

    /// Starts Pi, then asks for its state (`.started`) and its messages. Throws only when Pi does not start; a later
    /// exit is an `.exited` event. After an exit, a new call starts Pi again.
    public func start() async throws {
        guard !running, !shuttingDown else { return }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, stderr)
        // A write after Pi exits gets EPIPE, not a SIGPIPE that stops Rounds.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let (ended, end) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { end.yield($0.terminationStatus); end.finish() }
        try process.run()
        let out = Self.chunks(stdout.fileHandleForReading), err = Self.chunks(stderr.fileHandleForReading)
        (self.process, input, running, framer, stderrTail) = (process, stdin.fileHandleForWriting, true, PiRPCFramer(), Data())
        // One task reads each pipe in order; the exit is handled after both pipes end, so `.exited` comes last.
        Task {
            let errors = Task { for await chunk in err { self.received(error: chunk) } }
            for await chunk in out { self.received(chunk) }
            await errors.value
            var status: Int32 = -1
            for await code in ended { status = code }
            self.exited(status)
        }
        let state = nextID(), messages = nextID()
        (stateID, messagesID) = (state, messages)
        try? write(.getState(id: state))
        try? write(.getMessages(id: messages))
    }

    /// Pi rejects a prompt while a reply runs; the window sends none then (`BouncerThread.replying`).
    public func send(_ text: String) async throws {
        let id = nextID()
        try check(await request(.prompt(id: id, message: text), id: id))
    }

    /// Pi answers `abort` when the session is idle.
    public func stop() async {
        let id = nextID()
        guard let record = try? await request(.abort(id: id), id: id), case .response(_, _, true, _) = record else { return }
        output.yield(.item(.stopped(id: "stopped-\(id)")))
    }

    public func answer(_ questionID: String, _ answer: BouncerAnswer) async throws {
        guard let question = questions[questionID] else { throw BouncerError.unknownQuestion }
        try write(.uiResponse(question, answer))
        forget(questionID)
    }

    public func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws { throw BouncerError.notAvailable }

    /// Pi has nothing to check again; the approval gate rechecks in slice 04.
    public func checkAgain() async {}

    public func setModel(_ id: String?) async throws {
        guard let model = id ?? startModel, let slash = model.firstIndex(of: "/") else { return }
        let request = nextID()
        try check(await self.request(.setModel(id: request, provider: String(model[..<slash]),
                                                model: String(model[model.index(after: slash)...])), id: request))
    }

    /// Closes stdin, then sends SIGTERM if Pi still runs after 5 s.
    public func shutdown() async {
        shuttingDown = true
        try? input?.close()
        input = nil
        if !(await waitForExit(seconds: 5)) {
            process?.terminate()
            _ = await waitForExit(seconds: 5)
        }
        output.finish()
    }

    private func waitForExit(seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while running, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return !running
    }

    private func nextID() -> String {
        lastID += 1
        return "rounds-\(lastID)"
    }

    private func write(_ command: PiRPCCommand) throws {
        guard running, let input else { throw BouncerError.notRunning }
        do { try input.write(contentsOf: encodePiRPC(command)) } catch { throw BouncerError.notRunning }
    }

    private func request(_ command: PiRPCCommand, id: String) async throws -> PiRPCRecord {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try write(command)
                pending[id] = continuation
            } catch { continuation.resume(throwing: error) }
        }
    }

    private func check(_ record: PiRPCRecord) throws {
        if case .response(_, _, false, let error) = record { throw BouncerError.rejected(error ?? "") }
    }

    private func received(_ chunk: Data) {
        for line in framer.feed(chunk) { handle(decodePiRPC(line)) }
    }

    private func handle(_ record: PiRPCRecord) {
        switch record {
        case .response(let id?, _, let success, let error):
            if let continuation = pending.removeValue(forKey: id) { continuation.resume(returning: record) }
            else if !success, id == stateID || id == messagesID { output.yield(.failed(error ?? "Pi did not answer.")) }
        case .state(let id, let file, let model) where id != nil && id == stateID:
            startModel = model
            output.yield(.started(sessionFile: file, isNew: !arguments.contains("--session")))
        case .messages(let id, let items) where id != nil && id == messagesID:
            for item in items { output.yield(.item(item)) }
        case .event(let event): output.yield(event)
        case .uiRequest(let question, let timeout):
            questions[question.id] = question
            output.yield(.item(.question(question)))
            // Pi resolves a dialog with a timeout itself and says nothing; the card then stops counting.
            if let timeout {
                timeouts[question.id] = Task { [id = question.id] in
                    try? await Task.sleep(for: .milliseconds(timeout))
                    if !Task.isCancelled { self.expired(id) }
                }
            }
        case .response, .state, .messages, .ignored, .malformed: break
        }
    }

    private func expired(_ questionID: String) {
        guard questions[questionID] != nil else { return }
        forget(questionID)
        output.yield(.closed(questionID: questionID))
    }

    private func forget(_ questionID: String) {
        questions[questionID] = nil
        timeouts.removeValue(forKey: questionID)?.cancel()
    }

    private func received(error chunk: Data) {
        stderrTail = Data((stderrTail + chunk).suffix(4096))
    }

    private func exited(_ status: Int32) {
        (running, process, input) = (false, nil, nil)
        for continuation in pending.values { continuation.resume(throwing: BouncerError.notRunning) }
        pending = [:]
        for id in Array(questions.keys) { forget(id) }
        guard !shuttingDown else { return }
        let lines = String(decoding: stderrTail, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(5)
        output.yield(.exited(lines.isEmpty ? "Pi stopped with exit code \(status)." : lines.joined(separator: "\n")))
    }

    /// The data of a pipe as it comes, in order, until end of file.
    private static func chunks(_ handle: FileHandle) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else { continuation.yield(data) }
        }
        return stream
    }
}

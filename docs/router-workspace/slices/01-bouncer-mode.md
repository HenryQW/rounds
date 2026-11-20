# 01 Bouncer mode

## Goal

Rounds gets a Bouncer mode. The pill is the Bouncer, and a click on it opens the Bouncer Window, where the user talks to the Bouncer.

## State

Details, 2026-11-19. No open owner decision. Sub-steps 01a (RoundsCore) and 01b (mode switch, pill, Bouncer Window) are built. Next step: build sub-step 01c.

## Depends

None. Organization rules and workspace setup are built ([overview](../overview.md#built-so-far)).

## Builds

- The mode switch.
- The pill as the Bouncer: it stays still while nothing waits, and bounces only when the Bouncer asks for an approval or an answer.
- The Bouncer Window: the conversation, results and decisions. Approvals show as inline cards that host code draws, never as model text.
- The window talks to the Bouncer through one adapter. Demo data until dispatch exists ([slice 03](03-dispatch-and-results.md)). The `pi --mode rpc` adapter is temporary: [slice 02](02-node-harness-host.md) replaces it (decision "Bouncer on pi-durable").

## Decided

- Decision "Bouncer mode in Rounds" ([decisions.md](../decisions.md)).
- Decision "Bouncer Window has a task sidebar" ([decisions.md](../decisions.md)). Patterns to take from the Claude desktop app Code tab ([its docs](https://code.claude.com/docs/en/desktop)): **+ New** at the top of the sidebar; group and sort on hover; archive from a hover menu; a details panel of cards beside the chat; one view only (owner, 2026-11-19), where each agent report shows its tool steps collapsed and a click opens them; a control row under the prompt box; a stop button; Cmd+N and Ctrl+Tab; reports from other agents labeled with their task and a link back.
- Decision "Approvals as inline cards" ([decisions.md](../decisions.md)).
- Decisions "No shared theme in version one" and "Set Up row in the Bouncer Window" ([decisions.md](../decisions.md)).
- Design reference: [bouncer-mockups.html](../bouncer-mockups.html), the mockup the owner picked (layout C, inline approval cards). It covers the task, approval, error and accessibility states that the attention review asked for.
- Rounds still watches all sessions. The session list stays on the global shortcut.
- *Default* (agent, 2026-11-19, reversible): the Bouncer agent sees nothing of the sessions that it does not manage. On user request it reads metadata only (title, state, project, organization), never transcript text, and never sends them input. Organization rules decide what goes to the model.
- *Default* (agent, 2026-11-19, reversible): the mode switch is a toggle "Bouncer mode" on Settings > General, off by default, saved as `bouncerMode`.
- *Default* (agent, 2026-11-19, reversible): in Bouncer mode only a click opens the Bouncer Window; a hover does nothing. The Bouncer Window is a normal titled, resizable window, not a slide from the edge, because it holds a long conversation.
- *Default* (agent, 2026-11-19, reversible): the pill's right-click menu adds Open Session List in Bouncer mode, because the global shortcut can be empty and is then the only other path to the session list.
- *Default* (agent, 2026-11-19, reversible): the pill bounces while any approval or question waits, seen or not. It reuses the ringing layers of the existing pill (`RingingTab`), so the render server runs the motion.
- *Default* (agent, 2026-11-19, reversible): without `--demo`, the window uses the Pi adapter for the Bouncer conversation and shows no tasks, because tasks come with dispatch. With `--demo`, the demo adapter feeds the whole window, tasks and approval cards included.
- *Default* (agent, 2026-11-19, reversible): the Pi adapter never makes an approval card. A Pi dialog shows as a question card only, whatever its title says. Approval cards come only from host code (demo now, the gate in [slice 04](04-approval-and-publication.md)).
- *Default* (agent, 2026-11-19, reversible): the Bouncer Session runs with its working folder at the workspace folder and its session files in `~/Library/Application Support/Rounds/bouncer-sessions` (`--session-dir`). So the session list does not show the Bouncer as an ordinary pi row.
- *Default* (agent, 2026-11-19, reversible): the control row in slice 01 has the Model menu and the send or stop button. The menu lists Default and the models that `get_available_models` returns; the mockup's Fast and Deep are placeholders. The attach button and the Target repository and Organization menus come with dispatch ([slice 03](03-dispatch-and-results.md)), where they have an effect.
- *Default* (agent, 2026-11-19, reversible): New Task (Cmd+N) selects the Bouncer row and puts the focus in an empty prompt box until dispatch exists.
- *Default* (agent, 2026-11-19, reversible): slice 01 sends to Pi only the text that the user types. It gives the Bouncer no tool that reads other sessions.
- *Default* (reviewer, 2026-11-19, reversible): the Bouncer Session starts with no tools: `--no-tools --no-extensions --no-mcp --no-skills --no-prompt-templates`. A plain `pi --mode rpc` gets shell and edit tools and every installed extension, which breaks "It does not edit repositories" ([overview](../overview.md)) and decision "Option 3: container-use for all agent work". Context files stay on, so the workspace `AGENTS.md` loads. Slice 03 adds the dispatch and result tools with explicit `-e` paths.
- *Default* (agent, 2026-11-19, reversible): the slice merges in three sub-steps (see Files). One pull request would mix a process protocol, a new window and demo cards, which need different reviews.

## Open

None.

## Read first, in full

- [AGENTS.md](../../../AGENTS.md), [DESIGN.md](../../../DESIGN.md), [GLOSSARY.md](../../../GLOSSARY.md).
- [spec.md](../../spec.md) 2.7 (pi sessions), 4 (Components), 5.1, 5.4, 5.7 and 7.1 (Demo mode).
- [CONTEXT.md](../CONTEXT.md) (Bouncer Session, Approval Request) and [decisions.md](../decisions.md).
- [bouncer-mockups.html](../bouncer-mockups.html): the pill, the window and the keyboard handler at the end of the script.
- Pi 1.5.2 package docs, in the installed package's `docs/` folder: `rpc.md`, `rpc-commands.md` (`prompt`, `abort`, `get_state`, `get_messages`, `set_model`, `get_available_models`), `rpc-extension-ui.md`, `json.md`. `pi --help` is the authority for flags.
- Code: [EdgeDrawer.swift](../../../Sources/Rounds/EdgeDrawer.swift) (`EdgeDrawer.apply`, `observe`, `open(display:)`, `EdgePill`, `RingingTab`), [AppModel.swift](../../../Sources/Rounds/AppModel.swift) (`regroup`, the pill counts), [RoundsApp.swift](../../../Sources/Rounds/RoundsApp.swift), [Demo.swift](../../../Sources/Rounds/Demo.swift), [WorkspaceSettings.swift](../../../Sources/Rounds/WorkspaceSettings.swift), [SettingsView.swift](../../../Sources/Rounds/SettingsView.swift) (`SettingsPage`, `SettingsState.page`), [Pi.swift](../../../Sources/RoundsCore/Pi.swift), [Workspace.swift](../../../Sources/RoundsCore/Workspace.swift).

## Files

| Sub-step | File | New or changed | What |
|---|---|---|---|
| 01a | `Sources/RoundsCore/Bouncer.swift` | New | The thread model, events, waiting count, archive rule, setup steps, other waits |
| 01a | `Sources/RoundsCore/PiRPC.swift` | New | JSON lines framing, record decoding, command encoding, launch arguments |
| 01a | `Sources/RoundsCore/BouncerAdapter.swift` | New | `BouncerAdapter` and `PiRPCBouncer` (the child process) |
| 01a | `Tests/RoundsCoreTests/BouncerTests.swift`, `PiRPCTests.swift` | New | Tests below |
| 01b | `Sources/Rounds/BouncerModel.swift` | New | `@MainActor @Observable` owner of the adapter and the thread |
| 01b | `Sources/Rounds/BouncerWindow.swift` | New | Window controller, sidebar, conversation, composer, host note, keys |
| 01b | `Sources/Rounds/BouncerDemo.swift` | New | `DemoBouncer`, the scripted thread for `--demo` |
| 01b | `Sources/Rounds/EdgeDrawer.swift` | Changed | Pill look, size, click and menu in Bouncer mode |
| 01b | `Sources/Rounds/SettingsView.swift` | Changed | General toggle; Keys cheatsheet rows |
| 01b | `Sources/Rounds/RoundsApp.swift`, `Demo.swift` | Changed | Start the model; a `--demo-scene bouncer` scene |
| 01b | `docs/spec.md`, `GLOSSARY.md`, `docs/router-workspace/CONTEXT.md` | Changed | See "Docs in the same commit" |
| 01c | `Sources/Rounds/BouncerCards.swift` | New | Approval card, result card, report steps, fact banner |
| 01c | `Sources/Rounds/BouncerDetails.swift` | New | Details panel: Changes, Checks, Agents, Environment |
| 01c | `Sources/Rounds/BouncerWindow.swift`, `BouncerDemo.swift`, `docs/spec.md` | Changed | Task rows, group and sort, archive; demo tasks |

Each sub-step merges alone. 01a adds code that nothing calls yet, as `TaskGraph` did. 01b gives a working mode with a real Pi conversation and no tasks. 01c adds the task views that only demo data fills until slices 03 and 04.

## Contracts

```swift
// RoundsCore/Bouncer.swift
public enum BouncerError: Error, Equatable { case reasonRequired, notAvailable, notRunning, unknownQuestion, rejected(String), noAnswer }
public enum BouncerTaskState: String, Sendable { case working, needsInput, failed, finished, stopped }
public struct BouncerTask: Identifiable, Equatable, Sendable {
    public let id: String; public var title: String; public var repository: String?; public var organization: String?
    public var state: BouncerTaskState; public var updatedAt: Date; public var archived: Bool
    public var canArchive: Bool { state == .finished || state == .stopped }
}
public enum BouncerAnswer: Equatable, Sendable { case option(Int), text(String), confirmed(Bool), dismissed }
public struct BouncerQuestion: Identifiable, Equatable, Sendable {
    public let id: String; public let taskID: String?; public let title: String; public let options: [String]
    public let recommended: Int?; public let takesText: Bool; public let confirms: Bool  // a Pi confirm: Pi wants `confirmed`, not option text
    public var answer: BouncerAnswer?; public var closedByPi: Bool
}
public enum ApprovalDecision: Equatable, Sendable { case approved, rejected(reason: String) }
public struct ApprovalCard: Identifiable, Equatable, Sendable {
    public let id: String; public let taskID: String; public let title: String; public let actions: [String]
    public let checkedAt: Date; public var decision: ApprovalDecision?
}
public enum BouncerItem: Identifiable, Equatable, Sendable {
    case user(id: String, text: String), reply(id: String, text: String, toolSteps: Int)
    case report(id: String, taskID: String, role: String, text: String, toolSteps: [String])
    case question(BouncerQuestion), approval(ApprovalCard), note(id: String, text: String), stopped(id: String)
}
public enum BouncerEvent: Equatable, Sendable {
    case started(sessionFile: String?, isNew: Bool), item(BouncerItem), textDelta(String), toolStep(String)
    case replying(Bool), closed(questionID: String), tasks([BouncerTask]), banner(String?), failed(String), exited(String)
    case models([String])  // get_available_models, each "provider/id", for the Model menu; the thread ignores it
}
public struct BouncerThread: Equatable, Sendable {
    public private(set) var items: [BouncerItem]; public private(set) var tasks: [BouncerTask]
    public private(set) var banner: String?; public private(set) var replying: Bool
    public init(items: [BouncerItem] = [], tasks: [BouncerTask] = [])
    public mutating func apply(_ event: BouncerEvent)
    public mutating func answer(_ questionID: String, _ answer: BouncerAnswer)
    public mutating func decide(_ approvalID: String, _ decision: ApprovalDecision) throws  // empty reason: BouncerError.reasonRequired
    public var waitingCount: Int  // open questions + undecided approvals
}
public enum BouncerSetupStep: Equatable, Sendable { case chooseWorkspace, confirmRemotes, installPi }
public func bouncerSetupSteps(workspace: WorkspaceSettings, isWorkspace: Bool, remotes: [WorkspaceRemote]?, piPath: String?) -> [BouncerSetupStep]
public func otherWaits(_ sessions: [SessionRow], bouncerSessionFile: String?) -> [SessionRow]

// RoundsCore/PiRPC.swift
public struct PiRPCFramer { public mutating func feed(_ data: Data) -> [Data] }  // splits on LF only, drops one CR before it
public enum PiRPCRecord: Equatable, Sendable {
    case response(id: String?, command: String, success: Bool, error: String?)
    case state(id: String?, sessionFile: String?, model: String?), messages(id: String?, [BouncerItem])  // get_state, get_messages data
    case event(BouncerEvent), uiRequest(BouncerQuestion, timeoutMs: Int?), ignored(type: String), malformed(String)
    case aborted  // agent_settled with aborted: true
}
public func decodePiRPC(_ line: Data) -> PiRPCRecord
public func encodePiRPC(_ command: PiRPCCommand) -> Data  // one JSON object + LF
public enum PiRPCCommand: Sendable {
    case prompt(id: String, message: String), abort(id: String), getState(id: String), getMessages(id: String)
    case setModel(id: String, provider: String, model: String), availableModels(id: String), uiResponse(BouncerQuestion, BouncerAnswer)
}
public func bouncerArguments(sessionFile: String?, fileExists: Bool, sessionDir: String) -> (arguments: [String], isNew: Bool)

// RoundsCore/BouncerAdapter.swift
public protocol BouncerAdapter: Sendable {
    var events: AsyncStream<BouncerEvent> { get }
    func start() async throws
    func send(_ text: String) async throws
    func stop() async
    func answer(_ questionID: String, _ answer: BouncerAnswer) async throws
    func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws  // PiRPCBouncer: BouncerError.notAvailable
    func checkAgain() async
    func setModel(_ id: String?) async throws
    func shutdown() async
}
public actor PiRPCBouncer: BouncerAdapter { public init(executable: URL, folder: URL, sessionFile: String?, sessionDir: String) }  // arguments: bouncerArguments
```

Changes made in 01a, each for Pi's real messages: `confirms`, because option 2's text and `confirmed: true` need the dialog kind; `uiResponse` takes the question, because the encoder needs the option text; `.state` and `.messages`, because the adapter needs `sessionFile`, the start model and the history; `BouncerError` and the thread `init`, because the contract used them without a definition; `noAnswer`, because each command has a 10 s limit; `.aborted`, because the "stopped" item comes from Pi's `agent_settled`, not from the `abort` response, which Pi also sends when idle; the `PiRPCBouncer` init takes the session, not arguments, because the adapter always builds `bouncerArguments`, so Pi cannot start with tools. Message items take the id `pi-<role>-<timestamp>`, so `get_messages` after a restart replaces the live items and does not repeat them; a message without a timestamp gets a new id. A dialog takes the id `pi-ui-<id>`, so it cannot replace another item with the same id; the response sends Pi's own id.

App side: `BouncerModel.shared` holds `thread: BouncerThread`, `adapter: any BouncerAdapter`, `setupSteps`, `otherWaits` and `selection: String?` (nil is the Bouncer row). `pillWaiting` is `thread.waitingCount`; the pill reads only that, so other changes do not redraw it.

## How it works

- Mode: `bouncerMode` off keeps today's app. On, `BouncerModel.start()` makes the adapter; Off calls `shutdown()` and closes the window.
- Pill (`EdgePill`): in Bouncer mode it shows the Bouncer state only. `pillWaiting` 0: the empty clear glass tab of today, still, no number. More than 0: orange (`systemOrange`, ink #2B1A00) with the number; `RingingTab` peeks every 2 s with the ring. Reduce Motion: orange and still. `EdgeDrawer.observe` tracks `pillWaiting` and `bouncerMode` as it tracks `ringing`, for the larger panel size.
- Click: `EdgeDrawer.open(display:)` calls `BouncerWindowController.shared.show()` in Bouncer mode. The focus goes to the title of the first undecided approval card, else option 1 of the first open question, else the prompt box.
- Pi adapter: `pi --mode rpc` plus `bouncerArguments`, which always adds the no-tools flags (see Decided). The adapter builds the arguments itself. A command without a response in 10 s fails with `noAnswer`. A recorded session file that exists adds `--session <file>`; a missing file starts a new session and a note "New conversation. The earlier Bouncer session file is missing." Any other launch error shows in the banner and keeps the thread (CONTEXT.md, Bouncer Session). After start: `get_state` gives `sessionFile`, saved as `bouncerSessionFile` once the file exists (Pi writes a new session file after the first reply); `get_messages` fills the thread; `get_available_models` gives `.models` for the Model menu.
- Stream: assistant `message_update` text deltas grow the current reply; `tool_execution_start` adds a tool step to it; only `agent_settled` sets `replying` to false (`agent_end` can be followed by a retry). While a reply runs, the send button is a stop button that sends `abort`; `agent_settled` with `aborted: true` adds the "stopped" item; the window sends no prompt then, because Pi rejects a `prompt` during a run without `streamingBehavior`.
- Dialogs: `extension_ui_request` `select` gives a question with its options in order; `confirm` gives Yes and No; `input` and `editor` give a question with a text field. The answer goes back as `extension_ui_response` with the same `id` (`value`, `confirmed` or `cancelled: true`). A request with `timeout`: when Pi resolves it, the card shows "Pi closed this question." and stops counting. `notify` gives a note; `setStatus`, `setWidget`, `setTitle` and `set_editor_text` are ignored.
- Exit: Rounds closes stdin at quit or Off (quit also waits for a stop that an earlier Off started), then sends SIGTERM after 5 s and SIGKILL after 5 s more, because Pi ignores a single signal during its shutdown. An unexpected exit shows the last stderr lines in the banner with Start Again.
- Set Up row: `bouncerSetupSteps` from `WorkspaceSettingsState` and the `pi` path; it shows above the tasks only when a step is missing. A click opens Settings on the Workspace or Agents page (`SettingsState.page`). The adapter starts only with no step missing; `remotes` is nil until the check of the workspace folder finds a repository, so Pi does not start before that check ends.
- Host note: `otherWaits(AppModel.shared.allGroups.sessions, ...)` gives the sessions that need input or failed, without the Bouncer's own session. 0 hides the button. The popover lists title and state word, "Shown by Rounds; the Bouncer does not see these." and Open Session List (`PanelController.shared.show(.yourTurn)`).
- Demo: `--demo` makes `DemoBouncer`, which plays the mockup thread: one undecided approval, one open three-option question, so the pill shows 2.

| Keys | Action |
|---|---|
| ⌘N | New Task (see Decided) |
| ⌃Tab, ⌃⇧Tab | Next, previous row in sidebar order, Bouncer row included; wraps |
| Return, ⇧Return | Send; new line. No send while text is marked (input method) |
| Esc | Closes, in this order: a menu, the popover, the reply (stop), a sidebar or details overlay below 700 pt |
| ⌘W | Closes the window; the adapter keeps running |

Accessibility: the pill label is "Bouncer", its value "N waiting for you" or "Nothing waiting", and its hint "Opens the Bouncer Window". Each state dot has its state word in its label. The approval card is one group with a heading; its actions are a list in order. In 01b the card shows only the count of its actions; the ordered action list comes in 01c with `BouncerCards.swift`. Every control is reachable with Tab and shows the grey hover fill. Reduce Motion stops the pill and the typing dots.

Docs in the same commit: 01b changes spec 4 (new components), 5.1 (the pill's menu), 5.4 (General toggle, Keys rows), 5.7 (the pill in Bouncer mode), 2.7 (the Bouncer session folder is not read), 7.1 (the `--demo-scene bouncer` scene), and adds 5.9 Bouncer Window. GLOSSARY.md: the Pill entry, and Bouncer and Bouncer Window under Window. CONTEXT.md: the new names (host note, fact banner, Set Up row) before the code uses them. 01c adds the task, card and details parts to 5.9.

## Tests

In `Tests/RoundsCoreTests`, run with `scripts/test.sh`. The window has no test target; the agent checks it with `--demo` and window screenshots (AGENTS.md).

| Case | Input | Expect |
|---|---|---|
| Split record | One JSON record fed in two parts | One record, after the second part |
| CRLF | A record that ends with CR LF | Decodes; no CR in the text |
| Unicode separator | U+2028 inside a JSON string | One record, not two |
| Malformed line | `{"type":` | `.malformed`, the next line still decodes |
| No approval from Pi | `extension_ui_request` `select` titled "Approve 4 actions" | `.uiRequest` question with id `pi-ui-<id>` |
| Dialog id | A dialog with the id of an approval card in the thread | The card stays; the response has Pi's id |
| Answer encoding | option 2 of a `select`; `confirm` yes; dismiss | `value` is option 2's text; `confirmed: true`; `cancelled: true`; `id` kept |
| Waiting count | Empty; one open question; plus one approval; answer the question; Pi opens and then closes a second question; approve | 0, 1, 2, 1, 1, 0 |
| Reject reason | Reject with "" and with spaces | `reasonRequired`; card still undecided |
| Run end | `agent_end` then nothing; then `agent_settled` | Still replying; then not |
| Tool steps | Two `tool_execution_start` in one reply | The reply has 2 steps |
| Reopen | Recorded file exists; missing; nil | `--session <file>`, not new; no `--session`, new; new |
| No tools | Any case above | The arguments always hold `--no-tools`, `--no-extensions`, `--no-mcp`, `--no-skills` and `--no-prompt-templates` |
| Setup steps | No workspace; remotes not confirmed; no `pi`; all set | One step each; empty |
| Other waits | Bouncer's own session needs input; one other does | Only the other |
| Child process | `PiRPCBouncer` on a script that prints one response and exits 1 with stderr | A `.started`, then `.exited` with the stderr text |
| Launch arguments | A script that records its arguments | The five no-tools flags |
| Stubborn child | A script that ignores stdin EOF and SIGTERM | `shutdown()` ends it in the limit; `events` finishes |
| Exit during a command | The script exits while `send()` waits | `notRunning` |
| No response | The script reads and never answers | `noAnswer` |
| Dialog timeout | A question with a 100 ms timeout | `.closed`; a later `answer()` throws `unknownQuestion` |
| No executable | A path that does not exist | `start()` throws; no event |

## Numbers

| Measure | How | Target |
|---|---|---|
| Click to window shown | Log time at the click and at `windowDidBecomeKey`, `--demo` | 150 ms or less |
| CPU, pill still | `top -l 30 -pid <Rounds>`, mode on, nothing waits | 0.5% or less on average |
| CPU, pill bouncing | Same, `--demo` (2 waiting) | 1% or less (SwiftUI keyframes took about 15%) |
| Memory | `footprint <pid>`, window open with demo data, against mode off | 30 MB more or less |
| Reply redraws | Count thread changes per second during a long reply | 30 or fewer (deltas are joined) |
| Pi start | Launch to `get_state` response | 3 s or less |
| Quit | stdin closed to child exit | 5 s or less, else SIGTERM, then SIGKILL after 5 s more |

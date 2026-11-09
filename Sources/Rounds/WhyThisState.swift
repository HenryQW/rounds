import AppKit
import RoundsCore
import SwiftUI

/// The open Why This State… popover (spec 5.2): the row, its classifier input and the explanation, taken when it
/// opened, so the popover and the report show the same decision; and the report form.
@MainActor @Observable
final class WhyThisState {
    enum Step { case explain, report, saved(URL) }

    let row: SessionRow
    let input: StateInput?
    let explanation: StateExplanation?
    var step = Step.explain
    /// Nil: Not Sure.
    var correct: SessionState?
    var error: String?

    init(row: SessionRow, explained: (input: StateInput, explanation: StateExplanation)?) {
        (self.row, input, explanation) = (row, explained?.input, explained?.explanation)
    }

    /// "Source", "Rule", then each signal, as label and value; a signal with a time adds "13 min. ago".
    var lines: [(label: String, value: String)] {
        guard let e = explanation else { return [] }
        return [("Source", e.source), ("Rule", e.rule.label)] + e.signals.map { s in
            let time = s.at.map { min($0, .now).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) }
            return (s.label, [s.value, time ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        }
    }

    /// The text that Copy puts on the pasteboard: the state, the sentence and every line. No title.
    var text: String {
        ([row.status.label] + (explanation.map { [$0.sentence] } ?? []) + lines.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
    }
}

/// The popover under a row: the state, the rule that decided it and the signals; Report Wrong State… shows the report
/// form in the same popover, then the saved file.
struct WhyThisStateView: View {
    @Bindable var why: WhyThisState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch why.step {
            case .explain: explanation
            case .report: report
            case .saved(let url): saved(url)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(why.row.status.label).font(.headline)
            Text(why.explanation?.sentence ?? "Rounds has no signals for this session.").font(.callout).foregroundStyle(.secondary)
        }
        if why.explanation != nil {
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(Array(why.lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Text(line.label).foregroundStyle(.secondary)
                        Text(line.value)
                    }
                }
            }
            .font(.callout)
        }
        Divider()
        HStack {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(why.text, forType: .string)
            }
            Spacer()
            Button("Report Wrong State…") { why.step = .report }.disabled(why.input == nil)
        }
    }

    @ViewBuilder
    private var report: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Report Wrong State").font(.headline)
            Text("Rounds saves this state, its rule and its signals to a file on this Mac, with no prompt, reply or title text.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Picker("Correct state", selection: $why.correct) {
            Text("Not Sure").tag(SessionState?.none)
            Divider()
            ForEach(SessionState.allCases, id: \.self) { Text($0.title.capitalized).tag(Optional($0)) }
        }
        .fixedSize()
        if let error = why.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            Button("Cancel") { (why.step, why.error) = (.explain, nil) }.keyboardShortcut(.cancelAction)
            Button("Save Report") { save() }.keyboardShortcut(.defaultAction)
        }
    }

    private func saved(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Report saved", systemImage: "checkmark.circle").font(.headline)
                Text(url.lastPathComponent).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func save() {
        guard let input = why.input, let explanation = why.explanation else { return }
        do {
            why.step = .saved(try AppModel.shared.saveReport(why.row, input: input, explanation: explanation, correct: why.correct))
        } catch {
            why.error = "The report was not saved: \(error.localizedDescription)"
        }
    }
}

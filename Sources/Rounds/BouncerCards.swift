import RoundsCore
import SwiftUI

/// Only a structured host ApprovalCard enters this view. Agent text stays in the conversation renderer.
struct BouncerApprovalCard: View {
    let card: ApprovalCard
    let focus: FocusState<BouncerFocus?>.Binding
    @Bindable var state: BouncerWindowState
    let decide: (ApprovalDecision) -> Void

    private var reason: Binding<String> {
        Binding(get: { state.rejectionReasons[card.id] ?? "" }, set: { state.rejectionReasons[card.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.headline)
                        .focusable().focused(focus, equals: .approval(card.id))
                        .accessibilityAddTraits(.isHeader)
                    Text("From Rounds, not the agent").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(card.actions.enumerated()), id: \.offset) { i, action in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(action).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityRepresentation {
                List(Array(card.actions.enumerated()), id: \.offset) { i, action in
                    Text("\(i + 1). \(action)")
                }
                .accessibilityLabel("\(card.actions.count) actions, in order")
            }
            Text("Demo check: \(card.checkedAt.formatted(date: .omitted, time: .shortened)). No action will run.")
                .font(.callout).foregroundStyle(.secondary)
            if let decision = card.decision {
                switch decision {
                case .approved: Label("Approved in this demo", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .rejected(let reason): Text("Rejected: \(reason)").foregroundStyle(.secondary)
                }
            } else {
                Divider()
                TextField("Reason to reject (required)", text: reason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Reason to reject, required before Reject")
                HStack {
                    Text("Needs input").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reject") { decide(.rejected(reason: reason.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines))) }
                        .disabled(reason.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .bouncerHover("reject-\(card.id)", state: state)
                    Button("Approve") { decide(.approved) }
                        .bouncerHover("approve-\(card.id)", state: state)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval from Rounds")
    }
}

struct BouncerResultCard: View {
    let title: String
    let details: BouncerTaskDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Result: \(title)", systemImage: "checkmark.square")
                .font(.headline).accessibilityAddTraits(.isHeader)
            if let summary = details.summary { Text(summary).textSelection(.enabled) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Repository")
                    Text("Check")
                    Text("State")
                }
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(details.checks.enumerated()), id: \.offset) { _, check in
                    GridRow {
                        Text(check.repository).font(.callout.monospaced())
                        Text(check.name).font(.callout)
                        Text(check.result).font(.callout).foregroundStyle(check.passed ? Color.green : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !details.risks.isEmpty {
                Text("Risks").font(.callout.weight(.semibold))
                ForEach(details.risks, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bouncerCard()
    }
}

struct BouncerReportCard: View {
    let id: String
    let task: BouncerTask?
    let role: String
    let text: String
    let steps: [String]
    @Bindable var state: BouncerWindowState
    let selectTask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(role).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                if let task {
                    Button(task.title, action: selectTask).buttonStyle(.link)
                        .bouncerHover("report-\(id)", state: state)
                        .help("Open the task conversation and details")
                }
            }
            Text(text).textSelection(.enabled)
            if !steps.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { state.expandedReports.contains(id) }, set: {
                    if $0 { state.expandedReports.insert(id) } else { state.expandedReports.remove(id) }
                })) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(step).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(steps.count == 1 ? "1 tool step" : "\(steps.count) tool steps").font(.callout)
                }
                .bouncerHover("steps-\(id)", state: state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bouncerCard()
    }
}

struct BouncerFactBanner: View {
    @Bindable var state: BouncerWindowState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Not confirmed").font(.callout.weight(.semibold))
                Text("The Barback “Update call sites” may still run. Docker did not respond within 5 seconds.")
                    .font(.callout)
                Text("Shown by Rounds. Demo data.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Check Again") { state.factUnconfirmed = false }
                .bouncerHover("check-again", state: state)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    func bouncerCard() -> some View {
        padding(12)
            .background(Color.primary.opacity(0.025), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }

    func bouncerHover(_ id: String, state: BouncerWindowState) -> some View {
        background(Color.primary.opacity(state.hovered == id ? 0.08 : 0), in: .rect(cornerRadius: 4))
            .onHover { inside in
                if inside { state.hovered = id } else if state.hovered == id { state.hovered = nil }
            }
    }
}

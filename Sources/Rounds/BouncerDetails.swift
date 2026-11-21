import RoundsCore
import SwiftUI

/// Placeholder evidence for slice 01. Dispatch supplies real task evidence in slice 03.
struct BouncerTaskDetails: Sendable {
    struct Change: Sendable {
        let repository: String
        let path: String
        let added: Int
        let removed: Int
    }
    struct Check: Sendable {
        let repository: String
        let name: String
        let result: String
        let passed: Bool
    }
    struct Agent: Sendable {
        let role: String
        let name: String
        let state: String
        let child: Bool
    }
    struct Environment: Sendable {
        let repository: String
        let name: String
        let branch: String
        let revision: String
    }
    let summary: String?
    let risks: [String]
    let changes: [Change]
    let checks: [Check]
    let agents: [Agent]
    let environments: [Environment]
}

struct BouncerDetails: View {
    let task: BouncerTask
    let details: BouncerTaskDetails
    @Bindable var state: BouncerWindowState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Task Details").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if state.narrow {
                        Button("Close") { state.details = nil }
                            .bouncerHover("close-details", state: state)
                            .accessibilityLabel("Close task details")
                    }
                }
                section("Changes") {
                    if details.changes.isEmpty { empty("No changes reported.") }
                    ForEach(Array(details.changes.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.repository).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            Text(change.path).font(.callout.monospaced()).textSelection(.enabled)
                            Text("+\(change.added)  -\(change.removed)").font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                section("Checks") {
                    if details.checks.isEmpty { empty("No checks reported.") }
                    ForEach(Array(details.checks.enumerated()), id: \.offset) { _, check in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.repository).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            Text(check.name).font(.callout)
                            Label(check.result, systemImage: check.passed ? "checkmark.circle" : "minus.circle")
                                .font(.callout).foregroundStyle(check.passed ? Color.green : .secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                section("Agents") {
                    ForEach(Array(details.agents.enumerated()), id: \.offset) { _, agent in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.role).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            Text(agent.name).font(.callout)
                            Text(agent.state).font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.leading, agent.child ? 16 : 0)
                        .accessibilityElement(children: .combine)
                    }
                }
                section("Environment") {
                    if details.environments.isEmpty { empty("No environment reported.") }
                    ForEach(Array(details.environments.enumerated()), id: \.offset) { _, environment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(environment.repository).font(.callout.weight(.semibold))
                            Text(environment.name)
                            Text(environment.branch)
                            Text("Revision \(environment.revision)")
                        }
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    }
                    if !details.environments.isEmpty {
                        empty("Shared Dagger engine. Egress proxy only.")
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .background(.background)
        .accessibilityLabel("Details for \(task.title)")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { state.detailSections.contains(title) }, set: {
            if $0 { state.detailSections.insert(title) } else { state.detailSections.remove(title) }
        })) {
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
        }
        .bouncerHover("details-\(title)", state: state)
        .bouncerCard()
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

extension BouncerTaskState {
    var title: String {
        switch self {
        case .working: "Working"
        case .needsInput: "Needs input"
        case .failed: "Failed"
        case .finished: "Finished"
        case .stopped: "Stopped"
        }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .needsInput: .orange
        case .failed: .red
        case .finished: .green
        case .stopped: .secondary
        }
    }
}

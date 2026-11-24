import AppKit
import Foundation
import Observation
import RoundsCore
import SwiftUI

/// Local organization rules. The store refuses corrupt data and reloads before every change.
@MainActor @Observable
final class OrganizationSettingsState {
    static let shared = OrganizationSettingsState()
    private static let addedKey = "organizationAddedDirectories"
    private let directory = Demo.isOn
        ? FileManager.default.temporaryDirectory.appending(path: "rounds-demo-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.applicationSupportDirectory.appending(path: "Rounds")
    private(set) var policy = OrganizationPolicy()
    private(set) var loaded = false
    @ObservationIgnored private var lease: OrganizationPolicyLease?
    @ObservationIgnored private var leaseAttempted = false
    var hasLease: Bool { lease != nil }
    var mayRetry: Bool { lease != nil || !leaseAttempted }
    private(set) var needsRecovery = false
    var error: String?
    var warning: String?
    var addingOrganization = false
    var organizationName = ""
    var permissionOrganization: OrganizationPolicy.Organization?
    var confirmRecovery = false
    var permissionDestination: OrganizationDestination?
    var confirmPermission = false
    private(set) var addedDirectories: [String] = appDefaults.stringArray(forKey: addedKey) ?? []
    var store: OrganizationPolicyStore { OrganizationPolicyStore(url: directory.appending(path: "organization-policy.json")) }

    private init() {
        reload()
        // Two fictional organizations for the Organizations demo, in the demo's temporary folder.
        if Demo.isOn && loaded && policy.organizations.isEmpty {
            change {
                try $0.addOrganization(name: "HenryQW")
                try $0.addOrganization(name: "Evermark")
            }
        }
    }

    func reload() {
        do {
            if lease == nil {
                guard !leaseAttempted else { throw OrganizationPolicyError.anotherInstance }
                leaseAttempted = true
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                lease = try store.acquireLease()
            }
            policy = try store.load()
            loaded = true
            needsRecovery = false
            error = nil
        } catch {
            loaded = false
            needsRecovery = (error as? OrganizationPolicyError) == .interruptedWrite
            if (error as? OrganizationPolicyError) == .anotherInstance {
                self.error = "Another Rounds instance manages organization permissions. Quit this instance and reopen it after the other one closes."
            } else if lease == nil && leaseAttempted {
                self.error = "Could not acquire organization permissions. Quit Rounds and reopen it after resolving the error: \(error.localizedDescription)"
            } else {
                self.error = needsRecovery
                    ? "A rules update was interrupted. Remote sends remain blocked until you recover the rules."
                    : "Could not read organization rules: \(error.localizedDescription)"
            }
        }
    }

    func retry() {
        reload()
        if loaded { TicketStore.shared.checkGitHub() }
    }

    func withPolicy<T>(_ body: (OrganizationPolicy) throws -> T) throws -> T {
        guard lease != nil else { throw OrganizationPolicyError.anotherInstance }
        return try store.withPolicy(body)
    }

    func addOrganization() {
        let name = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        change { _ = try $0.addOrganization(name: name) }
        if error == nil { organizationName = ""; addingOrganization = false }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Projects"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            if !addedDirectories.contains(path) { addedDirectories.append(path) }
        }
        appDefaults.set(addedDirectories, forKey: Self.addedKey)
    }

    /// Moving one folder changes its explicit rule. Conflicting inherited rules remain local.
    func assign(_ path: String, to organization: UUID?) {
        change { try $0.assignDirectory(path, to: organization) }
    }

    func setPermission(organization: UUID, destination: OrganizationDestination, allowed: Bool) {
        change { policy in
            let current = PushStore.shared.organizationDestinations + TicketStore.shared.organizationDestinations
            guard current.contains(destination) else { throw AssignmentError.destinationChanged }
            if allowed {
                try policy.grant(organizationID: organization, service: destination.service, destinationIdentity: destination.identity)
            } else {
                try policy.revoke(organizationID: organization, service: destination.service, destinationIdentity: destination.identity)
            }
        }
    }

    func allows(row: SessionRow, destination: OrganizationDestination) -> Bool {
        guard lease != nil else { return false }
        return Self.allows(storeURL: store.url, directory: row.cwd, destination: destination)
    }

    nonisolated static func allows(storeURL: URL, directory: String, destination: OrganizationDestination) -> Bool {
        guard let policy = try? OrganizationPolicyStore(url: storeURL).load() else { return false }
        return policy.allowsTransmission(sessionDirectory: directory, gitRemote: .unknown,
                                         service: destination.service, destinationIdentity: destination.identity)
    }

    func recoverRules() {
        guard lease != nil else { return }
        do {
            let result = try store.recoverInterruptedWrite()
            reload()
            if result == .savedNeedsRecovery {
                error = "Rules were saved, but recovery is still required."
            } else if loaded {
                TicketStore.shared.checkGitHub()
            }
            warning = result == .savedMarkerNotDurable ? "Rules were saved, but recovery may be needed after a restart." : nil
        } catch {
            self.error = "Could not recover organization rules: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func resetPermissions(service: String) -> Bool {
        guard lease != nil else { return false }
        do {
            let current = try store.load()
            guard current.grants.contains(where: { $0.service == service }) else { return true }
            return change { $0.revokeAll(service: service) }
        } catch {
            loaded = false
            self.error = "Organization permissions could not be read."
            return false
        }
    }

    @discardableResult
    func reconcilePermissions(service: String, destinationIdentity: String) -> Bool {
        guard lease != nil else { return false }
        do {
            let current = try store.load()
            guard current.grants.contains(where: { $0.service == service && $0.destinationIdentity != destinationIdentity }) else { return true }
            return change { $0.retainGrants(service: service, destinationIdentity: destinationIdentity) }
        } catch {
            loaded = false
            self.error = "Organization permissions could not be read."
            return false
        }
    }

    @discardableResult
    private func change(_ edit: (inout OrganizationPolicy) throws -> Void) -> Bool {
        guard lease != nil else { return false }
        do {
            let result = try store.update(edit)
            if result == .savedNeedsRecovery {
                reload()
                error = "Rules were saved, but recovery is required before remote sends."
                return false
            }
            policy = try store.load()
            loaded = true
            error = nil
            warning = result == .savedMarkerNotDurable ? "Rules were saved, but recovery may be needed after a restart." : nil
            return true
        } catch {
            let message: String
            switch error as? OrganizationPolicyError {
            case .conflict: message = "This folder conflicts with another organization rule. Resolve the conflict first."
            case .inheritedRule: message = "This folder inherits a rule from a parent folder. Change the parent rule first."
            case .assignedChildren: message = "Move this folder's assigned child projects first."
            case .remoteRulesUnavailable: message = "Git remote rules cannot be checked here. Projects stay local until their remotes can be verified."
            default: message = error.localizedDescription
            }
            reload()
            if !needsRecovery { self.error = message }
            return false
        }
    }

    private enum AssignmentError: LocalizedError {
        case destinationChanged
        var errorDescription: String? {
            switch self {
            case .destinationChanged: "The destination changed. Review it again before allowing access."
            }
        }
    }
}

struct OrganizationSettingsView: View {
    let model: AppModel
    @Bindable private var state = OrganizationSettingsState.shared
    @Bindable private var bars = BarSettingsState.shared

    private var paths: [String] {
        let stored = state.policy.rules.compactMap { rule -> String? in
            if case .directory(let path) = rule.match { return path }
            return nil
        }
        let known = model.organizationDirectories + state.addedDirectories
        return Array(Set(known + stored)).sorted()
    }

    private func organization(for path: String) -> UUID? {
        guard case .classified(let id) = state.policy.classify(sessionDirectory: path, gitRemote: .unknown) else { return nil }
        return UUID(uuidString: id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Organizations").font(.title2.bold())
                Text("Drag a project to an organization, or use its menu.").foregroundStyle(.secondary)
                if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let warning = state.warning { Text(warning).foregroundStyle(.orange).textSelection(.enabled) }
                if !state.loaded && !state.needsRecovery && state.mayRetry { Button("Retry") { state.retry() } }
                if state.needsRecovery {
                    Button("Recover Rules…") { state.confirmRecovery = true }
                }
                if state.loaded {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            localColumn
                            organizationsColumn
                        }
                        .frame(minWidth: 560, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 20) {
                            localColumn
                            organizationsColumn
                        }
                    }
                    Text("Rules apply to every Rounds session.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .alert("Recover organization rules?", isPresented: $state.confirmRecovery) {
            Button("Cancel", role: .cancel) {}
            Button("Recover Rules", role: .destructive) { state.recoverRules() }
        } message: {
            Text("Rounds will remove all remote permissions. Review and allow each destination again.")
        }
        .sheet(item: $state.permissionOrganization) { organization in
            OrganizationPermissionsView(organization: organization)
        }
        .onAppear { bars.refresh() }
        .onDisappear {
            state.confirmRecovery = false
            state.permissionOrganization = nil
            bars.ownerOrganization = nil
            bars.confirmCreate = false
        }
        .sheet(item: $bars.ownerOrganization) { organization in
            VStack(alignment: .leading, spacing: 16) {
                Text("Owner of \(organization.name)").font(.headline)
                Text("The host and the account that may receive pushes of this organization, such as github.com/HenryQW. The account can be a person or a GitHub organization.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Owner", text: $bars.ownerText, prompt: Text("github.com/account"))
                if let error = bars.ownerError { Text(error).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { bars.ownerOrganization = nil }
                    Button("Save") { _ = bars.saveOwner() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 400)
        }
        .alert("Create a repository in this folder?", isPresented: $bars.confirmCreate) {
            TextField("Bar name", text: $bars.repositoryName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { bars.create(projectFolders: paths) }
        } message: {
            Text("Rounds runs git init in \(bars.createOrganization.flatMap { bars.pendingFolders[$0] } ?? "") and writes the bar name to \(barFileName). It does not add a remote, commit or push.")
        }
        .sheet(isPresented: $state.addingOrganization) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add an Organization").font(.headline)
                TextField("Organization name", text: $state.organizationName)
                if let error = state.error { Text(error).foregroundStyle(.red) }
                HStack { Spacer(); Button("Cancel") { state.addingOrganization = false; state.organizationName = "" }; Button("Add") { state.addOrganization() }.keyboardShortcut(.defaultAction) }
            }
            .padding(20).frame(width: 360)
        }
    }

    private var localColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Keep local").font(.headline); Spacer(); Button("Add Project…") { state.addProject() } }
            Text("No ticket lookups or remote alerts. Moving a folder here also keeps its assigned child projects local.")
                .font(.caption).foregroundStyle(.secondary)
            projectList(paths.filter { organization(for: $0) == nil }, target: nil)
            Text("Unmatched or conflicting rules stay local.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var organizationsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Organizations").font(.headline); Spacer(); Button("Add Organization…") { state.addingOrganization = true } }
            Text("Projects inherit their organization's rules.").font(.caption).foregroundStyle(.secondary)
            ForEach(state.policy.organizations) { item in
                GroupBox(item.name) {
                    VStack(alignment: .leading, spacing: 8) {
                        OrganizationBarRows(organization: item, projectFolders: paths)
                        projectList(paths.filter { organization(for: $0) == item.id }, target: item.id)
                        Divider()
                        Button("Review Permissions…") { state.permissionOrganization = item }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func projectList(_ items: [String], target: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if items.isEmpty { Text("Drop projects here.").font(.caption).foregroundStyle(.secondary).padding(8) }
            ForEach(items, id: \.self) { path in
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Menu("Move") {
                        Button("Keep Local") { state.assign(path, to: nil) }
                        ForEach(state.policy.organizations) { organization in
                            Button(organization.name) { state.assign(path, to: organization.id) }
                        }
                    }
                    .accessibilityLabel("Move \(URL(fileURLWithPath: path).lastPathComponent)")
                }
                .padding(8)
                .draggable(path)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { items, _ in
            guard let path = items.first, paths.contains(path) else { return false }
            state.assign(path, to: target)
            return true
        }
    }
}

private struct OrganizationPermissionsView: View {
    let organization: OrganizationPolicy.Organization
    @Environment(\.dismiss) private var dismiss
    @Bindable private var state = OrganizationSettingsState.shared
    @Bindable private var pushes = PushStore.shared
    @Bindable private var tickets = TicketStore.shared

    private var destinations: [OrganizationDestination] {
        pushes.organizationDestinations + tickets.organizationDestinations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions for \(organization.name)").font(.headline)
            Text("Allow each destination to receive information from this organization.")
                .foregroundStyle(.secondary)
            if let error = state.error { Text(error).foregroundStyle(.red) }
            if destinations.isEmpty {
                Text("No configured destinations are available. Add them in Notifications or Tickets.")
                    .foregroundStyle(.secondary)
            }
            ForEach(destinations) { destination in
                let allowed = state.policy.grants.contains {
                    $0.organizationID == organization.id && $0.service == destination.service && $0.destinationIdentity == destination.identity
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text(destination.title)
                        Text(destination.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(allowed ? "Allowed" : "Local only").foregroundStyle(.secondary)
                    if allowed {
                        Button("Revoke") { state.setPermission(organization: organization.id, destination: destination, allowed: false) }
                    } else {
                        Button("Review…") {
                            state.permissionDestination = destination
                            state.confirmPermission = true
                        }
                    }
                }
                Divider()
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear {
            pushes.prepareOrganizationDestinations()
            tickets.prepareOrganizationDestinations()
        }
        .onDisappear {
            state.confirmPermission = false
            state.permissionDestination = nil
        }
        .alert("Allow this destination?", isPresented: $state.confirmPermission, presenting: state.permissionDestination) { destination in
            Button("Cancel", role: .cancel) {}
            Button("Allow") { state.setPermission(organization: organization.id, destination: destination, allowed: true) }
        } message: { destination in
            Text("Allow \(destination.title) (\(destination.detail)) to receive information from \(organization.name). Alerts can include session titles and status. Ticket lookups can include branch names and issue links.")
        }
    }
}

import AppKit
import Foundation
import Observation
import RoundsCore
import SwiftUI

/// Bar setup (spec 2.7.2): the bar folder, its remotes and the task detail folders. The store refuses
/// corrupt data; every change reloads it first.
@MainActor @Observable
final class BarSettingsState {
    static let shared = BarSettingsState()
    private let directory = Demo.isOn
        ? FileManager.default.temporaryDirectory.appending(path: "rounds-demo-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.applicationSupportDirectory.appending(path: "Rounds")
    var store: BarSettingsStore { BarSettingsStore(url: directory.appending(path: "bar-settings.json")) }
    private(set) var settings = BarSettings()
    private(set) var loaded = false
    /// The folder the user chose, and what Git says about it; nil while no folder is chosen or the check runs.
    private(set) var folder: String?
    private(set) var inspection: BarInspection?
    private(set) var inspecting = false
    var error: String?
    /// The user's answer to "Create a repository in this folder?"; no until the user says yes.
    var createRepository = false
    var repositoryName = ""
    var confirmCreate = false
    /// A folder chosen for a scope but not yet approved.
    private(set) var chosenDetail: [BarScope: String] = [:]

    private init() {
        if Demo.isOn {
            // Fictional values; demo mode inspects, creates and saves nothing.
            folder = "/Users/demo/Projects/bar"
            inspection = .repository(root: "/Users/demo/Projects/bar",
                                     remotes: [BarRemote(name: "origin", url: "https://example.invalid/demo/bar.git")])
            chosenDetail[.unclassified] = "/Users/demo/Private/Task Details"
            loaded = true
            return
        }
        reload()
        if let bar = settings.bar { inspect(bar.path, adopt: false) }
    }

    var repositoryRoot: String? {
        if case .repository(let root, _) = inspection { root } else { nil }
    }

    /// The folder is the root of its repository and has no problem, so the repository section would only repeat it.
    var rootIsFolder: Bool {
        guard let folder, let root = repositoryRoot, !inspecting else { return false }
        return root == folder && settings.barProblem(inspection ?? .noRepository) != .folderChanged
    }

    var remotes: [BarRemote] {
        if case .repository(_, let remotes) = inspection { remotes } else { [] }
    }

    /// The selected folder is the recorded bar folder.
    var isBar: Bool {
        if Demo.isOn { return true }
        guard let folder, let bar = settings.bar else { return false }
        return FolderIdentity.current(folder) == bar
    }

    func reload() {
        do {
            settings = try store.load()
            loaded = true
            error = nil
        } catch {
            loaded = false
            self.error = "Could not read bar settings. Task details cannot be stored until the file is repaired or removed: \(store.url.path)"
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        (createRepository, repositoryName) = (false, "")
        inspect(url.path, adopt: true)
    }

    /// Runs Git off the main thread. A repository folder the user chose becomes the bar folder; the recorded
    /// folder checked at launch does not, so a replaced folder needs a new choice.
    func inspect(_ path: String, adopt: Bool) {
        guard !Demo.isOn else { return }
        (folder, inspection, inspecting) = (path, nil, true)
        Task {
            let result = await Task.detached { Result(catching: { try inspectBarFolder(path) }) }.value
            guard folder == path else { return }
            inspecting = false
            switch result {
            case .success(let found):
                inspection = found
                error = nil
                // The repository root becomes the bar folder.
                if adopt, case .repository(let root, _) = found {
                    folder = root
                    change { try $0.setBar(root) }
                }
            case .failure(let failure):
                error = "Could not inspect the folder: \(message(failure))"
            }
        }
    }

    /// Reads the recorded bar folder again; it does not adopt a replaced folder.
    func refresh() {
        guard let bar = settings.bar, !inspecting else { return }
        inspect(bar.path, adopt: false)
    }

    /// Called after the user confirms the alert.
    func create() {
        guard let folder, !Demo.isOn else { return }
        let name = repositoryName
        Task {
            let result = await Task.detached { Result(catching: { try createBarRepository(in: folder, name: name) }) }.value
            switch result {
            case .success:
                (createRepository, repositoryName) = (false, "")
                inspect(folder, adopt: true)
            case .failure(let failure):
                error = "Could not create the repository: \(message(failure))"
            }
        }
    }

    var acknowledged: Bool { isBar && !remotes.isEmpty && settings.acknowledges(remotes) }

    func setAcknowledged(_ on: Bool) {
        let remotes = remotes
        change { on ? try $0.acknowledgeRemotes(remotes) : $0.withdrawAcknowledgement() }
    }

    /// The folder a row shows: one chosen but not approved, else the approved one.
    func detailPath(_ scope: BarScope) -> String? {
        chosenDetail[scope] ?? settings.detailFolders[scope]?.path
    }

    func detailProblem(_ scope: BarScope) -> DetailFolderProblem? {
        guard let root = repositoryRoot else { return .notApproved }
        if let chosen = chosenDetail[scope] { return checkDetailFolder(chosen, repositoryRoot: root) ?? .notApproved }
        return settings.detailFolderProblem(for: scope, repositoryRoot: root)
    }

    /// A new folder needs a new approval.
    func chooseDetailFolder(_ scope: BarScope) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenDetail[scope] = url.path
        if settings.detailFolders[scope] != nil { change { $0.withdrawApproval(for: scope) } }
    }

    func setApproved(_ on: Bool, _ scope: BarScope) {
        guard let root = repositoryRoot else { return }
        if on {
            guard let path = detailPath(scope) else { return }
            if change({ try $0.approveDetailFolder(path, for: scope, repositoryRoot: root) }) { chosenDetail[scope] = nil }
        } else {
            change { $0.withdrawApproval(for: scope) }
        }
    }

    @discardableResult
    private func change(_ edit: (inout BarSettings) throws -> Void) -> Bool {
        guard !Demo.isOn else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            settings = try store.update(edit)
            loaded = true
            error = nil
            return true
        } catch {
            reload()
            if loaded { self.error = message(error) }
            return false
        }
    }

    private func message(_ error: Error) -> String {
        switch error as? BarError {
        case .invalidFolder: "The folder does not exist."
        case .invalidName: "Enter a name with no control characters, at most 100 characters."
        case .alreadyRepository: "The folder is already in a Git repository."
        case .fileExists: "The folder already has a \(barFileName) file. Rounds does not replace it."
        case .gitFailed(let text): text.isEmpty ? "Git failed." : text
        case .gitTimedOut: "Git did not answer in time."
        case .detailFolderInvalid(let problem): Self.text(problem)
        default: error.localizedDescription
        }
    }

    static func text(_ problem: DetailFolderProblem) -> String {
        switch problem {
        case .notApproved: "Not approved. Task details cannot be stored."
        case .missing: "The folder does not exist."
        case .replaced: "The folder was replaced. Approve it again."
        case .symlink: "The folder is a symbolic link. Choose the folder it points to."
        case .notOwner: "Another user owns this folder. Choose a folder that you own."
        case .notPrivate: "Other users can open this folder. Remove group and other access, and any ACL."
        case .insideRepository: "The folder is in the bar. Choose a folder outside it."
        }
    }
}

/// The four steps of bar setup, as sections of the Bar page.
struct BarSections: View {
    @Bindable var state: BarSettingsState
    @Bindable private var organizations = OrganizationSettingsState.shared

    var body: some View {
        if let error = state.error {
            Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        if state.loaded {
            folderSection
                // Remotes can change while the page is closed; read them again when it opens.
                .onAppear { state.refresh() }
            if state.folder != nil && !state.rootIsFolder { repositorySection }
            if state.isBar {
                remoteSection
                detailSection
            }
        }
    }

    private var folderSection: some View {
        Section {
            LabeledContent {
                Button(state.folder == nil ? "Choose…" : "Change…") { state.chooseFolder() }
            } label: {
                described("Bar folder", state.folder.map { abbreviate($0) } ?? "No folder chosen.")
            }
            .help(state.folder ?? "")
        } header: {
            step(1, "Choose a bar folder")
        } footer: {
            Text("The bar holds coordination records. Application code stays in its own repositories.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var repositorySection: some View {
        Section {
            if state.inspecting {
                LabeledContent { ProgressView().controlSize(.small) } label: { Text("Checking the folder").labelColumn() }
            } else if let root = state.repositoryRoot {
                LabeledContent { EmptyView() } label: {
                    described("Repository root", abbreviate(root))
                }
                .help(root)
                if state.settings.barProblem(state.inspection ?? .noRepository) == .folderChanged {
                    Text("The bar folder was moved or replaced. Choose it again.").foregroundStyle(.orange)
                }
            } else if state.inspection == .noRepository {
                LabeledContent { EmptyView() } label: {
                    described("No repository found", "The folder is not in a Git repository.")
                }
                Picker(selection: $state.createRepository) {
                    Text("Yes, Create a Repository").tag(true)
                    Text("No, Stop Setup").tag(false)
                } label: {
                    described("Create a repository in this folder?", "Rounds runs git init here. It adds no remote and makes no commit.")
                }
                .pickerStyle(.radioGroup)
                if state.createRepository {
                    LabeledContent {
                        HStack {
                            TextField("", text: $state.repositoryName, prompt: Text("Bar"))
                            Button("Create…") { state.confirmCreate = true }
                                .disabled(state.repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } label: {
                        described("Bar name", "Saved in \(barFileName) in the folder.")
                    }
                }
            }
        } header: {
            step(2, "Review the repository")
        }
        .alert("Create a repository in this folder?", isPresented: $state.confirmCreate) {
            Button("Cancel", role: .cancel) {}
            Button("Create Repository") { state.create() }
        } message: {
            Text("Rounds runs git init in \(state.folder ?? "") and writes \(barFileName). It does not add a remote, commit or push.")
        }
    }

    private var remoteSection: some View {
        Section {
            if state.remotes.isEmpty {
                LabeledContent { EmptyView() } label: {
                    described("No remote configured", "Set up a remote separately. Rounds then asks you to acknowledge it.")
                }
            } else {
                ForEach(state.remotes, id: \.url) { remote in
                    LabeledContent {
                        Text("Not verified").foregroundStyle(.orange)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(remote.name)
                            Text(remote.displayURL).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .labelColumn()
                    }
                }
                Toggle("I understand these remotes may be public.",
                       isOn: Binding(get: { state.acknowledged }, set: { state.setAcknowledged($0) }))
                    .toggleStyle(.checkbox)
            }
        } header: {
            step(3, "Review remote visibility")
        } footer: {
            Text("Rounds does not ask the Git host, as that sends the remote address off this Mac. Visibility does not permit organization data. Each push needs your approval.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var detailSection: some View {
        Section {
            ForEach(organizations.policy.organizations) { organization in
                detailRow(organization.name, .organization(organization.id))
            }
            detailRow("Unclassified projects", .unclassified)
        } header: {
            step(4, "Choose where task details stay")
        } footer: {
            Text("Task details are not remotely backed up by the root repository.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func detailRow(_ name: String, _ scope: BarScope) -> some View {
        let path = state.detailPath(scope)
        let problem = state.detailProblem(scope)
        return VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Button(path == nil ? "Choose…" : "Change…") { state.chooseDetailFolder(scope) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(path.map { abbreviate($0) } ?? "No folder chosen.").font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path ?? "")
                }
                .labelColumn()
            }
            if let problem, problem != .notApproved || path != nil {
                Text(BarSettingsState.text(problem)).font(.callout).foregroundStyle(.orange)
            }
            if path != nil {
                Toggle("I confirm this folder is approved for task details of \(name).",
                       isOn: Binding(get: { problem == nil }, set: { state.setApproved($0, scope) }))
                    .toggleStyle(.checkbox)
                    .disabled(problem != nil && problem != .notApproved && problem != .replaced)
            }
        }
    }

    /// A plain header, as on the other pages. The first header after the page title needs a gap; see "Sounds".
    private func step(_ number: Int, _ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.primary).padding(.top, number == 1 ? 12 : 0)
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

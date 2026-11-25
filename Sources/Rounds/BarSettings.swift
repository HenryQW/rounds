import AppKit
import Foundation
import Observation
import RoundsCore
import SwiftUI

/// The owner and the bar of each organization (spec 2.7.2), shown in Settings > Organizations. The store refuses
/// corrupt data; every change reloads it first.
@MainActor @Observable
final class BarSettingsState {
    static let shared = BarSettingsState()
    private let directory: URL
    var store: BarSettingsStore { BarSettingsStore(url: directory.appending(path: "bar-settings.json")) }
    private(set) var settings = BarSettings()
    private(set) var loaded = false
    /// The settings file could not be read or written.
    var error: String?

    enum Check: Equatable { case checking, done(BarProblem?) }
    /// The last check of each organization's bar; the Bar row shows its problem.
    private(set) var checks: [UUID: Check] = [:]
    /// A chosen folder with no repository, until the user creates one or chooses again.
    private(set) var pendingFolders: [UUID: String] = [:]
    /// The error of the last action on an organization's rows.
    var rowErrors: [UUID: String] = [:]

    /// The organization whose owner the sheet edits, and the text in it.
    var ownerOrganization: OrganizationPolicy.Organization?
    var ownerText = ""
    var ownerError: String?
    /// The organization and bar name of the "Create a repository in this folder?" alert.
    var createOrganization: UUID?
    var repositoryName = ""
    var confirmCreate = false

    /// Tests pass their own folder.
    init(directory: URL = Demo.isOn
            ? FileManager.default.temporaryDirectory.appending(path: "rounds-demo-\(ProcessInfo.processInfo.processIdentifier)")
            : URL.applicationSupportDirectory.appending(path: "Rounds")) {
        self.directory = directory
        guard !Demo.isOn else {
            loaded = true
            return
        }
        reload()
        for id in settings.organizations.keys { check(id) }
    }

    /// The organizations whose bar is ready; nil while a check runs and none is ready yet.
    var readyBars: Set<UUID>? {
        let known = Set(OrganizationSettingsState.shared.policy.organizations.map(\.id))
        let ready = Set(checks.filter { known.contains($0.key) && $0.value == .done(nil) }.keys)
        if ready.isEmpty && checks.contains(where: { known.contains($0.key) && $0.value == .checking }) { return nil }
        return ready
    }

    // Fictional values for the Organizations demo; demo mode inspects, creates and saves nothing.
    private static let demo: [String: (owner: String, bar: String?)] = [
        "HenryQW": ("github.com/HenryQW", "/Users/demo/Bars/henryqw-bar"),
        "Evermark": ("github.com/Evermark", nil),
    ]

    func owner(for organization: OrganizationPolicy.Organization) -> String? {
        if Demo.isOn { return Self.demo[organization.name]?.owner }
        return settings.organizations[organization.id]?.owner?.description
    }

    func barPath(for organization: OrganizationPolicy.Organization) -> String? {
        if Demo.isOn { return Self.demo[organization.name]?.bar }
        return pendingFolders[organization.id] ?? settings.organizations[organization.id]?.bar?.path
    }

    /// The problem the Bar row shows. Nil while the check runs, when the bar is ready, and when no bar is set.
    func problem(for organization: OrganizationPolicy.Organization) -> String? {
        let id = organization.id
        if Demo.isOn { return nil }
        if let error = rowErrors[id] { return error }
        if pendingFolders[id] != nil { return "No repository found. The folder is not in a Git repository." }
        guard case .done(let problem?) = checks[id], problem != .noBar, problem != .noOwner || barPath(for: organization) != nil else {
            return nil
        }
        return problem.message
    }

    func reload() {
        do {
            settings = try store.load()
            loaded = true
            error = nil
        } catch {
            loaded = false
            self.error = "Could not read bar settings. Tasks cannot be stored until the file is repaired or removed: \(store.url.path)"
        }
    }

    /// Checks the recorded bar off the main thread. A change during the check checks again, as `refresh` skips a
    /// row that is checking.
    func check(_ organization: UUID) {
        guard !Demo.isOn else { return }
        let settings = settings
        guard let bar = settings.organizations[organization]?.bar else {
            checks[organization] = .done(settings.barProblem(for: organization, inspection: .noRepository))
            return
        }
        checks[organization] = .checking
        Task {
            let problem = await Task.detached { () -> BarProblem? in
                do { return settings.barProblem(for: organization, inspection: try inspectBarFolder(bar.path)) }
                catch { return .inspectionFailed }
            }.value
            guard self.settings == settings else { return check(organization) }
            checks[organization] = .done(problem)
        }
    }

    /// Remotes can change while Settings is closed; check every bar again when the page opens.
    func refresh() {
        guard !Demo.isOn else { return }
        reload()
        for id in settings.organizations.keys where checks[id] != .checking { check(id) }
    }

    func editOwner(_ organization: OrganizationPolicy.Organization) {
        ownerText = owner(for: organization) ?? ""
        ownerError = nil
        ownerOrganization = organization
    }

    /// An empty text removes the owner. Returns false when the text is not a host and one account name.
    func saveOwner() -> Bool {
        guard let organization = ownerOrganization else { return true }
        let text = ownerText.trimmingCharacters(in: .whitespaces)
        let owner = RemoteOwner(text)
        guard text.isEmpty || owner != nil else {
            ownerError = "Enter a host and one account name, such as github.com/HenryQW. Do not add a scheme or a path."
            return false
        }
        if change(organization.id, { $0.setOwner(owner, for: organization.id) }) { check(organization.id) }
        ownerOrganization = nil
        return true
    }

    /// The repository root must be the chosen folder. A folder with no repository waits for Create Repository….
    func chooseBar(for organization: UUID, projectFolders: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard !Demo.isOn, panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        (rowErrors[organization], pendingFolders[organization]) = (nil, nil)
        checks[organization] = .checking
        Task {
            let result = await Task.detached { Result(catching: { try inspectBarFolder(path) }) }.value
            switch result {
            case .success(.noRepository):
                pendingFolders[organization] = path
                check(organization)
            case .success(.repository(let root, _)):
                guard FolderIdentity.current(root) == FolderIdentity.current(path) else {
                    rowErrors[organization] = "The folder is in the repository at \(abbreviate(root)). Choose the repository root."
                    return check(organization)
                }
                adopt(root, for: organization, projectFolders: projectFolders)
            case .failure(let failure):
                rowErrors[organization] = "Could not check the folder: \(message(failure))"
                check(organization)
            }
        }
    }

    func askCreate(for organization: UUID) {
        // The folder name is a first suggestion for the bar name.
        repositoryName = pendingFolders[organization].map { ($0 as NSString).lastPathComponent } ?? ""
        createOrganization = organization
        confirmCreate = true
    }

    /// Called after the user confirms the alert.
    func create(projectFolders: [String]) {
        guard let organization = createOrganization, let folder = pendingFolders[organization], !Demo.isOn else { return }
        let name = repositoryName
        Task {
            let result = await Task.detached { Result(catching: { try createBarRepository(in: folder, name: name) }) }.value
            switch result {
            case .success:
                repositoryName = ""
                pendingFolders[organization] = nil
                adopt(folder, for: organization, projectFolders: projectFolders)
            case .failure(let failure):
                rowErrors[organization] = "Could not create the repository: \(message(failure))"
            }
        }
    }

    private func adopt(_ root: String, for organization: UUID, projectFolders: [String]) {
        change(organization) { try $0.setBar(root, for: organization, projectFolders: projectFolders) }
        check(organization)
    }

    @discardableResult
    private func change(_ organization: UUID, _ edit: (inout BarSettings) throws -> Void) -> Bool {
        guard !Demo.isOn else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            settings = try store.update(edit)
            loaded = true
            error = nil
            return true
        } catch {
            reload()
            if loaded { rowErrors[organization] = message(error) }
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
        case .barInProject(let project):
            "A bar must be outside every project folder. This folder is, is in or holds \(abbreviate(project))."
        case .barShared(let other):
            "\(OrganizationSettingsState.shared.policy.organizations.first { $0.id == other }?.name ?? "Another organization") uses this folder as its bar. Each organization needs its own bar."
        case .changedOnDisk: "The bar settings changed. Try again."
        default: error.localizedDescription
        }
    }
}

func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

/// The Owner and Bar rows at the top of an organization's group (spec 5.4).
struct OrganizationBarRows: View {
    let organization: OrganizationPolicy.Organization
    let projectFolders: [String]
    @Bindable private var state = BarSettingsState.shared

    var body: some View {
        let owner = state.owner(for: organization)
        let path = state.barPath(for: organization)
        VStack(alignment: .leading, spacing: 8) {
            // Outside a Form, LabeledContent does not push its control to the trailing edge.
            HStack {
                described("Owner", owner ?? "Not set")
                Spacer()
                Button("Change…") { state.editOwner(organization) }
            }
            HStack {
                described("Bar", path.map(abbreviate) ?? "Not set").help(path ?? "")
                Spacer()
                if state.pendingFolders[organization.id] != nil {
                    Button("Create Repository…") { state.askCreate(for: organization.id) }
                }
                Button("Choose…") { state.chooseBar(for: organization.id, projectFolders: projectFolders) }
            }
            if state.checks[organization.id] == .checking {
                ProgressView().controlSize(.small)
            } else if let problem = state.problem(for: organization) {
                Text(problem).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("Private repository. Pushes go only to \(owner ?? "the owner").")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

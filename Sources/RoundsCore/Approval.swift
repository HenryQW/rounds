import CryptoKit
import Foundation

public enum ApprovalDecision: Codable, Equatable, Sendable { case approved, rejected(reason: String) }

public struct ApprovalDraft: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let contentID: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
        self.contentID = Self.identity(title, body)
    }

    fileprivate var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && contentID == Self.identity(title, body)
    }

    private static func identity(_ title: String, _ body: String) -> String {
        approvalDigest(Data("\(title.utf8.count):\(title)\(body)".utf8))
    }
}

public enum ApprovalIntent: Codable, Equatable, Sendable {
    case push(sourceRef: String, revision: String, remote: String, urls: [String], destinationRef: String)
    case draftPullRequest(repository: String, baseRef: String, headRef: String, revision: String, draft: ApprovalDraft)

    var display: String {
        switch self {
        case let .push(source, revision, remote, urls, destination):
            "Push \(source) at \(revision) to \(remote) (\(urls.joined(separator: ", "))), reference \(destination)."
        case let .draftPullRequest(repository, base, head, revision, draft):
            "Open a draft pull request in \(repository) from \(head) at \(revision) into \(base).\n\(draft.title)\n\(draft.body)"
        }
    }
}

public struct ApprovalAction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let intent: ApprovalIntent

    public init(id: UUID = UUID(), intent: ApprovalIntent) {
        self.id = id
        self.intent = intent
    }
}

public struct ApprovalSnapshot: Codable, Equatable, Sendable {
    struct Remote: Codable, Equatable, Sendable {
        let name: String
        let fetch: [String]
        let push: [String]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && sameDestinationBytes(lhs.fetch, rhs.fetch) && sameDestinationBytes(lhs.push, rhs.push)
        }
    }

    struct Override: Codable, Equatable, Sendable {
        let key: String
        let value: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value.utf8.elementsEqual(rhs.value.utf8)
        }
    }

    public let folder: FolderIdentity
    public let sourceRef: String
    public let revision: String
    // A tag can point to the same commit through a different object. Older snapshots omit this field.
    let annotatedSourceObject: String?
    public var pushRevision: String { annotatedSourceObject ?? revision }
    public let remote: String
    public var pushURLs: [String] { remotes.first { $0.name == remote }?.push ?? [] }
    let remotes: [Remote]
    let overrides: [Override]
    // Older snapshots omit the digest. A fresh SSH snapshot will differ on recheck.
    let sshLoginDigest: String?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.folder == rhs.folder && lhs.folder.path.utf8.elementsEqual(rhs.folder.path.utf8) &&
            lhs.sourceRef.utf8.elementsEqual(rhs.sourceRef.utf8) && lhs.revision == rhs.revision &&
            lhs.annotatedSourceObject == rhs.annotatedSourceObject && lhs.remote == rhs.remote &&
            lhs.remotes == rhs.remotes && lhs.overrides == rhs.overrides && lhs.sshLoginDigest == rhs.sshLoginDigest
    }
}

private func sameDestinationBytes(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in left.utf8.elementsEqual(right.utf8) }
}

public struct ApprovalHarnessBinding: Codable, Equatable, Sendable {
    public let taskID: Int
    public let conversationID: Int
    public let callID: String

    public init(taskID: Int, conversationID: Int, callID: String) {
        (self.taskID, self.conversationID, self.callID) = (taskID, conversationID, callID)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.taskID == rhs.taskID && lhs.conversationID == rhs.conversationID && lhs.callID.utf8.elementsEqual(rhs.callID.utf8)
    }

    fileprivate var isValid: Bool {
        let maximumSafeInteger = 9_007_199_254_740_991
        return (1...maximumSafeInteger).contains(taskID) && (1...maximumSafeInteger).contains(conversationID) &&
            !callID.isEmpty && callID.utf8.count <= 1024 && !callID.utf8.contains(0)
    }
}

public struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let repositoryID: UUID
    public let organizationID: UUID?
    public let resultRevisionID: UUID
    let resultDigest: String
    public let snapshot: ApprovalSnapshot
    public let actions: [ApprovalAction]
    public let createdAt: Date
    public let checkedAt: Date
    public let harnessBinding: ApprovalHarnessBinding?

    func validate(taskID: UUID) throws {
        let remoteNames = snapshot.remotes.map(\.name)
        guard self.taskID == taskID, !actions.isEmpty, Set(actions.map(\.id)).count == actions.count,
              checkedAt >= createdAt, resultDigest.utf8.count == 64, harnessBinding?.isValid != false,
              snapshot.folder.path.hasPrefix("/"), !snapshot.folder.path.utf8.contains(0),
              validApprovalRef(snapshot.sourceRef), validApprovalRevision(snapshot.revision),
              snapshot.annotatedSourceObject.map({ validApprovalRevision($0) && $0 != snapshot.revision }) != false,
              snapshot.sshLoginDigest.map({ $0.utf8.count == 64 && validApprovalRevision($0) }) != false,
              !snapshot.pushURLs.isEmpty, remoteNames == Set(remoteNames).sorted(),
              snapshot.remotes.allSatisfy({ remote in
                  validApprovalRemoteName(remote.name) && !remote.fetch.isEmpty && !remote.push.isEmpty &&
                      (remote.fetch + remote.push).allSatisfy(isStoredApprovalDestination)
              }), snapshot.overrides.allSatisfy({ override in
                  override.value == "." || remoteNames.contains(override.value) || isStoredApprovalDestination(override.value)
              }) else {
            throw ApprovalError.invalidRequest
        }
        let resultHeads = [snapshot.sourceRef] + actions.compactMap { action -> String? in
            guard case .push(_, _, _, _, let target) = action.intent else { return nil }
            return target
        }
        for action in actions {
            switch action.intent {
            case let .push(source, revision, remote, urls, destination):
                guard source.utf8.elementsEqual(snapshot.sourceRef.utf8), revision == snapshot.pushRevision,
                      remote == snapshot.remote, sameDestinationBytes(urls, snapshot.pushURLs),
                      validApprovalRef(destination) else { throw ApprovalError.invalidRequest }
            case let .draftPullRequest(repository, base, head, revision, draft):
                // The provider repository is a name, with no URL, user information or query.
                let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count >= 3, parts[0].contains("."), parts.allSatisfy(validApprovalRepositoryPart),
                      resultHeads.contains(where: { $0.utf8.elementsEqual(head.utf8) }), !base.utf8.elementsEqual(head.utf8),
                      base.hasPrefix("refs/heads/"), head.hasPrefix("refs/heads/"),
                      validApprovalRef(base), validApprovalRef(head), revision == snapshot.revision,
                      draft.isValid else { throw ApprovalError.invalidRequest }
                try checkApprovalText(draft.title)
                try checkApprovalText(draft.body)
            }
        }
    }
}

public struct ApprovalAnswer: Codable, Equatable, Sendable {
    public enum Actor: String, Codable, Sendable { case user }

    public let requestID: UUID
    public let decision: ApprovalDecision
    public let actor: Actor
    public let answeredAt: Date
}

enum ApprovalExecution: String, Codable, Sendable { case started, completed }

public struct ApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { request.id }
    public let request: ApprovalRequest
    public internal(set) var answer: ApprovalAnswer?
    public internal(set) var invalidatedAt: Date?
    // An absent journal is valid for records saved before action execution.
    var execution: [ApprovalExecution]?

    static func validate(_ records: [Self], taskID: UUID) throws {
        guard Set(records.map(\.id)).count == records.count,
              records.dropLast().allSatisfy({ $0.invalidatedAt != nil }) else { throw ApprovalError.invalidRequest }
        for record in records {
            try record.request.validate(taskID: taskID)
            if let answer = record.answer {
                guard answer.requestID == record.id, answer.answeredAt >= record.request.checkedAt,
                      try answer.decision.normalized() == answer.decision else { throw ApprovalError.invalidRequest }
            }
            if let invalidatedAt = record.invalidatedAt, invalidatedAt < (record.answer?.answeredAt ?? record.request.checkedAt) {
                throw ApprovalError.invalidRequest
            }
            if let execution = record.execution {
                guard record.answer?.decision == .approved, !execution.isEmpty, execution.count <= record.request.actions.count,
                      execution.dropLast().allSatisfy({ $0 == .completed }) else {
                    throw ApprovalError.invalidRequest
                }
            }
        }
    }

    mutating func invalidate(at time: Date) {
        guard invalidatedAt == nil else { return }
        invalidatedAt = max(time, answer?.answeredAt ?? request.checkedAt)
    }
}

public enum ApprovalError: LocalizedError, Equatable {
    case invalidRequest, resultMismatch, unknownRequest, alreadyAnswered, stale, snapshotUnavailable, needsInspection
    case userAnswerNotAuthorized, credentialAddressInText
    case actionNotApproved, executionUncertain, boundTaskUnverified

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The local approval request is invalid."
        case .resultMismatch: "The local approval request does not match the saved result."
        case .unknownRequest: "Rounds could not find this local approval request."
        case .alreadyAnswered: "Rounds already saved a decision for this request."
        case .stale: "This request is out of date. Check the result and create a new request."
        case .snapshotUnavailable: "Rounds could not verify the local source reference or Git destinations."
        case .needsInspection: "Check local task storage before saving another decision."
        case .userAnswerNotAuthorized: "Only a response from the approval card can save a decision."
        case .credentialAddressInText: "Remove the address with sign-in details before saving."
        case .actionNotApproved: "Rounds could not verify approval for this action."
        case .executionUncertain: "Check the outcome of the previous action before publishing again."
        case .boundTaskUnverified: "Rounds could not verify the Harness task for this approval."
        }
    }
}

extension ApprovalDecision {
    func normalized() throws -> Self {
        guard case .rejected(let reason) = self else { return self }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BouncerError.reasonRequired }
        try checkApprovalText(trimmed)
        return .rejected(reason: trimmed)
    }
}

private func isStoredApprovalDestination(_ value: String) -> Bool {
    approvalDestination(value)?.url.utf8.elementsEqual(value.utf8) == true
}

// Catch user information in common web addresses and explicit passwords in Git transport addresses.
// Free text can still contain secrets in other forms.
private func checkApprovalText(_ text: String) throws {
    let credentialAddress = #/(?i)\b(?:(?:https?|ftps?)://[^/\s?#@]+|(?:ssh|git(?:\+ssh)?|ssh\+git)://[^/\s?#@:]*:[^/\s?#@]*)@/#
    guard !text.contains("://") || text.firstMatch(of: credentialAddress) == nil else {
        throw ApprovalError.credentialAddressInText
    }
}

func approvalResultDigest(_ result: TaskResult) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return approvalDigest(try encoder.encode(result))
}

func approvalDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func validApprovalRevision(_ value: String) -> Bool {
    [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

func validApprovalRef(_ ref: String) -> Bool {
    ref.hasPrefix("refs/") && !ref.contains("..") && !ref.contains("@{") && !ref.hasSuffix(".") &&
        ref.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        } && !ref.utf8.contains { $0 <= 32 || $0 == 127 || "~^:?*[\\".utf8.contains($0) }
}

func validApprovalRemoteName(_ name: String) -> Bool {
    name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy(validApprovalRepositoryPart)
}

private func validApprovalRepositoryPart(_ part: Substring) -> Bool {
    !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "._-".utf8.contains($0)
    }
}

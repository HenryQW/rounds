import CryptoKit
import Foundation

/// A visible destination and an opaque identity for its exact current configuration.
struct OrganizationDestination: Identifiable, Equatable, Sendable {
    let service: String
    let identity: String
    let title: String
    let detail: String
    var id: String { service + ":" + identity }
}

/// The digest is used only to detect destination changes. Credential values never enter the policy file or UI.
func makeOrganizationDestination(service: String, fields: [String: String], title: String, detail: String) -> OrganizationDestination? {
    guard !fields.isEmpty, fields.values.allSatisfy({ !$0.isEmpty }) else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(DestinationIdentity(service: service, fields: fields)) else { return nil }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return OrganizationDestination(service: service, identity: "sha256:" + digest, title: title, detail: detail + " · " + digest.prefix(12))
}

/// Encodes the service and its fields without ambiguous string concatenation.
private struct DestinationIdentity: Encodable {
    let service: String
    let fields: [String: String]
}

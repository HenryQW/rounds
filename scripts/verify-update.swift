// Checks a Sparkle update before the release workflow publishes it (spec 5.8), as each installed copy will: the EdDSA
// signature in the appcast against the zip and the app's SUPublicEDKey, the zip's length, and the appcast version
// against the app's CFBundleVersion. A wrong or missing key would strand every installed copy, so a mismatch fails.
// Usage: swift scripts/verify-update.swift <Rounds.app> <zip> <appcast.xml>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-update: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: verify-update.swift <Rounds.app> <zip> <appcast.xml>") }
let info = NSDictionary(contentsOf: URL(fileURLWithPath: args[1]).appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
guard let key = (info["SUPublicEDKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { fail("no valid SUPublicEDKey in the app") }
guard let zip = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
guard let appcast = try? XMLDocument(contentsOf: URL(fileURLWithPath: args[3])),
      let item = try? appcast.nodes(forXPath: "//item").first as? XMLElement,
      let enclosure = item.elements(forName: "enclosure").first else { fail("no item with an enclosure in the appcast") }
let ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
guard let signature = enclosure.attribute(forLocalName: "edSignature", uri: ns)?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
    fail("no sparkle:edSignature on the enclosure")
}
guard publicKey.isValidSignature(signature, for: zip) else { fail("the signature does not match SUPublicEDKey") }
guard enclosure.attribute(forName: "length")?.stringValue == String(zip.count) else { fail("the enclosure length is not the zip's size") }
let version = item.elements(forLocalName: "version", uri: ns).first?.stringValue
guard version == info["CFBundleVersion"] as? String else { fail("sparkle:version \(version ?? "none") is not the app's CFBundleVersion") }
print("verify-update: the update is signed with SUPublicEDKey, version \(version ?? "")")

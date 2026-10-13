import CryptoKit
import Foundation

// Public-key verification only: checking a release must never require access to its private key.
// The signed footer format comes from Sparkle's common_cli/Signing.swift.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fail("Usage: verify-appcast.swift appcast.xml archive.dmg Info.plist") }
do {
    let feed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])), format: nil) as! [String: Any]
    guard let encodedKey = info["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: encodedKey) else { fail("Missing public update key") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard let marker = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
          let footer = String(data: feed[marker.upperBound...], encoding: .utf8) else { fail("Missing signed feed footer") }
    let fields = footer.components(separatedBy: "\n")
    guard fields.count == 4, fields[0].hasPrefix("edSignature: "), fields[1].hasPrefix("length: "), fields[2] == "-->", fields[3].isEmpty,
          let signature = Data(base64Encoded: String(fields[0].dropFirst("edSignature: ".count))),
          let length = Int(fields[1].dropFirst("length: ".count)), length == marker.lowerBound else { fail("Invalid signed feed footer") }
    let content = feed.prefix(length)
    guard key.isValidSignature(signature, for: content) else { fail("Invalid appcast signature") }
    let xml = try XMLDocument(data: content, options: .nodeLoadExternalEntitiesNever)
    let enclosures = try xml.nodes(forXPath: "/rss/channel/item/enclosure").compactMap { $0 as? XMLElement }
    guard let enclosure = enclosures.first(where: { URL(string: $0.attribute(forName: "url")?.stringValue ?? "")?.lastPathComponent == archiveURL.lastPathComponent }),
          let encodedSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
          let archiveSignature = Data(base64Encoded: encodedSignature),
          let encodedLength = enclosure.attribute(forName: "length")?.stringValue, let archiveLength = Int(encodedLength) else { fail("Missing signed archive enclosure") }
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    guard archive.count == archiveLength, key.isValidSignature(archiveSignature, for: archive) else { fail("Invalid update archive signature or length") }
    print("Verified appcast and update archive using SUPublicEDKey")
} catch {
    fail("Release verification failed: \(error)")
}

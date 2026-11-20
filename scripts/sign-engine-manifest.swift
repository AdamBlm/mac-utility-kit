import CryptoKit
import Foundation

struct Envelope: Encodable {
    let payload: Data
    let signature: Data
}

if CommandLine.arguments.dropFirst().elementsEqual(["--generate-key"]) {
    let key = Curve25519.Signing.PrivateKey()
    print("Private key (store securely): \(key.rawRepresentation.base64EncodedString())")
    print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
} else {
    guard CommandLine.arguments.count == 3,
          let key = ProcessInfo.processInfo.environment["MUK_VIDEO_ENGINE_SIGNING_KEY"].flatMap({ Data(base64Encoded: $0) }) else {
        FileHandle.standardError.write(Data("Provide an input, output, and MUK_VIDEO_ENGINE_SIGNING_KEY.\n".utf8))
        exit(2)
    }
    let payload = try Data(contentsOf: URL(filePath: CommandLine.arguments[1]))
    let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: key)
    let envelope = try Envelope(payload: payload, signature: signer.signature(for: payload))
    try JSONEncoder().encode(envelope).write(to: URL(filePath: CommandLine.arguments[2]), options: .atomic)
}

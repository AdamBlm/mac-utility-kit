import CryptoKit
import Foundation
import Testing
@testable import UtilityCore

struct ManagedVideoEnginesTests {
    @Test func verifiesUpdatesAndPreservesAnInstalledSetAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = URL(string: "https://example.test/manifest.json")!
        let key = Curve25519.Signing.PrivateKey()
        let fixture = EngineFeedFixture(key: key)
        let manager = try VideoEngineManager(root: root, feed: feed, publicKey: key.publicKey.rawRepresentation) {
            try await fixture.download($0)
        }
        #expect(try await manager.installed() == nil)
        let first = try await manager.install()
        #expect(first.revision == 1)

        await fixture.set(revision: 2, badSignature: true)
        await #expect(throws: ToolError.self) { _ = try await manager.install() }
        #expect(try await manager.installed()?.revision == 1)

        await fixture.set(revision: 2, corruptArtifact: true)
        await #expect(throws: ToolError.self) { _ = try await manager.install() }
        #expect(try await manager.installed()?.revision == 1)

        await fixture.set(revision: 2)
        let second = try await manager.install()
        #expect(second.revision == 2)
        #expect(first.directory != second.directory)
        #expect(FileManager.default.isExecutableFile(atPath: first.ffmpeg.path))

        try await manager.rollback()
        #expect(try await manager.installed()?.revision == 1)
        await fixture.set(revision: 1)
        await #expect(throws: ToolError.self) { _ = try await manager.install() }
        try await manager.remove()
        #expect(try await manager.installed() == nil)
        #expect(FileManager.default.isExecutableFile(atPath: second.deno.path))
    }

    @Test func cancelledFirstInstallDoesNotPublishOrLeaveStagedExecutables() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let fixture = EngineFeedFixture(key: key)
        let feed = URL(string: "https://example.test/manifest.json")!
        let manager = try VideoEngineManager(root: root, feed: feed, publicKey: key.publicKey.rawRepresentation) {
            try await fixture.download($0)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await Task {
                try await manager.install { _, completed, _, _ in
                    if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }.value
        }
        #expect(try await manager.installed() == nil)
        let installedFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(installedFiles.filter { !$0.hasPrefix(".") }.isEmpty)
    }
}

private actor EngineFeedFixture {
    let key: Curve25519.Signing.PrivateKey
    var revision = 1
    var badSignature = false
    var corruptArtifact = false
    private let executable = Data("#!/bin/sh\nexit 0\n".utf8)

    init(key: Curve25519.Signing.PrivateKey) { self.key = key }

    func set(revision: Int, badSignature: Bool = false, corruptArtifact: Bool = false) {
        self.revision = revision
        self.badSignature = badSignature
        self.corruptArtifact = corruptArtifact
    }

    func download(_ url: URL) throws -> (URL, URLResponse) {
        let body: Data
        if url.lastPathComponent == "manifest.json" {
            let hash = SHA256.hash(data: executable).map { String(format: "%02x", $0) }.joined()
            let artifacts: [[String: Any]] = ["yt-dlp", "deno", "ffmpeg", "ffprobe"].map { name in
                [
                    "name": name, "version": "fixture", "url": "https://example.test/\(name)",
                    "minimumMacOS": 15, "bytes": executable.count, "sha256": hash,
                    "notices": "https://example.test/notices", "source": "https://example.test/source",
                ]
            }
            let payload = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "revision": revision, "platforms": ["arm64": artifacts, "x86_64": artifacts],
            ])
            let signer = badSignature ? Curve25519.Signing.PrivateKey() : key
            body = try JSONSerialization.data(withJSONObject: [
                "payload": payload.base64EncodedString(),
                "signature": try signer.signature(for: payload).base64EncodedString(),
            ])
        } else {
            body = corruptArtifact ? Data(repeating: 0, count: executable.count) : executable
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

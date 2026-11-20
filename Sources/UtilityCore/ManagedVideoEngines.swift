import CryptoKit
import Darwin
import Foundation
import Synchronization

package struct ManagedVideoEngines: Sendable {
    let lease: VideoEngineLease
    package var directory: URL { lease.directory }
    package let revision: Int
    package let versions: [String: String]
    package let notices: [String: URL]
    package let sources: [String: URL]

    package var downloader: URL { directory.appendingPathComponent("yt-dlp") }
    package var ffmpeg: URL { directory.appendingPathComponent("ffmpeg") }
    package var deno: URL { directory.appendingPathComponent("deno") }
}

final class VideoEngineLease: Sendable {
    let directory: URL
    private let retired = Mutex(false)

    private let lock: FileHandle

    init?(directory: URL) {
        self.directory = directory
        guard let lock = try? FileHandle(forReadingFrom: directory.appendingPathComponent(".in-use")),
              flock(lock.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else { return nil }
        self.lock = lock
    }

    func retire() { retired.withLock { $0 = true } }

    deinit {
        flock(lock.fileDescriptor, LOCK_UN)
        if retired.withLock({ $0 }), flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private final class EngineDownloadLimits: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > 250_000_000 { downloadTask.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

package actor VideoEngineManager {
    private struct Envelope: Decodable {
        let payload: Data
        let signature: Data
    }

    private struct Manifest: Decodable {
        let schema: Int
        let revision: Int
        let platforms: [String: [Artifact]]
    }

    private struct Artifact: Decodable {
        let name: String
        let version: String
        let url: URL
        let notices: URL
        let source: URL?
        let minimumMacOS: Int
        let bytes: Int
        let sha256: String
    }

    private struct Installation: Codable {
        let directory: UUID
        let revision: Int
        let versions: [String: String]
        let notices: [String: URL]
        let sources: [String: URL]
    }

    private struct State: Codable {
        var highestRevision = 0
        var current: Installation?
        var previous: Installation?
    }

    private static let tools = ["yt-dlp", "deno", "ffmpeg", "ffprobe"]
    private let root: URL
    private let feed: URL
    private let publicKey: Curve25519.Signing.PublicKey
    private var busy = false
    private var leases: [UUID: VideoEngineLease] = [:]
    private let download: @Sendable (URL) async throws -> (URL, URLResponse)

    package init(
        root: URL, feed: URL, publicKey: Data,
        download: (@Sendable (URL) async throws -> (URL, URLResponse))? = nil
    ) throws {
        guard Self.isHTTPS(feed) else { throw ToolError.invalid("The engine feed requires HTTPS.") }
        self.root = root
        self.feed = feed
        self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: EngineDownloadLimits(), delegateQueue: nil)
        self.download = download ?? { try await session.download(from: $0) }
    }

    package func installed() throws -> ManagedVideoEngines? {
        let state = try readState()
        leases = leases.filter { id, _ in id == state.current?.directory || id == state.previous?.directory }
        return engineSet(state.current)
    }

    package func install(
        repair: Bool = false,
        progress: @Sendable (String, Int, Int, Int) async -> Void = { _, _, _, _ in }
    ) async throws -> ManagedVideoEngines {
        guard !busy else { throw ToolError.invalid("A Video Tools installation is already in progress.") }
        busy = true
        defer { busy = false }
        let lock = try lockStore()
        defer { try? lock.close() }
        try Task.checkCancellation()
        var state = try readState()
        let (file, response) = try await download(feed)
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.verifyResponse(response)
        guard (1...128 * 1024).contains(try Self.fileSize(file)) else {
            throw ToolError.invalid("The engine manifest is too large.")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        guard publicKey.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw ToolError.invalid("The engine manifest signature is invalid.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard manifest.schema == 1, manifest.revision > 0, manifest.revision >= state.highestRevision,
              let artifacts = manifest.platforms[architecture],
              artifacts.count == Self.tools.count, Set(artifacts.map(\.name)) == Set(Self.tools),
              artifacts.allSatisfy({ Self.isHTTPS($0.url) && (1...250_000_000).contains($0.bytes)
                  && (15...ProcessInfo.processInfo.operatingSystemVersion.majorVersion).contains($0.minimumMacOS)
                  && Self.isHTTPS($0.notices) && ($0.source.map(Self.isHTTPS) ?? !$0.name.hasPrefix("ff"))
                  && $0.sha256.utf8.count == 64 && !$0.version.isEmpty }),
              artifacts.first(where: { $0.name == "ffmpeg" })?.version
                == artifacts.first(where: { $0.name == "ffprobe" })?.version else {
            throw ToolError.invalid("The engine manifest is incompatible with this Mac or has been superseded.")
        }
        if !repair, let current = engineSet(state.current), current.revision == manifest.revision { return current }

        let installation = Installation(directory: UUID(), revision: manifest.revision,
                                        versions: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.version) }),
                                        notices: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.notices) }),
                                        sources: Dictionary(uniqueKeysWithValues: artifacts.compactMap { item in
                                            item.source.map { (item.name, $0) }
                                        }))
        let directory = root.appendingPathComponent(installation.directory.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var activated = false
        defer {
            if !activated {
                leases.removeValue(forKey: installation.directory)?.retire()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try Data().write(to: directory.appendingPathComponent(".in-use"))
        let totalBytes = artifacts.reduce(0) { $0 + $1.bytes }
        for (index, artifact) in artifacts.enumerated() {
            try Task.checkCancellation()
            await progress(artifact.name, index, artifacts.count, totalBytes)
            try Task.checkCancellation()
            try await stage(artifact, in: directory)
        }
        try Task.checkCancellation()
        guard let engines = engineSet(installation) else {
            throw ToolError.invalid("Video Tools installation is incomplete.")
        }
        _ = engineSet(state.previous)
        if engineSet(state.current) != nil { state.previous = state.current }
        state.current = installation
        state.highestRevision = manifest.revision
        try writeState(state)
        activated = true
        retireUnused(keeping: state)
        return engines
    }

    package func rollback() throws {
        guard !busy else { throw ToolError.invalid("Wait for the current installation to finish.") }
        let lock = try lockStore()
        defer { try? lock.close() }
        var state = try readState()
        guard engineSet(state.previous) != nil else { throw ToolError.invalid("There is no previous Video Tools installation.") }
        swap(&state.current, &state.previous)
        try writeState(state)
    }

    package func remove() throws {
        guard !busy else { throw ToolError.invalid("Wait for the current installation to finish.") }
        let lock = try lockStore()
        defer { try? lock.close() }
        var state = try readState()
        _ = engineSet(state.current)
        _ = engineSet(state.previous)
        state.current = nil
        state.previous = nil
        try writeState(state)
        retireUnused(keeping: state)
    }

    private func lockStore() throws -> FileHandle {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".store-lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ToolError.invalid("The Video Tools store could not be opened.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ToolError.invalid("Video Tools are being changed by another copy of Mac Utility Kit.")
        }
        return handle
    }

    private func retireUnused(keeping state: State) {
        let keep = Set([state.current?.directory, state.previous?.directory].compactMap { $0 })
        for id in Set(leases.keys).subtracting(keep) {
            leases.removeValue(forKey: id)?.retire()
        }
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent), !keep.contains(id),
                  let lease = VideoEngineLease(directory: directory) else { continue }
            lease.retire()
        }
    }

    private func stage(_ artifact: Artifact, in directory: URL) async throws {
        let (file, response) = try await download(artifact.url)
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.verifyResponse(response)
        guard try Self.fileSize(file) == artifact.bytes else {
            throw ToolError.invalid("The downloaded \(artifact.name) has an unexpected size.")
        }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var hasher = SHA256()
        while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else {
            throw ToolError.invalid("The downloaded \(artifact.name) failed verification.")
        }
        let executable = directory.appendingPathComponent(artifact.name)
        try FileManager.default.moveItem(at: file, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let argument = artifact.name.hasPrefix("ff") ? "-version" : "--version"
        try await withThrowingTaskGroup(of: Void.self) { checks in
            checks.addTask {
                try await ExternalTool.run(executable, name: artifact.name, arguments: [argument], directory: directory)
            }
            checks.addTask {
                try await Task.sleep(for: .seconds(30))
                throw ToolError.invalid("\(artifact.name) did not pass its startup check in time.")
            }
            defer { checks.cancelAll() }
            _ = try await checks.next()
        }
    }

    private var stateURL: URL { root.appendingPathComponent("state.json") }

    private func readState() throws -> State {
        do {
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return State()
        }
    }

    private func writeState(_ state: State) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func engineSet(_ installation: Installation?) -> ManagedVideoEngines? {
        guard let installation else { return nil }
        let directory = root.appendingPathComponent(installation.directory.uuidString, isDirectory: true)
        guard let lease = leases[installation.directory] ?? VideoEngineLease(directory: directory),
              Self.tools.allSatisfy({ ExternalTool.isExecutable(directory.appendingPathComponent($0)) }) else { return nil }
        leases[installation.directory] = lease
        return ManagedVideoEngines(lease: lease, revision: installation.revision, versions: installation.versions,
                                   notices: installation.notices, sources: installation.sources)
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() != nil && url.user() == nil && url.password() == nil
    }

    private static func verifyResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, isHTTPS(url) else {
            throw ToolError.invalid("The engine server did not return a secure download.")
        }
    }

    private static func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
    }
}

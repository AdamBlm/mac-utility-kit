import CryptoKit
import Foundation

public enum HashAlgorithm: String, CaseIterable, Sendable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha384 = "SHA-384"
    case sha512 = "SHA-512"

    public var isLegacy: Bool { self == .md5 || self == .sha1 }

    public var hexLength: Int {
        switch self {
        case .md5: 32
        case .sha1: 40
        case .sha256: 64
        case .sha384: 96
        case .sha512: 128
        }
    }
}

public enum HashVerification: Equatable, Sendable {
    case match, mismatch, invalid
}

public enum HashGeneratorError: LocalizedError {
    case notLocalFile
    case notRegularFile
    case changedFile

    public var errorDescription: String? {
        switch self {
        case .notLocalFile: "Only local files can be hashed."
        case .notRegularFile: "Select a regular file to hash."
        case .changedFile: "The file changed while hashing. Rehash it after the changes are complete."
        }
    }
}

public enum HashGenerator {
    public static func text(_ text: String, algorithm: HashAlgorithm) async throws -> String {
        try await run {
            try Task.checkCancellation()
            let data = Data(text.utf8)
            return hexadecimal(calculate(algorithm) { $0(data) })
        }
    }

    public static func file(_ url: URL, algorithm: HashAlgorithm) async throws -> String {
        try await run {
            guard url.isFileURL else { throw HashGeneratorError.notLocalFile }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard let stamp = try DuplicateFileIO.inspect(resolved) else {
                throw HashGeneratorError.notRegularFile
            }
            let file = DuplicateFile(url: resolved, stamp: stamp)
            let digest = try calculate(algorithm) { update in
                try DuplicateFileIO.forEachVerifiedChunk(file, consume: update)
            }
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == resolved.path else {
                throw HashGeneratorError.changedFile
            }
            return hexadecimal(digest)
        }
    }

    public static func verify(_ digest: String, expected: String, algorithm: HashAlgorithm) -> HashVerification {
        let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.utf8.count == algorithm.hexLength,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return .invalid }
        return digest == expected ? .match : .mismatch
    }

    private static func run(_ operation: @escaping @Sendable () throws -> String) async throws -> String {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            let digest = try await work.value
            try Task.checkCancellation()
            return digest
        } onCancel: {
            work.cancel()
        }
    }

    private static func calculate(_ algorithm: HashAlgorithm, feed: ((Data) -> Void) throws -> Void) rethrows -> [UInt8] {
        switch algorithm {
        case .md5: try digest(Insecure.MD5(), feed: feed)
        case .sha1: try digest(Insecure.SHA1(), feed: feed)
        case .sha256: try digest(SHA256(), feed: feed)
        case .sha384: try digest(SHA384(), feed: feed)
        case .sha512: try digest(SHA512(), feed: feed)
        }
    }

    private static func digest<H: HashFunction>(_ initial: H, feed: ((Data) -> Void) throws -> Void) rethrows -> [UInt8] {
        var hasher = initial
        try feed { hasher.update(data: $0) }
        return Array(hasher.finalize())
    }

    private static func hexadecimal(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

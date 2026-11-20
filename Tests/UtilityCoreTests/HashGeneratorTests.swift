import Foundation
import Testing
@testable import UtilityCore

struct HashGeneratorTests {
    @Test(arguments: [
        (HashAlgorithm.md5, "900150983cd24fb0d6963f7d28e17f72"),
        (.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d"),
        (.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (.sha384, "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"),
        (.sha512, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    ])
    func publishedVectors(algorithm: HashAlgorithm, expected: String) async throws {
        let digest = try await HashGenerator.text("abc", algorithm: algorithm)
        #expect(digest == expected)
        #expect(HashGenerator.verify(digest, expected: " \(expected.uppercased())\n", algorithm: algorithm) == .match)
    }

    @Test
    func streamsBinaryFileAcrossChunkBoundaries() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 255, count: 2_100_003).write(to: file)
        #expect(try await HashGenerator.file(file, algorithm: .sha256)
            == "0c595b58c8be6c4dbc892791c7e0a456d226a119c29abb784273c0dc5b2a60b4")
    }

    @Test
    func refusesToFinalizeDigestAfterInPlaceEditDuringVerifiedRead() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let stamp = try #require(try DuplicateFileIO.inspect(file))
        let source = DuplicateFile(url: file, stamp: stamp)
        var didReadOriginal = false
        #expect(throws: DuplicateReadError.self) {
            try DuplicateFileIO.forEachVerifiedChunk(source) { data in
                didReadOriginal = data == Data("abc".utf8)
                let writing = try FileHandle(forWritingTo: file)
                defer { try? writing.close() }
                try writing.write(contentsOf: Data("different".utf8))
            }
        }
        #expect(didReadOriginal)
    }

    @Test
    func rehashesSymlinkAfterItsTargetChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "data")
        let link = directory.appending(path: "link")
        try Data("old".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let old = try await HashGenerator.file(link, algorithm: .sha384)
        try Data("new".utf8).write(to: file, options: .atomic)
        let new = try await HashGenerator.file(link, algorithm: .sha384)
        #expect(new != old)
        #expect(new == (try await HashGenerator.text("new", algorithm: .sha384)))
    }

    @Test
    func propagatesCancellation() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HashGenerator.file(file, algorithm: .sha256)
        }
        await #expect(throws: CancellationError.self) { _ = try await job.value }
    }

    @Test
    func reportsUnreadableFilesAndInvalidExpectedDigests() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        await #expect(throws: (any Error).self) {
            _ = try await HashGenerator.file(missing, algorithm: .sha256)
        }
        let actual = try await HashGenerator.text("", algorithm: .sha256)
        #expect(HashGenerator.verify(actual, expected: "nope", algorithm: .sha256) == .invalid)
        #expect(HashGenerator.verify(actual, expected: String(repeating: "0", count: 64), algorithm: .sha256) == .mismatch)
    }
}

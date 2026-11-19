import Foundation
import Synchronization
import Testing
@testable import UtilityCore

struct DiskSpeedTests {
    @Test func displaysIndividualPassesInMeasurementOrderAlongsideMedian() {
        let passes = [
            DiskSpeedResult.Pass(writeMegabytesPerSecond: 33.5, readMegabytesPerSecond: 104.5),
            .init(writeMegabytesPerSecond: 20, readMegabytesPerSecond: 110),
            .init(writeMegabytesPerSecond: 28, readMegabytesPerSecond: 90)
        ]
        let result = DiskSpeedResult(sizeMiB: 256, passes: passes, bypassedFileCache: true, fullFlush: true)
        #expect(result.writeMegabytesPerSecond == 28)
        #expect(result.readMegabytesPerSecond == 104.5)
        #expect(result.passDetails(locale: Locale(identifier: "en_US_POSIX")) == [
            "Pass 1 · Write 33.5 MB/s · Read 104.5 MB/s",
            "Pass 2 · Write 20.0 MB/s · Read 110.0 MB/s",
            "Pass 3 · Write 28.0 MB/s · Read 90.0 MB/s"
        ])
        let quick = DiskSpeedResult(sizeMiB: 256, passes: [passes[0]], bypassedFileCache: true, fullFlush: true)
        #expect(quick.passDetails().isEmpty)
    }

    @Test func refillsEntireChunkBeyondPreviousBufferExtentAndAcrossPasses() async throws {
        let temporary = try Self.folder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        var options = DiskSpeedOptions()
        options.sizeMiB = 17
        options.repeats = true
        let samples = Mutex<[UInt8]>([])
        let output = try await DiskSpeed.run(in: temporary, options: options, refill: { buffer, count in
            samples.withLock { values in
                #expect(count == 1_048_576)
                buffer.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: values.count), count: count)
                values.append(buffer.load(fromByteOffset: count - 1, as: UInt8.self))
            }
        }, progress: { _ in })
        #expect(output.passes.count == 3)
        #expect(samples.withLock { $0 } == (0..<51).map(UInt8.init))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    @Test func measuresRepeatedSequentialIOAndPreservesOtherFiles() async throws {
        let temporary = try Self.folder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let original = temporary.appending(path: "keep.txt")
        try Data("preserve".utf8).write(to: original)
        var options = DiskSpeedOptions()
        options.sizeMiB = 1
        options.repeats = true
        let output = try await DiskSpeed.run(in: temporary, options: options)
        #expect(output.passes.count == 3)
        #expect(output.writeMegabytesPerSecond.isFinite && output.writeMegabytesPerSecond > 0)
        #expect(output.readMegabytesPerSecond.isFinite && output.readMegabytesPerSecond > 0)
        #expect(output.readMegabytesPerSecond == output.passes.map(\.readMegabytesPerSecond).sorted()[1])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == ["keep.txt"])
        #expect(try Data(contentsOf: original) == Data("preserve".utf8))
    }

    @Test func cancellationLeavesNoScratchFile() async throws {
        let temporary = try Self.folder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        var options = DiskSpeedOptions()
        options.sizeMiB = 4
        let settings = options
        let task = Task {
            try await DiskSpeed.run(in: temporary, options: settings) { event in
                if event.phase == .write && event.fraction > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    @Test func detectsChangedFolderAndLeavesNoScratchFile() async throws {
        let parent = try Self.folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let temporary = parent.appending(path: "target")
        let moved = parent.appending(path: "moved")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        var options = DiskSpeedOptions()
        options.sizeMiB = 1
        await #expect(throws: ToolError.self) {
            try await DiskSpeed.run(in: temporary, options: options) { event in
                if event.phase == .read && event.fraction == 0 {
                    try? FileManager.default.moveItem(at: temporary, to: moved)
                }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}

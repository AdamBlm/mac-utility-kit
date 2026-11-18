import Foundation
import Testing
import UtilityCore

struct DiskSpeedTests {
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

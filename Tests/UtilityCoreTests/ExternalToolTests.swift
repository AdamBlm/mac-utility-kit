import Darwin
import Foundation
import Testing
@testable import UtilityCore

struct ExternalToolTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsAnEngineAndItsHelper() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appending(path: "ready")
        let clock = ContinuousClock()
        let script = """
        trap '' TERM
        /bin/sleep 120 &
        printf '%s %s\n' "$$" "$!" > ready.tmp
        /bin/mv ready.tmp ready
        wait
        """
        let task = Task {
            try await ExternalTool.run(
                URL(fileURLWithPath: "/bin/sh"), name: "Test engine",
                arguments: ["-c", script],
                directory: folder
            )
        }
        defer { task.cancel() }
        let startupDeadline = clock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: ready.path), clock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let processIDs = try String(contentsOf: ready, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        try #require(processIDs.count == 2)
        try #require(processIDs.allSatisfy { kill($0, 0) == 0 })

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let exitDeadline = clock.now.advanced(by: .seconds(2))
        while processIDs.contains(where: processExists), clock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!processIDs.contains(where: processExists))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["ready"])
    }

    private func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}

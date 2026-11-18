import Darwin
import Foundation
import Testing
@testable import UtilityCore

struct ExternalToolTests {
    @Test func cancellationStopsAnEngineThatIgnoresTermination() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appending(path: "ready")
        let clock = ContinuousClock()
        let task = Task {
            try await ExternalTool.run(
                URL(fileURLWithPath: "/bin/sh"), name: "Test engine",
                arguments: ["-c", "trap '' TERM; echo $$ > ready; exec /bin/sleep 10"],
                directory: folder
            )
        }
        defer { task.cancel() }
        let startupDeadline = clock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: ready.path), clock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let processID = try #require(pid_t(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        let cancelledAt = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(processID, 0) == -1 && errno == ESRCH)
        #expect(cancelledAt.duration(to: clock.now) < .seconds(4))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["ready"])
    }
}

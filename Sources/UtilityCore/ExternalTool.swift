import Foundation
import Subprocess
import System

enum ExternalTool {
    static func run(
        _ executable: URL, name: String, arguments: [String], directory: URL,
        standardOutput: FileHandle? = nil
    ) async throws {
        try Task.checkCancellation()
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolError.invalid("Choose an executable \(name) binary.")
        }
        let log = directory.appendingPathComponent(UUID().uuidString + ".log")
        try Data().write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let discardedOutput = standardOutput == nil ? try FileDescriptor.open("/dev/null", .writeOnly) : nil
        defer { try? discardedOutput?.close() }
        let output = standardOutput.map { FileDescriptor(rawValue: $0.fileDescriptor) } ?? discardedOutput
        guard let output else { throw ToolError.invalid("Could not configure \(name) output.") }

        var platform = PlatformOptions()
        platform.createSession = true
        // Cancelled jobs discard staging data. Signal the whole session's
        // process group before its leader can exit and leave helpers behind.
        platform.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
        let result = try await Subprocess.run(
            .path(FilePath(executable.path)), arguments: Arguments(arguments),
            workingDirectory: FilePath(directory.path), platformOptions: platform,
            input: .none, output: .fileDescriptor(output, closeAfterSpawningProcess: false),
            error: .fileDescriptor(FileDescriptor(rawValue: handle.fileDescriptor), closeAfterSpawningProcess: false)
        )
        try Task.checkCancellation()
        guard result.terminationStatus.isSuccess else {
            let tail = try FileHandle(forReadingFrom: log)
            defer { try? tail.close() }
            let length = try tail.seekToEnd()
            try tail.seek(toOffset: length > 2048 ? length - 2048 : 0)
            let message = String(decoding: try tail.readToEnd() ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard message.isEmpty else { throw ToolError.invalid(message) }
            switch result.terminationStatus {
            case .exited(let code): throw ToolError.invalid("\(name) exited with status \(code).")
            case .signaled(let signal): throw ToolError.invalid("\(name) stopped with signal \(signal).")
            }
        }
    }
}

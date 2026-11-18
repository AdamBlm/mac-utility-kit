import Foundation

enum ExternalTool {
    static func run(_ executable: URL, name: String, arguments: [String], directory: URL) async throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolError.invalid("Choose an executable \(name) binary.")
        }
        let log = directory.appendingPathComponent(UUID().uuidString + ".log")
        try Data().write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        try process.run()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(80))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            let tail = try FileHandle(forReadingFrom: log)
            defer { try? tail.close() }
            let length = try tail.seekToEnd()
            try tail.seek(toOffset: length > 2048 ? length - 2048 : 0)
            let message = String(decoding: try tail.readToEnd() ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError.invalid(message.isEmpty ? "\(name) exited with status \(process.terminationStatus)." : message)
        }
    }
}

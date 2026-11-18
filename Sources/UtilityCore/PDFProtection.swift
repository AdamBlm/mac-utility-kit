import Foundation
import PDFKit

public struct PDFProtectionOptions: Sendable {
    public var executable: URL?
    public var password = ""
    public var confirmation = ""
    public var ownerPassword = ""
    public var allowsPrinting = true
    public var allowsCopying = true

    public init() {}
}

public enum PDFProtection {
    public static func add(
        _ input: URL, to output: URL, options: PDFProtectionOptions
    ) async throws -> String {
        guard !options.password.isEmpty, options.password == options.confirmation else {
            throw ToolError.invalid("Enter and confirm the document password.")
        }
        try validatePassword(options.password)
        let owner = options.ownerPassword.isEmpty ? UUID().uuidString + UUID().uuidString : options.ownerPassword
        try validatePassword(owner)
        guard owner != options.password else {
            throw ToolError.invalid("Choose a different owner password.")
        }
        guard let original = open(input), !original.isEncrypted, original.pageCount > 0 else {
            throw ToolError.invalid("Choose a readable, unencrypted PDF.")
        }
        let count = original.pageCount
        let settings: [String: Any] = [
            "encrypt": [
                "userPassword": options.password,
                "ownerPassword": owner,
                "256bit": [
                    "print": options.allowsPrinting ? "full" : "none",
                    "extract": options.allowsCopying ? "y" : "n"
                ]
            ]
        ]
        try await run(input, output: output, executable: options.executable, settings: settings) { candidate in
            guard let saved = open(candidate), saved.isEncrypted, saved.isLocked,
                  saved.unlock(withPassword: options.password), saved.pageCount == count,
                  saved.allowsPrinting == options.allowsPrinting, saved.allowsCopying == options.allowsCopying,
                  let ownerCopy = open(candidate), ownerCopy.unlock(withPassword: owner) else {
                throw ToolError.invalid("The new password and permissions could not be verified.")
            }
        }
        return "\(input.lastPathComponent) · AES-256 protected"
    }

    public static func remove(
        _ input: URL, to output: URL, options: PDFProtectionOptions
    ) async throws -> String {
        guard let original = open(input), original.isEncrypted else {
            throw ToolError.invalid("Choose an encrypted PDF.")
        }
        try validatePassword(options.password)
        guard original.unlock(withPassword: options.password), original.pageCount > 0 else {
            throw ToolError.invalid("The document password is incorrect.")
        }
        let count = original.pageCount
        try await run(input, output: output, executable: options.executable,
                      settings: ["password": options.password, "decrypt": ""]) { candidate in
            guard let saved = open(candidate), !saved.isEncrypted, !saved.isLocked, saved.pageCount == count else {
                throw ToolError.invalid("The decrypted PDF could not be verified.")
            }
        }
        return "\(input.lastPathComponent) · Password removed"
    }

    private static func validatePassword(_ value: String) throws {
        guard value.utf8.count <= 127, !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ToolError.invalid("Use a password of at most 127 UTF-8 bytes with no null characters.")
        }
    }

    private static func open(_ url: URL) -> PDFDocument? {
        guard url.isFileURL else { return nil }
        return PDFDocument(url: url)
    }

    private static func run(
        _ input: URL, output: URL, executable: URL?, settings: [String: Any],
        verify: (URL) throws -> Void
    ) async throws {
        let manager = FileManager.default
        guard let executable, executable.isFileURL, manager.isExecutableFile(atPath: executable.path) else {
            throw ToolError.invalid("Choose a local qpdf executable.")
        }
        guard output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local PDF filename.")
        }
        try Task.checkCancellation()
        let folder = output.deletingLastPathComponent().appendingPathComponent(".MacUtilityKit-" + UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let configuration = folder.appendingPathComponent("job.json")
        let candidate = folder.appendingPathComponent("Protected.pdf")
        var job = settings
        job["inputFile"] = input.path
        job["outputFile"] = candidate.path
        let json = try JSONSerialization.data(withJSONObject: job)
        try json.write(to: configuration, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        do {
            // Pass only the path to the private job document in the process arguments.
            try await ExternalTool.run(executable, name: "qpdf", arguments: ["--job-json-file=" + configuration.path], directory: folder)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolError.invalid("qpdf could not change this document's password settings.")
        }
        try manager.removeItem(at: configuration)
        try Task.checkCancellation()
        try verify(candidate)
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
    }
}

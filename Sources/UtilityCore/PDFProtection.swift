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
    package static func addPasswordIssue(_ options: PDFProtectionOptions) -> String? {
        if options.password.isEmpty { return "Enter a document password." }
        if !isValidPassword(options.password) {
            return "Use a document password of at most 127 UTF-8 bytes with no null characters."
        }
        if options.password != options.confirmation { return "Confirm the document password." }
        if !isValidPassword(options.ownerPassword) {
            return "Use an owner password of at most 127 UTF-8 bytes with no null characters."
        }
        if options.ownerPassword == options.password { return "Choose a different owner password." }
        return nil
    }

    public static func add(
        _ input: URL, to output: URL, options: PDFProtectionOptions
    ) async throws -> String {
        if let issue = addPasswordIssue(options) { throw ToolError.invalid(issue) }
        let owner = options.ownerPassword.isEmpty ? UUID().uuidString + UUID().uuidString : options.ownerPassword
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
        guard isValidPassword(value) else {
            throw ToolError.invalid("Use a password of at most 127 UTF-8 bytes with no null characters.")
        }
    }

    private static func isValidPassword(_ value: String) -> Bool {
        value.utf8.count <= 127 && !value.utf8.contains(0)
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

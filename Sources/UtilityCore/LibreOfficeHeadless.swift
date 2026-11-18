import Foundation

enum LibreOfficeHeadless {
    static func binary(for selection: URL) -> URL {
        selection.pathExtension.lowercased() == "app"
            ? selection.appending(path: "Contents/MacOS/soffice") : selection
    }

    static func convert(
        _ input: URL, filter: String, fileExtension: String, executable: URL, in staging: URL,
        inputFilter: String? = nil
    ) async throws -> URL {
        let folder = staging.appending(path: "office-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let profile = folder.appending(path: "Profile", directoryHint: .isDirectory)
        let out = folder.appending(path: "Output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        var arguments = [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless", "--nologo", "--nodefault", "--norestore"
        ]
        if let inputFilter { arguments.append("--infilter=" + inputFilter) }
        arguments += ["--convert-to", filter, "--outdir", out.path, input.path]
        try await ExternalTool.run(binary(for: executable), name: "LibreOffice", arguments: arguments, directory: folder)
        try Task.checkCancellation()
        return out.appending(path: input.deletingPathExtension().lastPathComponent + "." + fileExtension)
    }
}

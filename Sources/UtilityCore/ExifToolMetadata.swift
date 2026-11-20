import Foundation

enum ExifToolMetadata {
    static func inspect(_ input: URL, executable: URL) async throws -> ImageMetadataSnapshot {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        let json = scratch.appendingPathComponent("metadata.json")
        try Data().write(to: json)
        let handle = try FileHandle(forWritingTo: json)
        defer { try? handle.close() }
        try await ExternalTool.run(executable, name: "ExifTool", arguments: [
            "-config", "", "-j", "-G1:4", "-s", "-a", "-u", "-e", "-n", "--", input.path
        ], directory: scratch, standardOutput: handle)
        guard let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]],
              let entry = entries.first else {
            throw ToolError.invalid("ExifTool did not return a metadata report.")
        }
        var groups: [ImageMetadataGroup: Set<String>] = [:]
        for key in entry.keys {
            let segments = key.split(separator: ":")
            guard segments.count >= 2, let namespace = segments.first, let field = segments.last else { continue }
            let fieldName = "\(namespace):\(field)"
            let recognized = MetadataField.groups(namespace: String(namespace), name: String(field))
            for group in recognized { groups[group, default: []].insert(fieldName) }
        }
        return ImageMetadataSnapshot(groups: groups.mapValues { $0.sorted() })
    }

    static func remove(
        _ input: URL, to output: URL, groups: Set<ImageMetadataGroup>, executable: URL
    ) async throws -> (ImageMetadataSnapshot, ImageMetadataSnapshot) {
        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        guard let stamp = try DuplicateFileIO.inspect(resolved) else {
            throw ToolError.invalid("Choose a readable local image file.")
        }
        try FileManager.default.copyItem(at: resolved, to: output)
        guard try DuplicateFileIO.inspect(output) != nil,
              try DuplicateFileIO.inspect(resolved) == stamp,
              input.resolvingSymlinksInPath().standardizedFileURL == resolved else {
            throw ToolError.invalid("The original image changed while preparing its copy.")
        }
        let original = try await inspect(output, executable: executable)
        let fields = Set(groups.flatMap { original.groups[$0] ?? [] })
        // The group classifiers may overlap. ExifTool reads details first, then removes only recognized,
        // writable names together with complete groups where the user explicitly selected them.
        var arguments = ["-config", "", "-overwrite_original"]
        if groups.contains(.location) { arguments += ["-GPS:All="] }
        if groups.contains(.camera) { arguments += ["-MakerNotes:All="] }
        if groups.contains(.iptc) { arguments += ["-IPTC:All="] }
        if groups.contains(.xmp) { arguments += ["-XMP:All="] }
        for field in fields.sorted() {
            if field.range(of: #"^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
                arguments.append("-\(field)=")
            }
        }

        if !fields.isEmpty {
            arguments += ["--", output.path]
            try await ExternalTool.run(executable, name: "ExifTool", arguments: arguments,
                                       directory: output.deletingLastPathComponent())
        }
        let updated = try await inspect(output, executable: executable)
        return (original, updated)
    }
}

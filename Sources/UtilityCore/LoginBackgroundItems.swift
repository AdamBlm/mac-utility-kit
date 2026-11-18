import Darwin
import Foundation

package enum LoginBackgroundItems {
    package enum Kind: String, CaseIterable, Sendable {
        case loginItem = "Login item"
        case app = "App registration"
        case agent = "Launch agent"
        case daemon = "Launch daemon"
        case background = "Background task"
        case unknown = "Unknown type"
    }

    package enum Status: String, CaseIterable, Sendable {
        case enabled = "Enabled"
        case disabled = "Disabled"
        case disallowed = "Disallowed"
        case unknown = "Unknown status"
    }

    package struct Entry: Identifiable, Sendable {
        package let id: String
        package let name: String
        package let publisher: String?
        package let team: String?
        package let identifier: String?
        package let sourcePath: String?
        package let executablePath: String?
        package let kind: Kind
        package let status: Status
        package let systemWide: Bool

        package var location: URL? {
            if let sourcePath, let url = Self.localURL(sourcePath) { return url }
            return executablePath.flatMap(Self.localURL)
        }

        package var locationExists: Bool {
            location.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }

        private static func localURL(_ raw: String) -> URL? {
            if raw.hasPrefix("/") { return URL(filePath: raw) }
            guard let url = URL(string: raw), url.isFileURL, url.path.hasPrefix("/"),
                  url.host == nil || url.host?.isEmpty == true || url.host == "localhost"
            else { return nil }
            return url
        }
    }

    package static func inventory() async throws -> [Entry] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("inventory.txt")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        try await ExternalTool.run(URL(filePath: "/usr/bin/sfltool"), name: "sfltool",
                                   arguments: ["dumpbtm"], directory: directory, standardOutput: handle)
        try Task.checkCancellation()
        return try parse(String(contentsOf: output, encoding: .utf8), userID: Int(getuid()))
    }

    static func parse(_ output: String, userID: Int) throws -> [Entry] {
        var entries: [Entry] = []
        var currentUID: Int?
        var allowSection = false
        var recognizedSection = false
        var recordNumber: String?
        var fields: [String: String] = [:]

        func finishRecord() {
            defer { fields.removeAll(keepingCapacity: true) }
            guard allowSection, let currentUID, let recordNumber else { return }
            let identifier = fields["Bundle Identifier"] ?? fields["Identifier"]
            guard let name = fields["Name"] ?? identifier else { return }
            let kind: Kind
            let type = fields["Type"]?.split(separator: "(", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch type {
            case "app", "legacy app": kind = .app
            case "login item", "legacy login item": kind = .loginItem
            case "agent", "legacy agent": kind = .agent
            case "daemon", "legacy daemon": kind = .daemon
            case "background app refresh", "background tasks": kind = .background
            case "developer", "spotlight", "dock tile", "quicklook": return
            default: kind = .unknown
            }

            let labels = fields["Disposition"]?
                .split(separator: "(", maxSplits: 1).first?
                .split { !$0.isLetter }.map { String($0).lowercased() } ?? []
            let disposition = labels.joined(separator: " ")
            let status: Status
            if labels.contains("disallowed") || labels.contains("denied") || disposition.contains("not allowed") {
                status = .disallowed
            } else if labels.contains("disabled") {
                status = .disabled
            } else if labels.contains("enabled"),
                      !disposition.contains("not enabled") {
                status = .enabled
            } else {
                status = .unknown
            }

            entries.append(Entry(
                id: "\(currentUID):\(recordNumber):\(fields["UUID"] ?? "")",
                name: name, publisher: fields["Developer Name"], team: fields["Team Identifier"],
                identifier: identifier, sourcePath: fields["URL"], executablePath: fields["Executable Path"],
                kind: kind, status: status, systemWide: currentUID == 0 || currentUID == -2
            ))
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                finishRecord()
                recordNumber = nil
                let uid = line.dropFirst("Records for UID ".count).prefix { $0 == "-" || $0.isNumber }
                currentUID = Int(uid)
                allowSection = currentUID == userID || currentUID == 0 || currentUID == -2
                recognizedSection = recognizedSection || allowSection
            } else if line.hasPrefix("#"), line.hasSuffix(":"),
                      !line.dropFirst().dropLast().isEmpty,
                      line.dropFirst().dropLast().allSatisfy(\.isNumber) {
                finishRecord()
                recordNumber = String(line.dropFirst().dropLast())
            } else if allowSection, recordNumber != nil, let separator = line.firstIndex(of: ":") {
                let key = String(line[..<separator])
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value != "(null)", value != "(none)" {
                    fields[key] = value
                }
            }
        }
        finishRecord()
        guard recognizedSection else { throw ToolError.invalid("macOS did not return a recognizable login item inventory.") }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

import CoreGraphics
import Foundation

public actor DisplayControl {
    public enum Feature: String, CaseIterable, Identifiable, Sendable {
        case brightness = "Brightness"
        case contrast = "Contrast"
        case volume = "Volume"

        public var id: Self { self }
        fileprivate var command: String {
            switch self {
            case .brightness: "luminance"
            case .contrast: "contrast"
            case .volume: "volume"
            }
        }
    }

    public struct Display: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let displayID: UInt32
        fileprivate let selector: String
    }

    public struct Setting: Equatable, Sendable {
        public let current: Int
        public let maximum: Int
    }

    public enum WriteResult: Equatable, Sendable {
        case accepted(Setting)
        case notAccepted(Setting)
        case unconfirmed
    }

    public static var platformSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private let command: @Sendable ([String]) async throws -> String
    private let connectedExternalIDs: @Sendable () -> Set<UInt32>
    private var busy = false

    public init(executable: URL) {
        command = { try await M1DDCCommand.run(executable, arguments: $0) }
        connectedExternalIDs = { Self.externalIDs() }
    }

    init(command: @escaping @Sendable ([String]) async throws -> String,
         connectedExternalIDs: @escaping @Sendable () -> Set<UInt32>) {
        self.command = command
        self.connectedExternalIDs = connectedExternalIDs
    }

    public func displays() async throws -> [Display] {
        try enter()
        defer { busy = false }
        return try await list()
    }

    public func settings(for display: Display) async throws -> [Feature: Setting] {
        try enter()
        defer { busy = false }
        try await validateConnected(display)
        var result: [Feature: Setting] = [:]
        for feature in Feature.allCases {
            try Task.checkCancellation()
            result[feature] = try await read(feature, on: display)
        }
        guard connectedExternalIDs().contains(display.displayID) else { throw Self.disconnected }
        return result
    }

    public func apply(_ requested: Int, feature: Feature, on display: Display) async throws -> WriteResult {
        try enter()
        defer { busy = false }
        try await validateConnected(display)
        guard let before = try await read(feature, on: display) else {
            throw ToolError.invalid("This display no longer reports a range for \(feature.rawValue.lowercased()).")
        }
        guard (0...before.maximum).contains(requested) else {
            throw ToolError.invalid("Enter a value from 0 to \(before.maximum).")
        }
        if requested == before.current { return .accepted(before) }
        try Task.checkCancellation()
        guard connectedExternalIDs().contains(display.displayID) else { throw Self.disconnected }
        _ = try await command(["display", display.selector, "set", feature.command, String(requested)])

        var latest: Setting?
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(160)) }
            guard connectedExternalIDs().contains(display.displayID) else { return .unconfirmed }
            if let setting = try await read(feature, on: display) {
                latest = setting
                if setting.current == requested { return .accepted(setting) }
            }
        }
        return latest.map(WriteResult.notAccepted) ?? .unconfirmed
    }

    private func read(_ feature: Feature, on display: Display) async throws -> Setting? {
        do {
            let current = try await command(["display", display.selector, "get", feature.command])
            let maximum = try await command(["display", display.selector, "max", feature.command])
            guard let current = parseValue(current), let maximum = parseValue(maximum),
                  maximum > 0, current <= maximum else { return nil }
            return Setting(current: current, maximum: maximum)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func parseValue(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt16(value).map(Int.init)
    }

    private func list() async throws -> [Display] {
        let output: String
        do {
            output = try await command(["display", "list", "detailed"])
        } catch let failure as M1DDCCommand.Failure where failure.output.trimmingCharacters(in: .whitespacesAndNewlines)
            == "No external display found, aborting" {
            return []
        }
        let connected = connectedExternalIDs()
        return Self.parseDisplays(output).filter { connected.contains($0.displayID) }
    }

    private func validateConnected(_ display: Display) async throws {
        guard try await list().contains(where: { $0.id == display.id && $0.displayID == display.displayID }) else {
            throw Self.disconnected
        }
    }

    private func enter() throws {
        guard !busy else { throw ToolError.invalid("Wait for the current display request to finish.") }
        busy = true
    }

    private static var disconnected: ToolError {
        .invalid("The selected external display is no longer connected. Refresh to choose a display.")
    }

    // m1ddc prints a heading, display ID, and system UUID for each detailed record.
    static func parseDisplays(_ output: String) -> [Display] {
        var records: [[Substring]] = []
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                records.append([line])
            } else if let last = records.indices.last {
                records[last].append(line)
            }
        }
        let parsed = records.compactMap { record -> Display? in
            guard let header = record.first, let closeBracket = header.firstIndex(of: "]"),
                  let openParenthesis = header.lastIndex(of: "("), header.last == ")",
                  openParenthesis > closeBracket,
                  let uuidText = recordValue(" - System UUID:", in: record),
                  let uuid = UUID(uuidString: uuidText),
                  let idText = recordValue(" - Display ID:", in: record),
                  let displayID = UInt32(idText), displayID != 0,
                  let headerID = UUID(uuidString: String(header[header.index(after: openParenthesis)..<header.index(before: header.endIndex)])),
                  headerID == uuid else { return nil }
            let name = header[header.index(after: closeBracket)..<openParenthesis]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Display(id: uuid, name: name.isEmpty ? "External Display" : name,
                           displayID: displayID, selector: "uuid=" + uuidText)
        }
        let byUUID = Dictionary(grouping: parsed, by: \.id)
        let byDisplayID = Dictionary(grouping: parsed, by: \.displayID)
        return parsed.filter { byUUID[$0.id]?.count == 1 && byDisplayID[$0.displayID]?.count == 1 }
    }

    private static func recordValue(_ prefix: String, in record: [Substring]) -> String? {
        let fields = record.filter { $0.hasPrefix(prefix) }
        guard fields.count == 1, let field = fields.first else { return nil }
        return field.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func externalIDs() -> Set<UInt32> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Set(displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsOnline($0) != 0 })
    }
}

private enum M1DDCCommand {
    struct Failure: LocalizedError {
        let output: String
        let underlying: String

        var errorDescription: String? {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? underlying : message
        }
    }

    static func run(_ executable: URL, arguments: [String]) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("response")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        do {
            try await ExternalTool.run(executable, name: "m1ddc", arguments: arguments, directory: folder,
                                       standardOutput: handle)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let response = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            throw Failure(output: response, underlying: error.localizedDescription)
        }
        return try String(contentsOf: output, encoding: .utf8)
    }
}

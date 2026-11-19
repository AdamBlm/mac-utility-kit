import Foundation
import Network

public struct NetworkSpeedResult: Sendable {
    public let mode: NetworkSpeedTest.Mode
    public let downloadBitsPerSecond: Double?
    public let uploadBitsPerSecond: Double?
    public let idleLatencyMilliseconds: Double?
    public let responsiveness: Double?
    public let uploadResponsiveness: Double?
    public let downloadResponsiveness: Double?
    public let interface: String?
    public let timestamp: Date
    public let elapsedSeconds: TimeInterval?
}

public enum NetworkSpeedTest {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case combined = "Combined"
        case sequential = "Sequential"

        public var id: Self { self }
        var arguments: [String] { self == .sequential ? ["-c", "-s"] : ["-c"] }
    }

    struct Path: Equatable, Sendable {
        let connected: Bool
        let interfaces: [String]
        var uniqueInterface: String? { interfaces.count == 1 ? interfaces.first : nil }

        init(connected: Bool, interfaces: [String]) {
            self.connected = connected
            self.interfaces = interfaces.sorted()
        }

        init(_ path: NWPath) {
            self.init(connected: path.status == .satisfied,
                      interfaces: path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name))
        }
    }

    public static func run(mode: Mode = .combined) async throws -> NetworkSpeedResult {
        let executable = URL(fileURLWithPath: "/usr/bin/networkQuality")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolError.invalid("Network Quality is unavailable on this Mac.")
        }
        let monitor = NWPathMonitor()
        let (paths, updates) = AsyncStream<Path>.makeStream()
        monitor.pathUpdateHandler = { path in updates.yield(Path(path)) }
        monitor.start(queue: DispatchQueue(label: "MacUtilityKit.NetworkPath"))
        defer {
            monitor.cancel()
            updates.finish()
        }

        let initial = try await initialPath(paths)
        let result = try await measure(path: initial, changes: paths, timeout: .seconds(45), mode: mode) {
            try await benchmark(executable, mode: mode)
        }
        try Task.checkCancellation()
        let final = Path(monitor.currentPath)
        if !final.connected { throw ToolError.invalid("The network disconnected during the test.") }
        if final != initial { throw ToolError.invalid("The active network interface changed. Run the test again.") }
        return result
    }

    static func measure(
        path: Path, changes: AsyncStream<Path>, timeout: Duration, mode: Mode = .combined,
        benchmark: @escaping @Sendable () async throws -> Data
    ) async throws -> NetworkSpeedResult {
        try Task.checkCancellation()
        guard path.connected else { throw ToolError.invalid("The Mac is offline. Connect to a network and try again.") }
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await benchmark() }
            group.addTask {
                for await next in changes {
                    try Task.checkCancellation()
                    if !next.connected {
                        throw ToolError.invalid("The network disconnected during the test.")
                    }
                    if next != path {
                        throw ToolError.invalid("The active network interface changed. Run the test again.")
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolError.invalid("The network test did not finish in time. Try again.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
        try Task.checkCancellation()
        return try decode(data, interface: path.uniqueInterface, mode: mode)
    }

    static func decode(_ data: Data, interface: String?, timestamp: Date = .now,
                       mode: Mode = .combined, timeZone: TimeZone = .current) throws -> NetworkSpeedResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalid("Network Quality did not return a readable report.")
        }
        let reportedInterface = interfaceName(object["interface_name"]) ?? interfaceName(object["interface"])
        let timing = reportTiming(object, received: timestamp, timeZone: timeZone)
        return NetworkSpeedResult(
            mode: mode,
            downloadBitsPerSecond: metric(object["dl_throughput"]),
            uploadBitsPerSecond: metric(object["ul_throughput"]),
            idleLatencyMilliseconds: metric(object["base_rtt"]),
            responsiveness: metric(object["responsiveness"]) ?? metric(object["rpm"]),
            uploadResponsiveness: metric(object["ul_responsiveness"]),
            downloadResponsiveness: metric(object["dl_responsiveness"]),
            interface: reportedInterface ?? interface,
            timestamp: timing.completed,
            elapsedSeconds: timing.elapsed
        )
    }

    private static func reportTiming(
        _ object: [String: Any], received: Date, timeZone: TimeZone
    ) -> (completed: Date, elapsed: TimeInterval?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.isLenient = false
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String, let parsed = formatter.date(from: text),
                  formatter.string(from: parsed) == text else { return nil }
            return parsed
        }
        // The native tool reports local wall-clock times without a UTC offset.
        // Avoid a misleading native timestamp if an ambiguous hour or clock change puts it far from receipt.
        guard let completed = date(object["end_date"]), abs(completed.timeIntervalSince(received)) <= 60 else {
            return (received, nil)
        }
        let elapsed = date(object["start_date"]).map { completed.timeIntervalSince($0) }
            .flatMap { (0...60).contains($0) ? $0 : nil }
        return (completed, elapsed)
    }

    private static func interfaceName(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func metric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private static func initialPath(_ paths: AsyncStream<Path>) async throws -> Path {
        try await withThrowingTaskGroup(of: Path.self) { group in
            group.addTask {
                for await event in paths { return event }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw ToolError.invalid("Could not determine the current network connection.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private static func benchmark(_ executable: URL, mode: Mode) async throws -> Data {
        try Task.checkCancellation()
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: ".network-quality-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appending(path: "report.json")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        do {
            try Task.checkCancellation()
            try await ExternalTool.run(executable, name: "Network Quality", arguments: mode.arguments,
                                       directory: folder, standardOutput: handle)
        } catch {
            try Task.checkCancellation()
            throw ToolError.invalid("The network benchmark could not finish. \(error.localizedDescription)")
        }
        return try Data(contentsOf: file)
    }
}

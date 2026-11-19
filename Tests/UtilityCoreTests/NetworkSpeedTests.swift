import Foundation
import Testing
@testable import UtilityCore

struct NetworkSpeedTests {
    @Test func decodesNativeMetricsReportsMissingFieldsAndUsesReportedInterface() throws {
        let json = Data(#"{"dl_throughput": 12345678, "ul_throughput": -1, "responsiveness": true, "ul_responsiveness": 124, "interface_name": "en7"}"#.utf8)
        let timestamp = Date(timeIntervalSince1970: 42)
        let measured = try NetworkSpeedTest.decode(json, interface: "en0", timestamp: timestamp)
        #expect(measured.downloadBitsPerSecond == 12_345_678)
        #expect(measured.uploadBitsPerSecond == nil)
        #expect(measured.responsiveness == nil)
        #expect(measured.uploadResponsiveness == 124)
        #expect(measured.interface == "en7")
        #expect(measured.timestamp == timestamp)
        #expect(throws: ToolError.self) {
            try NetworkSpeedTest.decode(Data("invalid".utf8), interface: nil)
        }
    }

    @Test func choosesTheFirstValidMetricAndInterfaceAlias() throws {
        let preferred = try NetworkSpeedTest.decode(
            Data(#"{"responsiveness":0,"rpm":812,"interface_name":"en3","interface":"en7"}"#.utf8), interface: "en0"
        )
        #expect(preferred.responsiveness == 0)
        #expect(preferred.interface == "en3")

        let alternate = try NetworkSpeedTest.decode(
            Data(#"{"responsiveness":null,"rpm":812,"interface_name":" ","interface":"en7"}"#.utf8), interface: "en0"
        )
        #expect(alternate.responsiveness == 812)
        #expect(alternate.interface == "en7")

        let unreported = try NetworkSpeedTest.decode(
            Data(#"{"responsiveness":true,"rpm":-1,"interface_name":0,"interface":null}"#.utf8), interface: "en0"
        )
        #expect(unreported.responsiveness == nil)
        #expect(unreported.interface == "en0")
    }

    @Test func requestsNativeSequentialModeAndParsesIdleAndDirectionalMetrics() throws {
        #expect(NetworkSpeedTest.Mode.combined.arguments == ["-c"])
        #expect(NetworkSpeedTest.Mode.sequential.arguments == ["-c", "-s"])
        let sequential = try NetworkSpeedTest.decode(
            Data(#"{"base_rtt":27.82,"ul_responsiveness":1129,"dl_responsiveness":1007}"#.utf8), interface: nil, mode: .sequential
        )
        #expect(sequential.mode == .sequential)
        #expect(sequential.idleLatencyMilliseconds == 27.82)
        #expect(sequential.uploadResponsiveness == 1129)
        #expect(sequential.downloadResponsiveness == 1007)
        #expect(sequential.responsiveness == nil)

        for value in ["true", "-1", "null", #""27.82""#] {
            let report = try NetworkSpeedTest.decode(Data("{\"base_rtt\":\(value)}".utf8), interface: nil)
            #expect(report.idleLatencyMilliseconds == nil)
        }
        #expect(try NetworkSpeedTest.decode(Data("{}".utf8), interface: nil).idleLatencyMilliseconds == nil)
    }

    @Test func rejectsOfflineAndCancelsOnInterfaceChange() async throws {
        let (paths, changes) = AsyncStream<NetworkSpeedTest.Path>.makeStream()
        defer { changes.finish() }
        await #expect(throws: ToolError.self) {
            try await NetworkSpeedTest.measure(path: .init(connected: false, interfaces: []), changes: paths, timeout: .seconds(1)) {
                Issue.record("An offline test must not execute the benchmark.")
                return Data()
            }
        }
        changes.yield(.init(connected: true, interfaces: ["en1"]))
        await #expect(throws: ToolError.self) {
            try await NetworkSpeedTest.measure(path: .init(connected: true, interfaces: ["en0"]), changes: paths, timeout: .seconds(1)) {
                try await Task.sleep(for: .seconds(2))
                return Data()
            }
        }
    }

    @Test func timesOutAndNeverPublishesCancelledMeasurement() async throws {
        let online = NetworkSpeedTest.Path(connected: true, interfaces: ["en0"])
        let (timeoutPath, timeoutUpdates) = AsyncStream<NetworkSpeedTest.Path>.makeStream()
        defer { timeoutUpdates.finish() }
        await #expect(throws: ToolError.self) {
            try await NetworkSpeedTest.measure(path: online, changes: timeoutPath, timeout: .milliseconds(15)) {
                try await Task.sleep(for: .seconds(1))
                return Data()
            }
        }
        let (cancelPath, cancelUpdates) = AsyncStream<NetworkSpeedTest.Path>.makeStream()
        defer { cancelUpdates.finish() }
        let task = Task {
            try await NetworkSpeedTest.measure(path: online, changes: cancelPath, timeout: .seconds(1)) {
                try? await Task.sleep(for: .milliseconds(100))
                return Data(#"{"dl_throughput": 120}"#.utf8)
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

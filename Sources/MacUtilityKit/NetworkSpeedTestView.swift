import SwiftUI
import UtilityCore

struct NetworkSpeedTestView: View {
    @State private var mode: NetworkSpeedTest.Mode = .combined
    @State private var result: NetworkSpeedResult?
    @State private var work: Task<Void, Never>?
    @State private var issue: String?
    @State private var copied = false

    var body: some View {
        InteractiveToolLayout(tool: .networkSpeedTest) { palette in
            WorkspaceSection("Connection test", palette: palette) {
                Text("Tests download, upload and responsiveness using macOS Network Quality. Running a test sends data over your active connection.")
                    .font(.callout).foregroundStyle(.secondary)
                SettingRow("Test mode") {
                    Picker("Test mode", selection: $mode) {
                        ForEach(NetworkSpeedTest.Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .help("Combined tests upload and download together. Sequential measures responsiveness for each direction.")
                    .disabled(work != nil)
                }
                HStack {
                    Button("Start Test", systemImage: "speedometer", action: start)
                        .buttonStyle(.borderedProminent).disabled(work != nil)
                    if work != nil {
                        ProgressView("Measuring connection…").controlSize(.small)
                        Button("Cancel") { work?.cancel() }
                    }
                }
            }
            if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            if let result {
                WorkspaceSection("Results", palette: palette) {
                    let fields = rows(result)
                    ForEach(fields, id: \.0) { label, value in
                        LabeledContent(label, value: value).font(.callout.monospacedDigit())
                    }
                    Button("Copy Results", systemImage: "doc.on.doc") {
                        DeveloperToolFiles.copy((["Network Speed Test"] + fields.map { "\($0.0): \($0.1)" }).joined(separator: "\n"))
                        copied = true
                    }
                    if copied { Text("Copied").foregroundStyle(.secondary).font(.callout) }
                }
            }
        }
        .onDisappear { work?.cancel() }
        .onChange(of: mode) {
            result = nil
            issue = nil
            copied = false
        }
    }

    private func rows(_ result: NetworkSpeedResult) -> [(String, String)] {
        var fields = [
            ("Test mode", result.mode.rawValue),
            ("Download", throughput(result.downloadBitsPerSecond)),
            ("Upload", throughput(result.uploadBitsPerSecond)),
            ("Idle latency", latency(result.idleLatencyMilliseconds))
        ]
        if result.mode == .sequential {
            fields.append(("Download responsiveness", responsiveness(result.downloadResponsiveness)))
            fields.append(("Upload responsiveness", responsiveness(result.uploadResponsiveness)))
        } else {
            fields.append(("Responsiveness", responsiveness(result.responsiveness)))
        }
        fields.append(("Interface", result.interface ?? "Unavailable"))
        if let elapsed = result.elapsedSeconds {
            fields.append(("Elapsed", "\(elapsed.formatted(.number.precision(.fractionLength(1)))) seconds"))
        }
        fields.append(("Completed", result.timestamp.formatted(date: .abbreviated, time: .standard)))
        return fields
    }

    private func throughput(_ value: Double?) -> String {
        value.map { "\(($0 / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps" } ?? "Unavailable"
    }

    private func latency(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) ms" } ?? "Unavailable"
    }

    private func responsiveness(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) RPM" } ?? "Unavailable"
    }

    private func start() {
        guard work == nil else { return }
        result = nil
        issue = nil
        copied = false
        let testMode = mode
        work = Task {
            defer { work = nil }
            do {
                let report = try await NetworkSpeedTest.run(mode: testMode)
                if !Task.isCancelled { result = report }
            } catch is CancellationError {
                issue = "Test cancelled."
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}

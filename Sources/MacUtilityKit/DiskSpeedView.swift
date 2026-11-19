import AppKit
import SwiftUI
import UtilityCore

struct DiskSpeedView: View {
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser
    @State private var volumes: [URL] = []
    @State private var options = DiskSpeedOptions()
    @State private var result: DiskSpeedResult?
    @State private var progress: DiskSpeedProgress?
    @State private var work: Task<Void, Never>?
    @State private var issue: String?
    @State private var copied = false
    @State private var refreshID = UUID()
    @State private var inspection: (request: DestinationRequest, result: Result<DiskSpeedDestination, any Error>)?

    private struct DestinationRequest: Equatable {
        let folder: URL
        let refreshID: UUID
    }

    private var inspectionRequest: DestinationRequest { .init(folder: folder, refreshID: refreshID) }

    private var destinationIssue: String? {
        guard let inspection, inspection.request == inspectionRequest else { return nil }
        switch inspection.result {
        case .success(let info): return info.issue(forSizeMiB: options.sizeMiB)
        case .failure(let error): return error.localizedDescription
        }
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var destinations: [URL] {
        let mounted = [home] + volumes.filter { $0 != home }
        return mounted.contains(folder) ? mounted : mounted + [folder]
    }

    var body: some View {
        InteractiveToolLayout(tool: .diskSpeedTest) { palette in
            WorkspaceSection("Test settings", palette: palette) {
                SettingRow("Location") {
                    Picker("Test location", selection: $folder) {
                        ForEach(destinations, id: \.self) { destination in
                            Text(location(destination)).tag(destination)
                        }
                    }
                    .labelsHidden()
                    Button("Choose Folder…", systemImage: "folder", action: chooseFolder)
                    Button("Refresh volumes", systemImage: "arrow.clockwise", action: refreshVolumes)
                        .labelStyle(.iconOnly)
                }
                if let inspection, inspection.request == inspectionRequest {
                    if case .success(let info) = inspection.result {
                        let free = info.availableBytes.map {
                            ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)
                        } ?? "Unavailable"
                        LabeledContent("Available space", value: free).font(.callout)
                    }
                    if let destinationIssue {
                        Text(destinationIssue).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Checking location…").controlSize(.small)
                }
                SettingRow("Test size") {
                    Picker("Test size", selection: $options.sizeMiB) {
                        ForEach([64, 256, 512, 1_024, 2_048, 4_096], id: \.self) {
                            Text("\($0.formatted()) MiB").tag($0)
                        }
                    }
                    .labelsHidden()
                }
                SettingRow("Mode") {
                    Picker("Test mode", selection: $options.repeats) {
                        Text("Quick").tag(false)
                        Text("Three passes").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
            }
            .disabled(work != nil)
            HStack {
                Button("Run Test", systemImage: "gauge.with.dots.needle.33percent", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(work != nil || inspection?.request != inspectionRequest || destinationIssue != nil)
                if work != nil {
                    Button("Cancel") { work?.cancel() }
                }
            }
            if let progress {
                WorkspaceSection("Progress", palette: palette) {
                    ProgressView("\(progress.phase.rawValue) · Pass \(progress.pass) of \(progress.passes)",
                                 value: progress.fraction)
                }
            }
            if let result {
                WorkspaceSection("Sequential throughput", palette: palette) { results(result) }
            }
            if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
        }
        .task { refreshVolumes() }
        .task(id: inspectionRequest) { [inspectionRequest] in
            do {
                let info = try await DiskSpeed.inspect(inspectionRequest.folder)
                try Task.checkCancellation()
                inspection = (inspectionRequest, .success(info))
            } catch {
                if !Task.isCancelled { inspection = (inspectionRequest, .failure(error)) }
            }
        }
        .onChange(of: folder) { clear() }
        .onChange(of: options) { clear() }
        .onDisappear { work?.cancel() }
    }

    private func results(_ result: DiskSpeedResult) -> some View {
        let details = result.passDetails()
        return VStack(alignment: .leading, spacing: 9) {
            LabeledContent(details.isEmpty ? "Write" : "Median write", value: throughput(result.writeMegabytesPerSecond))
            LabeledContent(details.isEmpty ? "Read" : "Median read", value: throughput(result.readMegabytesPerSecond))
            Text(result.passes.count == 1 ? "\(result.sizeMiB.formatted()) MiB · One pass"
                 : "\(result.sizeMiB.formatted()) MiB per pass · Median of three")
                .foregroundStyle(.secondary)
            Text(cacheStatus(result)).foregroundStyle(.secondary)
            if !details.isEmpty {
                DisclosureGroup("Individual Passes") {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Copy Results", systemImage: "doc.on.doc") {
                DeveloperToolFiles.copy(([
                    "Disk Speed Test", "Location: \(folder.path)",
                    "Test size: \(result.sizeMiB.formatted()) MiB · \(result.passes.count) pass(es)",
                    "\(details.isEmpty ? "Sequential write" : "Median sequential write"): \(throughput(result.writeMegabytesPerSecond))",
                    "\(details.isEmpty ? "Sequential read" : "Median sequential read"): \(throughput(result.readMegabytesPerSecond))",
                    cacheStatus(result)
                ] + details).joined(separator: "\n"))
                copied = true
            }
            if copied { Text("Copied").foregroundStyle(.secondary) }
        }
        .font(.callout.monospacedDigit())
    }

    private func location(_ url: URL) -> String {
        if url == home { return "Home folder" }
        let name = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        return volumes.contains(url) ? (name ?? url.path) : url.path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        folder = selected
    }

    private func refreshVolumes() {
        refreshID = UUID()
        volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                                        options: [.skipHiddenVolumes]) ?? []
    }

    private func run() {
        guard work == nil, inspection?.request == inspectionRequest, destinationIssue == nil else { return }
        clear()
        let target = folder
        let settings = options
        work = Task {
            defer { work = nil; progress = nil }
            do {
                let measured = try await DiskSpeed.run(in: target, options: settings) { event in
                    await MainActor.run { progress = event }
                }
                if !Task.isCancelled { result = measured }
            } catch is CancellationError {
                issue = "Test cancelled."
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func clear() {
        result = nil
        progress = nil
        issue = nil
        copied = false
    }

    private func throughput(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) MB/s"
    }

    private func cacheStatus(_ result: DiskSpeedResult) -> String {
        let cache = result.bypassedFileCache ? "File cache bypass requested" : "File cache active"
        return cache + (result.fullFlush ? " · Full write flush" : " · Standard write flush")
    }
}

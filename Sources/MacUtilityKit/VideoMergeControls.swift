import AVKit
import Combine
import SwiftUI
import UtilityCore

struct VideoMergeControls: View {
    @Binding var inputs: [URL]
    @Binding var options: VideoMergeOptions
    @State private var selection = 1
    @State private var analysis: Analysis?
    @State private var preview: Preview?
    @State private var playbackRequest: BoundaryRequest?

    private struct Request: Equatable {
        let inputs: [URL]
        let options: VideoMergeOptions
    }

    private struct BoundaryRequest: Equatable {
        let request: Request
        let index: Int
    }

    private struct Analysis {
        let request: Request
        let result: Result<VideoMergePlan, any Error>
    }

    private struct Preview {
        let request: BoundaryRequest
        let result: Result<VideoMergeBoundaryPreview, any Error>
    }

    var body: some View {
        let request = Request(inputs: inputs, options: options)
        let boundary = inputs.count > 1 ? BoundaryRequest(request: request, index: min(selection, inputs.count - 1)) : nil
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Format") {
                Picker("Format", selection: $options.format) {
                    ForEach(VideoMergeFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            SettingRow("Method") {
                Picker("Method", selection: $options.mode) {
                    ForEach(VideoMergeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            if options.mode == .normalize {
                SettingRow("Resolution") {
                    Picker("Resolution", selection: $options.resolution) {
                        ForEach(VideoMergeResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Toggle("Keep primary audio from each clip", isOn: $options.keepsAudio)
            if !inputs.isEmpty {
                let plan = analysis?.request == request ? try? analysis?.result.get() : nil
                clipOrder(plan: plan)
                if let plan {
                    LabeledContent("Output", value: "\(Int(plan.size.width)) × \(Int(plan.size.height)) · \(time(plan.duration))")
                        .font(.callout.monospacedDigit())
                        .frame(maxWidth: 310)
                    if options.mode == .passthrough, let issue = plan.passthroughIssue {
                        Text(issue).font(.callout).foregroundStyle(.secondary)
                    } else if let boundary {
                        boundaryPreview(boundary)
                    }
                } else if analysis?.request == request, case .failure(let error) = analysis?.result {
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
                if inputs.count == 1 {
                    Text("Add a second clip to merge.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: request) { await analyze(request) }
        .task(id: boundary) { await loadBoundary(boundary) }
        .onChange(of: boundary) { playbackRequest = nil }
    }

    private func clipOrder(plan: VideoMergePlan?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Clip order").font(.headline)
            ForEach(inputs.indices, id: \.self) { index in
                let input = inputs[index]
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(input.lastPathComponent).lineLimit(1).truncationMode(.middle).help(input.path)
                        if let clip = plan?.clips[index] {
                            let interval = "\(time(clip.start))–\(time(clip.start + clip.duration))"
                            Text([interval, warning(for: clip)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Move \(input.lastPathComponent) up", systemImage: "chevron.up") {
                        move(index, by: -1)
                    }
                    .labelStyle(.iconOnly).disabled(index == 0)
                    Button("Move \(input.lastPathComponent) down", systemImage: "chevron.down") {
                        move(index, by: 1)
                    }
                    .labelStyle(.iconOnly).disabled(index == inputs.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func boundaryPreview(_ request: BoundaryRequest) -> some View {
        SettingRow("Transition") {
            Picker("Transition", selection: Binding(get: { request.index }, set: { selection = $0 })) {
                ForEach(Array(inputs.indices.dropFirst()), id: \.self) { index in
                    Text("Clip \(index) → \(index + 1)").tag(index)
                }
            }
            .labelsHidden()
        }
        if playbackRequest == request {
            Button("Hide Playback") { playbackRequest = nil }
            BoundaryPlayer(inputs: request.request.inputs, index: request.index, options: request.request.options)
                .id(request.index)
        } else {
            Button("Preview Playback", systemImage: "play.rectangle") { playbackRequest = request }
        }
        if preview?.request == request, let result = preview?.result {
            switch result {
            case .success(let images):
                HStack(alignment: .top, spacing: 12) {
                    still(images.before, label: "Before cut")
                    still(images.after, label: "After cut")
                }
            case .failure(let error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            ProgressView("Preparing preview…").controlSize(.small)
        }
    }

    private func still(_ image: CGImage, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(decorative: image, scale: 1)
                .resizable().scaledToFit().frame(maxWidth: 230, maxHeight: 140)
                .accessibilityLabel(label)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func time(_ value: Double) -> String {
        Duration.seconds(value).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 2)))
    }

    private func warning(for clip: VideoMergePlan.Clip) -> String? {
        let warnings = [
            options.mode == .normalize && clip.sizesDiffer ? "Padded or resized" : nil,
            options.mode == .normalize && clip.hasDifferentSettings && !clip.sizesDiffer ? "Stream settings differ" : nil,
            options.keepsAudio && !clip.hasAudio ? "Silent" : nil
        ].compactMap { $0 }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    private func move(_ index: Int, by offset: Int) {
        guard inputs.indices.contains(index), inputs.indices.contains(index + offset) else { return }
        inputs.swapAt(index, index + offset)
    }

    private func analyze(_ request: Request) async {
        guard request.inputs.count > 1 else { analysis = nil; return }
        do {
            let plan = try await VideoMerge.plan(request.inputs, options: request.options)
            if !Task.isCancelled { analysis = Analysis(request: request, result: .success(plan)) }
        } catch {
            if !Task.isCancelled { analysis = Analysis(request: request, result: .failure(error)) }
        }
    }

    private func loadBoundary(_ request: BoundaryRequest?) async {
        guard let request else { preview = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            let images = try await VideoMerge.previewBoundary(request.request.inputs, before: request.index, options: request.request.options)
            if !Task.isCancelled { preview = Preview(request: request, result: .success(images)) }
        } catch {
            if !Task.isCancelled { preview = Preview(request: request, result: .failure(error)) }
        }
    }
}

private struct BoundaryPlayer: View {
    let inputs: [URL]
    let index: Int
    let options: VideoMergeOptions
    @State private var player: AVPlayer?
    @State private var issue: String?

    var body: some View {
        Group {
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            } else if let player, let item = player.currentItem {
                VideoPlayer(player: player)
                    .frame(minHeight: 160, idealHeight: 210, maxHeight: 260)
                    .accessibilityLabel("Playback across the selected cut")
                    .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                        guard status == .failed else { return }
                        issue = item.error?.localizedDescription ?? "Could not play this transition."
                    }
            } else {
                ProgressView("Preparing playback…").controlSize(.small)
            }
        }
        .task {
            do {
                let item = try await VideoMerge.boundaryPlayback(inputs, before: index, options: options)
                try Task.checkCancellation()
                player = AVPlayer(playerItem: item)
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

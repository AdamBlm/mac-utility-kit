import AppKit
import SwiftUI
import UtilityCore

struct EjectDisksDraft {
    var devices: [EjectDevice] = []
    var selected: Set<EjectTarget> = []
    var outcomes: [EjectOutcome] = []
    var loading = false
    var ejecting = false
    var refreshPending = false
    var error: String?
}

struct EjectDisksView: View {
    @Binding var draft: EjectDisksDraft
    @State private var confirmation: [EjectTarget] = []
    @State private var confirmsEject = false

    private var isBusy: Bool { draft.loading || draft.ejecting }

    var body: some View {
        InteractiveToolLayout(tool: .ejectAllDisks) { palette in
            WorkspaceSection("Devices", palette: palette) {
                inventory
            }
            if !draft.outcomes.isEmpty {
                WorkspaceSection("Results", palette: palette) {
                    outcomes
                }
            }
        }
        .onAppear { scheduleRefresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            scheduleRefresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            scheduleRefresh()
        }
        .confirmationDialog("Eject selected devices?", isPresented: $confirmsEject, titleVisibility: .visible) {
            Button(confirmation.count == 1 ? "Eject Device" : "Eject Devices") { perform(confirmation) }
        } message: {
            Text(confirmation.map(\.name).joined(separator: ", "))
        }
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise", action: scheduleRefresh)
                    .disabled(isBusy)
                if isBusy {
                    ProgressView(draft.ejecting ? "Ejecting…" : "Checking disks…").controlSize(.small)
                }
                Spacer()
                if !draft.devices.isEmpty {
                    Button(draft.selected.count == draft.devices.count ? "Clear Selection" : "Select All") {
                        draft.selected = draft.selected.count == draft.devices.count ? [] : Set(draft.devices.map(\.id))
                    }
                    .disabled(isBusy)
                }
            }
            if let error = draft.error {
                Text(error).font(.callout).foregroundStyle(.red)
            } else if draft.devices.isEmpty && !isBusy {
                Text("No eligible external disks or mounted disk images.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(draft.devices) { device in
                Divider()
                deviceRow(device)
            }
            if !draft.devices.isEmpty {
                Button("Eject Selected Devices", systemImage: "eject.fill") {
                    confirmation = draft.devices.map(\.id).filter { draft.selected.contains($0) }
                    confirmsEject = !confirmation.isEmpty
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || draft.selected.isEmpty)
            }
        }
    }

    private func deviceRow(_ device: EjectDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { draft.selected.contains(device.id) }, set: { enabled in
                if enabled { draft.selected.insert(device.id) } else { draft.selected.remove(device.id) }
            })) {
                Label(device.name, systemImage: device.isDiskImage ? "opticaldiscdrive" : "externaldrive")
                    .font(.headline).lineLimit(1).help(device.name)
            }
            .toggleStyle(.checkbox)
            if device.volumes.isEmpty {
                Text("No mounted volumes").font(.callout).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            ForEach(device.volumes) { volume in
                HStack {
                    Label(volume.name, systemImage: "externaldrive")
                        .lineLimit(1).help(volume.mount.path)
                    Spacer()
                    Button("Unmount") { perform([volume.id]) }
                        .accessibilityLabel("Unmount \(volume.name)")
                }
                .padding(.leading, 20)
                .font(.callout)
            }
        }
        .disabled(isBusy)
    }

    private var outcomes: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(draft.outcomes) { outcome in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(outcome.id.name).font(.headline)
                        Text(message(outcome.status)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .busy = outcome.status {
                        Button("Retry") { perform([outcome.id]) }
                            .disabled(isBusy)
                    }
                }
            }
        }
    }

    private func message(_ status: EjectOutcome.Status) -> String {
        switch status {
        case .ejected: "Ejected"
        case .unmounted: "Unmounted"
        case .alreadyRemoved: "Already removed"
        case .busy(let detail):
            ["The disk is in use. Close open files or apps using it, then retry.", detail]
                .compactMap { $0 }.joined(separator: " ")
        case .failed(let message): message
        }
    }

    private func scheduleRefresh() {
        draft.refreshPending = true
        guard !isBusy else { return }
        draft.loading = true
        Task {
            defer { draft.loading = false }
            await reloadUntilCurrent()
        }
    }

    private func reloadUntilCurrent() async {
        repeat {
            draft.refreshPending = false
            await reload()
        } while draft.refreshPending && !Task.isCancelled
    }

    private func reload() async {
        do {
            let devices = try await EjectDisks.inventory()
            try Task.checkCancellation()
            guard !draft.refreshPending else { return }
            draft.devices = devices
            draft.selected.formIntersection(devices.map(\.id))
            draft.error = nil
        } catch is CancellationError {
        } catch {
            guard !draft.refreshPending else { return }
            draft.devices = []
            draft.selected.removeAll()
            draft.error = error.localizedDescription
        }
    }

    private func perform(_ targets: [EjectTarget]) {
        guard !isBusy, !targets.isEmpty else { return }
        draft.ejecting = true
        Task {
            defer { draft.ejecting = false }
            let results = await EjectDisks.perform(targets)
            for result in results {
                draft.outcomes.removeAll { $0.id == result.id }
                draft.outcomes.append(result)
            }
            await reloadUntilCurrent()
        }
    }
}

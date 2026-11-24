import AppKit
import SwiftUI
import UtilityCore

struct WiFiPasswordView: View {
    @State private var networks: [WiFiPassword.SavedNetwork] = []
    @State private var selectedID: WiFiPassword.SavedNetwork.ID?
    @State private var manualName = ""
    @State private var manualSecurity: QRPayload.Security = .wpa
    @State private var password = ""
    @State private var isRetrievedPassword = false
    @State private var hidden = false
    @State private var revealed = false
    @State private var qr: Preview?
    @State private var message: String?
    @State private var inventory: Task<Void, Never>?
    @State private var lookup: Task<Void, Never>?

    private struct Preview {
        let payload: Data
        let image: CGImage
    }

    private var selected: WiFiPassword.SavedNetwork? { networks.first { $0.id == selectedID } }

    private var security: QRPayload.Security? {
        guard let selected else { return selectedID == nil ? manualSecurity : nil }
        if case .shareable(let value) = selected.security { return value }
        return nil
    }

    private var payload: QRPayload? {
        guard let security else { return nil }
        return .wiFi(name: selected?.name ?? manualName, security: security, password: password, hidden: hidden)
    }

    private func isCurrent(_ preview: Preview) -> Bool {
        guard let payload, let bytes = try? payload.encodedBytes() else { return false }
        return preview.payload == bytes
    }

    var body: some View {
        InteractiveToolLayout(tool: .wifiPasswordQR) { palette in
            WorkspaceSection("Network", palette: palette) {
                HStack {
                    Picker("Source", selection: Binding(get: { selectedID }, set: { selectNetwork($0) })) {
                        Text("Enter manually").tag(WiFiPassword.SavedNetwork.ID?.none)
                        ForEach(networks) { network in
                            Text(networkLabel(network)).tag(Optional(network.id))
                        }
                    }
                    Button("Refresh saved networks", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly)
                        .help("Refresh saved networks")
                        .disabled(inventory != nil || lookup != nil)
                    if inventory != nil {
                        ProgressView().controlSize(.small).accessibilityLabel("Reading saved networks")
                    }
                }
                if networks.isEmpty && inventory == nil {
                    Text("macOS hasn’t shared saved network names with this app. Enter the network details manually.")
                        .foregroundStyle(.secondary)
                }

                if let selected {
                    if case .unsupported(let reason) = selected.security {
                        Text(reason).foregroundStyle(.secondary)
                    } else if let security {
                        Text(security.rawValue).foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Network name (SSID)", text: Binding(get: { manualName }, set: { name in
                        if !manualName.utf8.elementsEqual(name.utf8) { clearCredentials() }
                        manualName = name
                    }))
                    Picker("Security", selection: $manualSecurity) {
                        ForEach(QRPayload.Security.allCases, id: \.self) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .onChange(of: manualSecurity) { clearCredentials() }
                }

                if let security {
                    Toggle("Hidden network", isOn: $hidden)
                        .onChange(of: hidden) { qr = nil }
                    if security != .open { passwordControls }
                    Button("Show Wi-Fi QR", action: generate)
                        .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                        .disabled((selected?.name ?? manualName).isEmpty || (security != .open && password.isEmpty))
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }

            if let qr, isCurrent(qr) {
                WorkspaceSection("Wi-Fi QR", palette: palette) {
                    Image(decorative: qr.image, scale: 1).resizable().interpolation(.none)
                        .frame(width: 200, height: 200).accessibilityLabel("Network connection QR code")
                    if security != .open {
                        Text("Anyone with this code can read the network password.")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Copy QR") { copyQR(qr) }
                        Button("Export PNG…") { exportQR(qr) }
                        Button("Hide QR") { self.qr = nil }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onDisappear {
            inventory?.cancel()
            inventory = nil
            clearCredentials()
        }
    }

    private var passwordControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Wi-Fi password", text: Binding(
                get: { password },
                set: { value in
                    if !password.utf8.elementsEqual(value.utf8) { qr = nil }
                    password = value
                    isRetrievedPassword = false
                }
            ))
                .disabled(lookup != nil)
            if selected != nil {
                Text("macOS controls access to saved passwords and may ask you to authorize this lookup.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if selected != nil {
                    Button("Look Up Saved Password", systemImage: "key.fill", action: lookUp)
                        .disabled(lookup != nil || inventory != nil)
                }
                if lookup != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Looking up saved password")
                    Button("Cancel Look Up") { cancelLookup() }
                }
                if !password.isEmpty {
                    Button(revealed ? "Hide Password" : "Reveal Password") { revealed.toggle() }
                    Button("Copy Password") { copyPassword() }
                    Button("Clear Password") { clearCredentials() }
                }
            }
            if revealed { Text(password).font(.body.monospaced()).textSelection(.disabled) }
        }
    }

    private func networkLabel(_ network: WiFiPassword.SavedNetwork) -> String {
        switch network.security {
        case .shareable(let security): "\(network.name) · \(security.rawValue)"
        case .unsupported: "\(network.name) · Unsupported security"
        }
    }

    private func refresh() {
        guard inventory == nil else { return }
        inventory = Task {
            let available = await WiFiPassword.savedNetworks()
            guard !Task.isCancelled else { return }
            var refreshIssue: String?
            if isRetrievedPassword, let selected {
                do {
                    _ = try WiFiPassword.credentialSSID(for: selected, in: available)
                } catch {
                    clearCredentials()
                    refreshIssue = error.localizedDescription
                }
            }
            networks = available
            if let selectedID, !networks.contains(where: { $0.id == selectedID }) { selectNetwork(nil) }
            if let refreshIssue { message = refreshIssue }
            inventory = nil
        }
    }

    private func lookUp() {
        guard let selected, lookup == nil, inventory == nil else { return }
        message = nil
        revealed = false
        lookup = Task {
            do {
                let value = try await WiFiPassword.savedPassword(for: selected)
                try Task.checkCancellation()
                guard selectedID == selected.id else { return }
                password = value
                isRetrievedPassword = true
                qr = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            lookup = nil
        }
    }

    private func cancelLookup() {
        lookup?.cancel()
        lookup = nil
    }

    private func clearCredentials() {
        cancelLookup()
        password = ""
        isRetrievedPassword = false
        revealed = false
        qr = nil
        message = nil
    }

    private func selectNetwork(_ id: WiFiPassword.SavedNetwork.ID?) {
        guard selectedID != id else { return }
        clearCredentials()
        hidden = false
        selectedID = id
    }

    private func generate() {
        guard let payload, case .wiFi(let name, let security, let password, let hidden) = payload else { return }
        do {
            qr = try Preview(payload: payload.encodedBytes(), image: WiFiPassword.qr(
                name: name, security: security, password: password, hidden: hidden
            ))
            message = nil
        } catch {
            qr = nil
            message = error.localizedDescription
        }
    }

    private func copyPassword() {
        let item = NSPasteboardItem()
        if item.setString(password, forType: .string) { writePrivateClipboardItem(item) }
    }

    private func copyQR(_ preview: Preview) {
        guard isCurrent(preview) else { return }
        do {
            let item = NSPasteboardItem()
            if item.setData(try QRTools.png(preview.image), forType: .png) { writePrivateClipboardItem(item) }
        } catch {
            message = error.localizedDescription
        }
    }

    private func writePrivateClipboardItem(_ item: NSPasteboardItem) {
        message = ConcealedClipboard.write(item) ? "Copied to clipboard." : "Could not copy to the clipboard."
    }

    private func exportQR(_ preview: Preview) {
        guard isCurrent(preview) else { return }
        do { try DeveloperToolFiles.save(QRTools.png(preview.image), as: "Wi-Fi QR.png") }
        catch { message = error.localizedDescription }
    }
}

import SwiftUI
import UtilityCore

struct JWTDecoderDraft {
    var algorithm = JWTDecoder.Algorithm.hs256
    var encoding = JWTDecoder.KeyEncoding.utf8
}

struct JWTDecoderView: View {
    @Binding var draft: JWTDecoderDraft
    @State private var token = ""
    @State private var secret = ""
    @State private var showsVerification = false
    @State private var verification: Verification?
    @State private var decoded: Result<JWTDecoder.Token, Error>?

    private enum Verification {
        case matched
        case failed(String)

        var passed: Bool {
            if case .matched = self { return true }
            return false
        }
    }

    var body: some View {
        InteractiveToolLayout(tool: .jwtDecoder) { palette in
            WorkspaceSection("Token", palette: palette) {
                TextEditor(text: Binding(get: { token }, set: {
                    token = $0
                    secret = ""
                    decoded = nil
                    verification = nil
                }))
                .font(.body.monospaced())
                .frame(minHeight: 118, maxHeight: 160)
                .accessibilityLabel("JWT compact token")
                if !token.isEmpty && decoded == nil {
                    ProgressView("Decoding…").controlSize(.small)
                }
                if case .failure(let error) = decoded {
                    Label(error.localizedDescription, systemImage: "exclamationmark.circle").font(.callout)
                }
            }
            if case .success(let result) = decoded {
                WorkspaceSection("Signature", palette: palette) {
                    signatureControls(result)
                }
                WorkspaceSection(verification?.passed == true ? "Time Claims" : "Time Claims · Unverified", palette: palette) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        timeClaims(result, now: context.date)
                    }
                }
                WorkspaceSection("Header", palette: palette) {
                    code(result.header)
                }
                WorkspaceSection(verification?.passed == true ? "Payload" : "Payload · Unverified", palette: palette) {
                    code(result.payload)
                }
            }
        }
        .task(id: token) {
            let input = token
            guard !input.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                let job = Task.detached(priority: .userInitiated) { try JWTDecoder.decode(input) }
                let result = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                if !Task.isCancelled { decoded = .success(result) }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { decoded = .failure(error) }
            }
        }
        .onChange(of: draft.algorithm) { verification = nil }
        .onChange(of: draft.encoding) { verification = nil }
        .onChange(of: showsVerification) {
            if !showsVerification {
                secret = ""
                verification = nil
            }
        }
        .onDisappear {
            token = ""
            secret = ""
            decoded = nil
            verification = nil
            showsVerification = false
        }
    }

    @ViewBuilder
    private func signatureControls(_ result: JWTDecoder.Token) -> some View {
        if verification?.passed == true {
            Label("Signature verified with the supplied key", systemImage: "checkmark.shield")
                .font(.callout)
            Text("Issuer and audience have not been checked.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label(result.algorithm == "none" ? "Unsigned token · claims unverified" : "Claims unverified",
                  systemImage: "exclamationmark.shield")
                .font(.callout)
        }
        Text("Header algorithm \(result.algorithm.debugDescription)").font(.caption.monospaced()).foregroundStyle(.secondary)
        if JWTDecoder.Algorithm(rawValue: result.algorithm) != nil {
            DisclosureGroup("Verify HMAC Signature", isExpanded: $showsVerification) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow("Algorithm") {
                        Picker("Verification algorithm", selection: $draft.algorithm) {
                            ForEach(JWTDecoder.Algorithm.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                    SettingRow("Key format") {
                        Picker("Key format", selection: $draft.encoding) {
                            ForEach(JWTDecoder.KeyEncoding.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                    SecureField("Secret key", text: Binding(get: { secret }, set: {
                        secret = $0
                        verification = nil
                    }))
                    Button("Verify", systemImage: "checkmark.shield") { verify(result) }
                        .disabled(secret.isEmpty)
                    if case .failed(let message) = verification {
                        Label(message, systemImage: "xmark.circle").font(.callout)
                    }
                }
                .padding(.top, 6)
            }
        } else if result.algorithm != "none" {
            Text("Signature verification supports HS256, HS384, and HS512.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func timeClaims(_ result: JWTDecoder.Token, now: Date) -> some View {
        Text(result.timeWindow(at: now).rawValue).font(.callout)
        ForEach([("Issued at", result.issuedAt), ("Not before", result.notBefore), ("Expires", result.expires)],
                id: \.0) { label, value in
            if let value {
                SettingRow(label) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let date = value.date {
                            Text(date.formatted(date: .abbreviated, time: .standard))
                        }
                        Text("\(value.source) s since Unix epoch")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func code(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
    }

    private func verify(_ result: JWTDecoder.Token) {
        do {
            let matches = try JWTDecoder.verify(result, algorithm: draft.algorithm, secret: secret, encoding: draft.encoding)
            verification = matches ? .matched : .failed("The signature does not match the supplied key.")
        } catch {
            verification = .failed(error.localizedDescription)
        }
    }
}

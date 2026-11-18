import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct AppDamageDiagnosisView: View {
    @State private var source: URL?
    @State private var report: AppDamageDiagnosis.Report?
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        InteractiveToolLayout(tool: .appDamageDiagnosis) { palette in
            WorkspaceSection("Application", palette: palette) {
                HStack {
                    Button("Choose App…", systemImage: "folder", action: choose)
                    if let source {
                        Text(source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if task != nil {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking application")
                        Button("Cancel", action: cancel)
                    }
                }
                Text("Inspect the app’s signature and local macOS policy without opening the app.")
                    .foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let report {
                WorkspaceSection("Diagnosis", palette: palette) {
                    Text(title(report.verdict)).font(.headline)
                    Text(guidance(report.verdict)).foregroundStyle(.secondary)
                    HStack {
                        if report.verdict == .policyDenied || report.verdict == .unverified {
                            Button("Open Privacy & Security", systemImage: "gearshape") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        if let help = URL(string: "https://support.apple.com/en-us/102445") {
                            Link("Apple Support", destination: help)
                        }
                    }
                }
                WorkspaceSection("Checks", palette: palette) {
                    diagnostic("Declared bundle identifier", report.bundleIdentifier)
                    diagnostic("Signing identifier", report.signingIdentifier)
                    diagnostic("Embedded signing certificate", report.certificateName)
                    diagnostic("Developer team", report.teamIdentifier)
                    diagnostic("Signature", signatureText(report.signature))
                    if let signatureDetail = report.signatureDetail { diagnostic("Signing detail", signatureDetail) }
                    diagnostic("Download quarantine", report.quarantined.map { $0 ? "Present" : "Absent" })
                    diagnostic("Local policy", report.assessment.allowsExecution.map { $0 ? "Accepted" : "Denied" })
                    if let authority = report.assessment.authority { diagnostic("Policy authority", authority) }
                    if let detail = report.assessment.detail { diagnostic("Assessment detail", detail) }
                }
            }
        }
        .onDisappear(perform: cancel)
    }

    private func diagnostic(_ label: String, _ value: String?) -> some View {
        SettingRow(label) {
            Text(value ?? "Unavailable").foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func choose() {
        guard let url = DeveloperToolFiles.choose(allowedTypes: [.applicationBundle]) else { return }
        cancel()
        source = url
        report = nil
        error = nil
        task = Task {
            do {
                let result = try await AppDamageDiagnosis.inspect(url)
                try Task.checkCancellation()
                report = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            task = nil
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }

    private func title(_ verdict: AppDamageDiagnosis.Verdict) -> String {
        switch verdict {
        case .checksPassed: "Signing and policy checks passed"
        case .damagedOrModified: "The signed contents appear damaged or modified"
        case .unverified: "No verifiable signature was found"
        case .policyDenied: "This Mac’s policy rejected the app"
        case .indeterminate: "The available checks could not determine the cause"
        }
    }

    private func signatureText(_ signature: AppDamageDiagnosis.Signature) -> String {
        switch signature {
        case .verified: "Integrity verified"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid"
        case .indeterminate: "Indeterminate"
        }
    }

    private func guidance(_ verdict: AppDamageDiagnosis.Verdict) -> String {
        switch verdict {
        case .checksPassed: "If the alert persists, contact the developer with the exact macOS message."
        case .damagedOrModified: "Replace this copy with a fresh download from the developer or the App Store."
        case .unverified, .policyDenied: "Look for a verified copy from the developer or the App Store. Privacy & Security shows any actions macOS makes available for this app."
        case .indeterminate: "Review the check details and contact the developer if the alert persists."
        }
    }
}

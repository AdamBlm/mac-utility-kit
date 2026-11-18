import AppKit
import SwiftUI
import UtilityCore

struct CaptureTextDraft {
    var language: String?
    var autoCopy = false
    var image: CGImage?
    var text = ""
}

struct CaptureTextView: View {
    @Binding var draft: CaptureTextDraft
    let onHandoff: (CGImage, String?) -> Void

    @State private var selector = ScreenRegionSelector()
    @State private var task: Task<Void, Never>?
    @State private var status: String?
    @State private var permissionNeeded = false
    @State private var languages: [String] = []

    var body: some View {
        InteractiveToolLayout(tool: .captureText) { palette in
            WorkspaceSection("Capture", palette: palette) {
                Text("Drag a rectangle around the text on your screen, then press Return.")
                    .font(.callout).foregroundStyle(.secondary)
                SettingRow("Language") {
                    Picker("Recognition language", selection: $draft.language) {
                        Text("Auto-detect").tag(nil as String?)
                        ForEach(languages, id: \.self) { language in
                            Text(Locale.current.localizedString(forIdentifier: language) ?? language)
                                .tag(Optional(language))
                        }
                    }
                    .labelsHidden()
                }
                .disabled(task != nil)
                Toggle("Copy recognized text immediately", isOn: $draft.autoCopy)
                    .disabled(task != nil)
                HStack {
                    Button(draft.image == nil ? "Select Screen Region" : "Capture Again",
                           systemImage: "selection.pin.in.out", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(task != nil)
                    if task != nil {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { task?.cancel() }
                    }
                }
                if permissionNeeded {
                    Text("Allow Mac Utility Kit in System Settings → Privacy & Security → Screen & System Audio Recording. Reopen the app if macOS asks.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open System Settings", systemImage: "gear") {
                        ScreenCapturePermission.openSettings()
                    }
                }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
            }

            if let image = draft.image {
                WorkspaceSection("Recognized Text", palette: palette) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .accessibilityLabel("Captured screen region")
                    if draft.text.isEmpty {
                        Text("No text detected. Try a tighter region or a different language.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(draft.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 240)
                    }
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") {
                            DeveloperToolFiles.copy(draft.text)
                            status = "Copied recognized text."
                        }
                        .disabled(draft.text.isEmpty)
                        Button("Open in Extract Text", systemImage: "arrow.turn.up.right") {
                            onHandoff(image, draft.language)
                        }
                        Spacer()
                        Button("Clear") {
                            draft.image = nil
                            draft.text = ""
                            status = nil
                        }
                    }
                }
                .disabled(task != nil)
            }
        }
        .task { languages = (try? TextExtraction.languages()) ?? [] }
        .onDisappear { task?.cancel() }
        .onChange(of: draft.language) {
            if let image = draft.image, task == nil {
                recognizeAgain(image)
            }
        }
    }

    private func start() {
        guard task == nil else { return }
        permissionNeeded = false
        status = nil
        // Request access only as a result of the user pressing Select or Capture Again.
        if !ScreenCapturePermission.request() {
            permissionNeeded = true
            return
        }
        let language = draft.language
        let shouldCopy = draft.autoCopy
        task = Task {
            defer { task = nil }
            guard let selection = await selector.select() else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let image = try await ScreenImageCapture.capture(region: selection.region, displays: selection.displays)
                let text = try await TextExtraction.recognizeImage(image, language: language)
                try Task.checkCancellation()
                draft.image = image
                draft.text = text
                if shouldCopy, !text.isEmpty {
                    DeveloperToolFiles.copy(text)
                    status = "Copied recognized text."
                }
            } catch is CancellationError {
                return
            } catch {
                if !CGPreflightScreenCaptureAccess() { permissionNeeded = true }
                status = error.localizedDescription
            }
        }
    }

    private func recognizeAgain(_ image: CGImage) {
        let language = draft.language
        task = Task {
            defer { task = nil }
            do {
                let text = try await TextExtraction.recognizeImage(image, language: language)
                try Task.checkCancellation()
                draft.text = text
                status = nil
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

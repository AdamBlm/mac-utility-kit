import AppKit
import SwiftUI
import UtilityCore

struct HashGeneratorDraft {
    var text = ""
    var algorithm: HashAlgorithm = .sha256
    var expected = ""
    var checksumList = ""
    var usesChecksumList = false
    var files: [URL] = []
    var mode: Mode = .text

    enum Mode: String, CaseIterable { case text = "Text", files = "Files" }
}

struct HashGeneratorView: View {
    @Binding var draft: HashGeneratorDraft
    @State private var results: [DigestRow] = []
    @State private var running = false
    @State private var resultsInput: Input?
    @State private var exportError: String?
    @State private var fileRevision = UUID()

    private struct Input: Equatable {
        let text: String
        let files: [URL]
        let algorithm: HashAlgorithm
        let mode: HashGeneratorDraft.Mode
        let fileRevision: UUID?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.mode == rhs.mode && lhs.algorithm == rhs.algorithm && lhs.files == rhs.files && lhs.fileRevision == rhs.fileRevision
                && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }

    private struct DigestRow: Identifiable {
        let id: Int
        let name: String
        let digest: String?
        let error: String?
    }

    var body: some View {
        let input = Input(
            text: draft.mode == .text ? draft.text : "",
            files: draft.mode == .files ? draft.files : [],
            algorithm: draft.algorithm, mode: draft.mode, fileRevision: draft.mode == .files ? fileRevision : nil
        )
        let currentResults = resultsInput == input ? results : []
        let isHashing = (resultsInput != input || running) && (input.mode == .text || !input.files.isEmpty)
        let usesChecksumList = input.mode == .files && draft.usesChecksumList
        let expectations = usesChecksumList && !draft.checksumList.isEmpty
            ? Result { try HashChecksumList(draft.checksumList, algorithm: input.algorithm).expectations(for: input.files) }
            : nil
        InteractiveToolLayout(tool: .hashGenerator) { palette in
            WorkspaceSection("Input", palette: palette) {
                Picker("Input", selection: $draft.mode) {
                    ForEach(HashGeneratorDraft.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if draft.mode == .text {
                    TextEditor(text: $draft.text)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .workspaceInset(palette)
                        .accessibilityLabel("Text to hash as UTF-8")
                    Text("Text is hashed as UTF-8, including whitespace.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Choose files…", systemImage: "folder") { chooseFiles() }
                        if !draft.files.isEmpty {
                            Button("Rehash Files", systemImage: "arrow.clockwise") { fileRevision = UUID() }
                                .disabled(isHashing)
                        }
                    }
                    ForEach(draft.files, id: \.self) { file in
                        HStack {
                            Text(file.lastPathComponent).help(file.path)
                            Spacer()
                            Button("Remove \(file.lastPathComponent)", systemImage: "xmark") {
                                draft.files.removeAll { $0 == file }
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
                SettingRow("Algorithm") {
                    Picker("Algorithm", selection: $draft.algorithm) {
                        ForEach(HashAlgorithm.allCases, id: \.self) { algorithm in
                            Text(algorithm.rawValue + (algorithm.isLegacy ? " (legacy)" : "")).tag(algorithm)
                        }
                    }
                    .labelsHidden()
                }
                if input.mode == .files {
                    Toggle("Verify with a checksum list", isOn: $draft.usesChecksumList)
                }
                if usesChecksumList {
                    TextEditor(text: $draft.checksumList)
                        .font(.body.monospaced())
                        .frame(minHeight: 78, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .workspaceInset(palette)
                        .accessibilityLabel("Expected checksums and filenames")
                    Text("Paste output from shasum or a GNU checksum command. Paths match queued files only.")
                        .font(.callout).foregroundStyle(.secondary)
                    if case .failure(let error)? = expectations {
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Expected hex digest (optional)", text: $draft.expected)
                        .font(.body.monospaced())
                }
            }
            WorkspaceSection("Results", palette: palette) {
                if isHashing { ProgressView("Hashing…").controlSize(.small) }
                if currentResults.isEmpty && !isHashing {
                    Text("Choose one or more files to generate digests.").foregroundStyle(.secondary)
                }
                ForEach(currentResults) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(row.name).font(.headline)
                        if let digest = row.digest {
                            Text(digest).font(.body.monospaced()).textSelection(.enabled)
                            HStack {
                                if let expectation = try? expectations?.get()[row.id] {
                                    Text(verification(digest, expectation: expectation))
                                        .font(.callout).foregroundStyle(.secondary)
                                } else if !usesChecksumList, !draft.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(verification(digest, expectation: .digest(draft.expected)))
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Copy digest", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(digest) }
                            }
                        } else if let error = row.error {
                            Text(error).font(.callout).foregroundStyle(.red)
                        }
                    }
                }
                if !currentResults.isEmpty && !isHashing {
                    if input.mode == .files {
                        Text("Digests reflect the last read. Rehash Files to check for changes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        if input.mode == .files, currentResults.allSatisfy({ $0.digest != nil }) {
                            Button("Copy checksum list", systemImage: "doc.on.doc") { copyChecksums(input) }
                            Button("Export checksum list…", systemImage: "square.and.arrow.up") {
                                export(input, asChecksumList: true)
                            }
                        } else {
                            Button("Copy results", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(report) }
                            Button("Export results…", systemImage: "square.and.arrow.up") { export(input) }
                        }
                    }
                    if input.mode == .files, currentResults.allSatisfy({ $0.digest != nil }),
                       HashChecksumList.usesAbsolutePaths(for: input.files) {
                        Text("This checksum list includes full file paths.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let exportError, resultsInput == input { Text(exportError).font(.callout).foregroundStyle(.red) }
            }
        }
        .task(id: input) { await calculate(input) }
    }

    private var report: String {
        ([draft.algorithm.rawValue] + results.map { row in
            let name = row.name.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            return "\(row.digest ?? row.error ?? "")  \(name)"
        }).joined(separator: "\n") + "\n"
    }

    private func calculate(_ input: Input) async {
        guard !Task.isCancelled else { return }
        results = []
        resultsInput = input
        exportError = nil
        running = input.mode == .text || !input.files.isEmpty
        defer { if !Task.isCancelled { running = false } }
        if input.mode == .text {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let digest = try await HashGenerator.text(input.text, algorithm: input.algorithm)
                guard !Task.isCancelled else { return }
                results = [DigestRow(id: 0, name: "Text", digest: digest, error: nil)]
            } catch {
                guard !Task.isCancelled else { return }
                results = [DigestRow(id: 0, name: "Text", digest: nil, error: error.localizedDescription)]
            }
            return
        }
        for (index, file) in input.files.enumerated() {
            let row: DigestRow
            do {
                let digest = try await HashGenerator.file(file, algorithm: input.algorithm)
                row = DigestRow(id: index, name: file.lastPathComponent, digest: digest, error: nil)
            } catch {
                row = DigestRow(id: index, name: file.lastPathComponent, digest: nil, error: error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            results.append(row)
        }
    }

    private func verification(_ digest: String, expectation: HashChecksumList.Expectation) -> String {
        let expected: String
        switch expectation {
        case .digest(let value): expected = value
        case .missing: return "No expected digest for this file"
        case .ambiguous: return "Multiple checksum matches"
        }
        return switch HashGenerator.verify(digest, expected: expected, algorithm: draft.algorithm) {
        case .match: "Matches expected digest"
        case .mismatch: "Digest does not match"
        case .invalid: "Enter \(draft.algorithm.hexLength) hex characters"
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !draft.files.contains(url) { draft.files.append(url) }
        fileRevision = UUID()
    }

    private func copyChecksums(_ input: Input) {
        do {
            DeveloperToolFiles.copy(try checksumList(input))
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func checksumList(_ input: Input) throws -> String {
        try HashChecksumList.format(results.compactMap(\.digest), for: input.files, algorithm: input.algorithm)
    }

    private func export(_ input: Input, asChecksumList: Bool = false) {
        do {
            let data = asChecksumList ? try checksumList(input) : report
            let suffix = input.algorithm.rawValue.lowercased().replacingOccurrences(of: "-", with: "")
            try DeveloperToolFiles.save(Data(data.utf8), as: asChecksumList ? "checksums.\(suffix)" : "digests.txt")
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}

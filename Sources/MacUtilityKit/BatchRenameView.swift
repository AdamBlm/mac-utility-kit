import AppKit
import SwiftUI
import UtilityCore

struct BatchRenameDraft {
    struct Entry: Identifiable {
        let id = UUID()
        var url: URL
        var isIncluded = true
    }

    struct CompletedRun: Sendable {
        let receipt: BatchRenameReceipt
        let changes: [BatchRenameChange]
    }

    var files: [Entry] = []
    var options = BatchRenameOptions()
    var completed: CompletedRun?
    var isRenaming = false
}

struct BatchRenameView: View {
    @Binding var draft: BatchRenameDraft
    @State private var dropping = false
    @State private var message: String?
    @State private var confirm = false

    @State private var preview: Preview?
    @State private var proposed: BatchRenamePlan?
    private var busy: Bool { draft.isRenaming }

    private struct PreviewInput: Equatable, Sendable {
        let selected: [URL]
        let options: BatchRenameOptions
    }

    private struct Preview {
        let input: PreviewInput
        let result: Result<BatchRenamePlan, any Error>
    }

    var body: some View {
        let input = PreviewInput(selected: draft.files.filter(\.isIncluded).map(\.url), options: draft.options)
        let plan = preview?.input == input ? preview?.result : nil
        InteractiveToolLayout(tool: .batchRename) { palette in
            rulesSection(palette).disabled(busy)
            previewSection(palette, plan: plan).disabled(busy)
            if busy {
                ProgressView().controlSize(.small)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: input) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = await Task.detached {
                    Result { try BatchRename.plan(files: input.selected, options: input.options) }
                }.value
                try Task.checkCancellation()
                preview = Preview(input: input, result: result)
            } catch {}
        }
        .confirmationDialog("Rename the selected files?", isPresented: $confirm, titleVisibility: .visible, presenting: proposed) { confirmed in
            Button("Rename Files") { apply(confirmed) }
        }
    }

    private func rulesSection(_ palette: WorkspacePalette) -> some View {
        WorkspaceSection("Rules", palette: palette) {
            Toggle("Include file extensions when applying rules", isOn: $draft.options.includesExtension)
            if draft.options.rules.contains(where: { $0.kind == .number }) {
                SettingRow("Numbering order") {
                    Picker("Numbering order", selection: $draft.options.numberingOrder) {
                        ForEach(BatchRenameOptions.NumberingOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .labelsHidden()
                }
            }
            ForEach($draft.options.rules) { $rule in
                Divider()
                HStack(spacing: 10) {
                    Picker("Rule", selection: $rule.kind) {
                        ForEach(BatchRenameRule.Kind.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Spacer()
                    Button("Move up", systemImage: "chevron.up") { move(rule.id, by: -1) }
                        .labelStyle(.iconOnly)
                        .disabled(draft.options.rules.first?.id == rule.id)
                    Button("Move down", systemImage: "chevron.down") { move(rule.id, by: 1) }
                        .labelStyle(.iconOnly)
                        .disabled(draft.options.rules.last?.id == rule.id)
                    Button("Remove rule", systemImage: "trash") {
                        draft.options.rules.removeAll { $0.id == rule.id }
                    }
                    .labelStyle(.iconOnly)
                }
                ruleSettings($rule)
            }
            Button("Add Rule", systemImage: "plus") { draft.options.rules.append(BatchRenameRule()) }
        }
    }

    @ViewBuilder
    private func ruleSettings(_ rule: Binding<BatchRenameRule>) -> some View {
        switch rule.wrappedValue.kind {
        case .replace:
            HStack {
                TextField("Find", text: rule.search)
                TextField("Replace with", text: rule.replacement)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Match case", isOn: rule.caseSensitive)
                Toggle("Regular expression", isOn: rule.regularExpression)
            }
        case .capitalization:
            SettingRow("Case") {
                Picker("Case", selection: rule.capitalization) {
                    ForEach(BatchRenameRule.Capitalization.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
            }
        case .number:
            SettingRow("Start") { integerField("Start", rule.start) }
            SettingRow("Increment") { integerField("Increment", rule.increment) }
            SettingRow("Padding") { Stepper("\(rule.padding.wrappedValue) digits", value: rule.padding, in: 1...12) }
            placementSettings(rule)
        case .date:
            SettingRow("Date source") {
                Picker("Date source", selection: rule.dateSource) {
                    ForEach(BatchRenameRule.DateSource.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
            }
            SettingRow("Date format") { TextField("Date format", text: rule.dateFormat).textFieldStyle(.roundedBorder) }
            placementSettings(rule)
        }
    }

    @ViewBuilder
    private func placementSettings(_ rule: Binding<BatchRenameRule>) -> some View {
        SettingRow("Placement") {
            Picker("Placement", selection: rule.placement) {
                ForEach(BatchRenameRule.Placement.allCases, id: \.self) { Text($0.rawValue) }
            }
            .labelsHidden()
        }
        SettingRow("Separator") { TextField("Separator", text: rule.separator).textFieldStyle(.roundedBorder) }
    }

    private func integerField(_ label: String, _ value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 82)
    }

    private func previewSection(_ palette: WorkspacePalette, plan: Result<BatchRenamePlan, any Error>?) -> some View {
        let changes = (try? plan?.get().changes) ?? []
        let destinations = Dictionary(changes.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first })
        let canOrderQueue = draft.files.count > 1 && draft.options.numberingOrder == .queue
            && draft.options.rules.contains { $0.kind == .number }
        let hasChanges = changes.contains { $0.source.path.utf8.elementsEqual($0.destination.path.utf8) == false }
        return WorkspaceSection("File Preview", palette: palette) {
            HStack {
                Button("Add Files…", systemImage: "folder") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { add(panel.urls) }
                }
                if draft.files.isEmpty {
                    Text("or drop files here").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Clear Queue") { draft.files = [] }
                }
                Spacer()
                if draft.completed != nil {
                    Button("Undo Last Rename", systemImage: "arrow.uturn.backward") { undo() }
                }
                Button("Rename Files…") {
                    proposed = try? plan?.get()
                    confirm = proposed != nil
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
            }
            if case .failure(let error)? = plan {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            ForEach($draft.files) { $entry in
                let id = entry.id
                let name = entry.url.lastPathComponent
                Divider()
                HStack {
                    Toggle("Include \(entry.url.lastPathComponent)", isOn: $entry.isIncluded).labelsHidden()
                    Text(entry.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.url.path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(entry.isIncluded ? destinations[entry.url]?.lastPathComponent ?? "—" : "Excluded")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if canOrderQueue {
                        Button("Move \(name) Up", systemImage: "chevron.up") { moveFile(id, by: -1) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(id == draft.files.first?.id)
                        Button("Move \(name) Down", systemImage: "chevron.down") { moveFile(id, by: 1) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(id == draft.files.last?.id)
                    }
                    Button("Remove file", systemImage: "xmark") {
                        draft.files.removeAll { $0.id == id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(palette.accent).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            !busy && add(urls)
        } isTargeted: {
            dropping = $0
        }
    }

    private func move(_ id: UUID, by distance: Int) {
        guard let index = draft.options.rules.firstIndex(where: { $0.id == id }),
              draft.options.rules.indices.contains(index + distance) else { return }
        draft.options.rules.swapAt(index, index + distance)
    }

    private func moveFile(_ id: UUID, by distance: Int) {
        guard !busy, let index = draft.files.firstIndex(where: { $0.id == id }),
              draft.files.indices.contains(index + distance) else { return }
        draft.files.swapAt(index, index + distance)
    }

    @discardableResult
    private func add(_ urls: [URL]) -> Bool {
        var added = false
        for input in urls where input.isFileURL {
            let url = input.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL.appendingPathComponent(input.lastPathComponent)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false,
                  !draft.files.contains(where: { $0.url == url }) else { continue }
            draft.files.append(BatchRenameDraft.Entry(url: url))
            added = true
        }
        if added { message = nil }
        return added
    }

    private func apply(_ plan: BatchRenamePlan) {
        guard !busy else { return }
        draft.isRenaming = true
        Task {
            defer { draft.isRenaming = false }
            do {
                let receipt = try await Task.detached { try plan.apply() }.value
                draft.completed = BatchRenameDraft.CompletedRun(receipt: receipt, changes: plan.changes)
                updateQueue(plan.changes.map { ($0.source, $0.destination) })
                message = "Files renamed."
            } catch { message = error.localizedDescription }
        }
    }

    private func undo() {
        guard !busy, let completed = draft.completed else { return }
        draft.isRenaming = true
        Task {
            defer { draft.isRenaming = false }
            do {
                try await Task.detached { try completed.receipt.undo() }.value
                updateQueue(completed.changes.map { ($0.destination, $0.source) })
                draft.completed = nil
                message = "Original filenames restored."
            } catch { message = error.localizedDescription }
        }
    }

    private func updateQueue(_ paths: [(URL, URL)]) {
        let updates = Dictionary(paths, uniquingKeysWith: { first, _ in first })
        for index in draft.files.indices {
            if let target = updates[draft.files[index].url] { draft.files[index].url = target }
        }
    }
}

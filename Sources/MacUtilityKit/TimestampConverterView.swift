import SwiftUI
import UtilityCore

private enum TimestampDirection: String, CaseIterable, Identifiable {
    case toDate = "Unix to Date"
    case toUnix = "Date to Unix"

    var id: Self { self }
}

struct TimestampConverterDraft {
    fileprivate var direction = TimestampDirection.toDate
    var unit = UnixTimestampUnit.seconds
    var timeZone = TimeZone.current.identifier
    var unixInput = ""
    var localInput = ""
    var selectedMatch: UnixMicrosecondTimestamp?
}

struct TimestampConverterView: View {
    @Binding var draft: TimestampConverterDraft
    @State private var pickerVisible = false
    @State private var filter = ""
    @State private var copied: String?

    private static let zones = Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC", TimeZone.current.identifier])).sorted()

    private var selectedZone: TimeZone { TimeZone(identifier: draft.timeZone) ?? .gmt }

    var body: some View {
        InteractiveToolLayout(tool: .timestampConverter) { palette in
            WorkspaceSection("Convert", palette: palette) {
                Picker("Conversion direction", selection: $draft.direction) {
                    ForEach(TimestampDirection.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                SettingRow("Unix unit") {
                    Picker("Unix unit", selection: $draft.unit) {
                        ForEach(UnixTimestampUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                SettingRow("Time zone") {
                    Button {
                        filter = ""
                        pickerVisible = true
                    } label: {
                        Label(draft.timeZone, systemImage: "globe")
                    }
                    .popover(isPresented: $pickerVisible, arrowEdge: .bottom) { zonePicker }
                }
                HStack {
                    if draft.direction == .toDate {
                        TextField("Unix timestamp", text: $draft.unixInput)
                            .accessibilityLabel("Unix timestamp in \(draft.unit.rawValue.lowercased())")
                    } else {
                        TextField("YYYY-MM-DD HH:MM:SS.ffffff", text: Binding(get: { draft.localInput }, set: {
                            draft.localInput = $0
                            draft.selectedMatch = nil
                        }))
                            .accessibilityLabel("Local date and time")
                    }
                    Button("Now", systemImage: "clock", action: useNow)
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            }
            if draft.direction == .toDate {
                if !draft.unixInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    WorkspaceSection("Result", palette: palette) { unixResult }
                }
            } else if !draft.localInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                WorkspaceSection("Result", palette: palette) { civilResult }
            }
            if let copied { Text(copied).font(.callout).foregroundStyle(.secondary) }
        }
        .onChange(of: draft.localInput) { copied = nil }
        .onChange(of: draft.unixInput) { copied = nil }
        .onChange(of: draft.timeZone) {
            draft.selectedMatch = nil
            copied = nil
        }
        .onChange(of: draft.direction) { copied = nil }
        .onChange(of: draft.unit) { copied = nil }
    }

    @ViewBuilder
    private var unixResult: some View {
        switch Result(catching: { try UnixMicrosecondTimestamp.parse(draft.unixInput, unit: draft.unit) }) {
        case .success(let timestamp): formattedResult(timestamp)
        case .failure(let error): failure(error.localizedDescription)
        }
    }

    @ViewBuilder
    private var civilResult: some View {
        switch Result(catching: { try TimestampConverter.resolveLocal(draft.localInput, in: selectedZone) }) {
        case .success(let matches):
            if matches.isEmpty {
                failure("This local time does not exist in \(draft.timeZone) because the clocks change.")
            } else if matches.count == 1, let onlyMatch = matches.first {
                formattedResult(onlyMatch.timestamp)
            } else {
                Text("This local time is repeated. Choose the occurrence by its UTC offset.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Occurrence", selection: $draft.selectedMatch) {
                    Text("Choose an occurrence").tag(UnixMicrosecondTimestamp?.none)
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                        Text(matches.count == 2
                             ? "\(index == 0 ? "Earlier" : "Later") · \(match.offset)"
                             : "\(index + 1) · \(match.offset)")
                        .tag(Optional(match.timestamp))
                    }
                }
                .onChange(of: draft.selectedMatch) { copied = nil }
                if let selected = draft.selectedMatch, matches.contains(where: { $0.timestamp == selected }) {
                    formattedResult(selected)
                }
            }
        case .failure(let error):
            failure(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func formattedResult(_ timestamp: UnixMicrosecondTimestamp) -> some View {
        switch Result(catching: { try TimestampConverter.display(timestamp, in: selectedZone) }) {
        case .success(let result):
            if draft.direction == .toDate {
                resultRow("Local date", value: result.local + " " + result.offset)
            } else {
                resultRow(draft.unit.rawValue, value: timestamp.formatted(in: draft.unit))
            }
            resultRow("ISO 8601", value: result.iso8601)
        case .failure(let error):
            failure(error.localizedDescription)
        }
    }

    private func resultRow(_ label: String, value: String) -> some View {
        SettingRow(label) {
            Text(value).font(.body.monospaced()).textSelection(.enabled)
            Spacer()
            Button("Copy \(label)", systemImage: "doc.on.doc") {
                DeveloperToolFiles.copy(value)
                copied = "\(label) copied."
            }
            .labelStyle(.iconOnly)
            .help("Copy \(label)")
        }
    }

    private func failure(_ message: String) -> some View {
        Text(message).font(.callout).foregroundStyle(.red)
    }

    private var zonePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find a time zone", text: $filter)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.zones.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { zone in
                        Button {
                            draft.timeZone = zone
                            pickerVisible = false
                        } label: {
                            HStack {
                                Text(zone)
                                Spacer()
                                if zone == draft.timeZone { Image(systemName: "checkmark") }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 310, height: 320)
    }

    private func useNow() {
        let timestamp = UnixMicrosecondTimestamp.now
        if draft.direction == .toDate {
            draft.unixInput = timestamp.formatted(in: draft.unit)
        } else if let shown = try? TimestampConverter.display(timestamp, in: selectedZone) {
            draft.localInput = shown.local
            draft.selectedMatch = timestamp
        }
    }
}

import SwiftUI
import UtilityCore

struct DraftRetentionPreference: View {
    @AppStorage(DraftRetention.preference) private var enabled = false
    private let retention = DraftRetention.shared

    var body: some View {
        Toggle("Keep Word Counter and Case Converter drafts for 7 days", isOn: Binding(
            get: { enabled }, set: { retention.setEnabled($0) }
        ))
        if enabled || retention.issue != nil {
            Button("Clear Retained Drafts") { try? retention.clear() }
        }
        if let issue = retention.issue { Text(issue).foregroundStyle(.secondary) }
    }
}

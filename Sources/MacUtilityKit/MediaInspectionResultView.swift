import AppKit
import SwiftUI
import UtilityCore

struct MediaInspectionResultView: View {
    let inspection: MediaInspectionResult

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inspection.report.sections.enumerated()), id: \.offset) { _, section in
                    DisclosureGroup(section.title) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                GridRow {
                                    Text(row.label).foregroundStyle(.secondary)
                                    Text(row.value).textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text(inspection.filename).lineLimit(1)
                Spacer(minLength: 8)
                Button("Copy summary", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inspection.report.summary, forType: .string)
                }
            }
        }
        .font(.callout)
    }
}

import SwiftUI

struct MacBenchmarkSummary: View {
    let values: [(label: String, value: String)]

    var body: some View {
        WorkspaceFlowLayout {
            ForEach(values, id: \.label) { metric in
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
                .padding(.trailing, 20)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

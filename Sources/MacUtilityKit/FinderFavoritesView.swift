import SwiftUI
import UtilityCore

struct FinderFavoritesView: View {
    let tools: [Tool]
    let open: (Tool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Favorite Actions")
                .font(.headline)

            if tools.isEmpty {
                Text("Star a compatible tool in Mac Utility Kit to use it here.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tools) { tool in
                            Button {
                                open(tool)
                                dismiss()
                            } label: {
                                Label(tool.title, systemImage: tool.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(height: min(CGFloat(tools.count) * 32 + 4, 240))
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}

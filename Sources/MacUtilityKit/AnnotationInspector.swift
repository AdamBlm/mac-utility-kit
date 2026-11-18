import AppKit
import SwiftUI
import UtilityCore

struct AnnotationInspector: View {
    @Binding var draft: AnnotateScreenshotDraft

    private var layer: ScreenshotAnnotation? {
        guard let id = draft.selected else { return nil }
        return draft.history.layers.first { $0.id == id }
    }

    var body: some View {
        if let tool = layer?.kind ?? draft.activeTool {
            SettingRow("Color") {
                ColorPicker("Annotation color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
            }
            if tool.isPoint {
                SettingRow("Text size") {
                    let size = styleValue(\.fontSize, fallback: $draft.fontSize)
                    Slider(value: size, in: 10...144, step: 1)
                        .accessibilityLabel("Annotation text size")
                    Text(size.wrappedValue.formatted(.number.precision(.fractionLength(0))))
                        .monospacedDigit().frame(width: 38)
                }
            } else {
                SettingRow("Stroke") {
                    let stroke = styleValue(\.stroke, fallback: $draft.stroke)
                    Slider(value: stroke, in: 1...32, step: 1)
                        .accessibilityLabel("Annotation stroke width")
                    Text(stroke.wrappedValue.formatted(.number.precision(.fractionLength(0))))
                        .monospacedDigit().frame(width: 38)
                }
            }
            if tool == .text {
                TextField("Annotation text", text: styleValue(\.text, fallback: $draft.text), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
            if tool == .number, layer != nil {
                SettingRow("Number") {
                    Stepper(value: styleValue(\.number, fallback: .constant(1)), in: 1...999) {
                        Text((layer?.number ?? 1).formatted()).monospacedDigit()
                    }
                }
            }
            if draft.activeTool != nil, !draft.history.canAdd {
                Text("This image already has 200 annotations. Remove a layer to add another.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func styleValue<T>(_ key: WritableKeyPath<ScreenshotAnnotation, T>, fallback: Binding<T>) -> Binding<T> {
        Binding {
            layer?[keyPath: key] ?? fallback.wrappedValue
        } set: { value in
            if var item = layer {
                item[keyPath: key] = value
                draft.history.replace(item)
            } else {
                fallback.wrappedValue = value
            }
        }
    }

    private var colorBinding: Binding<Color> {
        let rgb = styleValue(\.color, fallback: $draft.color)
        return Binding {
            let value = rgb.wrappedValue
            return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                         blue: Double(value & 255) / 255)
        } set: { color in
            guard let value = NSColor(color).usingColorSpace(.sRGB) else { return }
            func byte(_ component: CGFloat) -> UInt32 { UInt32((min(1, max(0, component)) * 255).rounded()) }
            rgb.wrappedValue = (byte(value.redComponent) << 16) | (byte(value.greenComponent) << 8) | byte(value.blueComponent)
        }
    }
}

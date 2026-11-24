import SwiftUI

struct AudioTrimWaveformView: View {
    let palette: WorkspacePalette
    let peaks: [Float]
    let duration: Double
    let start: Double
    let end: Double
    let playhead: Double?
    let update: (Double, Double) -> Void

    @State private var movingStart: Bool?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let left = position(start, width: width)
            let right = position(end, width: width)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(palette.canvas)
                if left < right {
                    Rectangle().fill(palette.accent.opacity(0.15))
                        .frame(width: right - left).offset(x: left)
                }
                Canvas { context, size in
                    let middle = size.height / 2
                    var waveform = Path()
                    for (index, peak) in peaks.enumerated() {
                        let x = Double(index) / Double(max(1, peaks.count - 1)) * size.width
                        let amplitude = CGFloat(min(1, peak)) * (middle - 5)
                        waveform.move(to: CGPoint(x: x, y: middle - amplitude))
                        waveform.addLine(to: CGPoint(x: x, y: middle + amplitude))
                    }
                    context.stroke(waveform, with: .color(Color.primary.opacity(0.65)), lineWidth: 1)
                }
                if let playhead {
                    Rectangle().fill(.primary).frame(width: 1)
                        .offset(x: position(playhead, width: width))
                }
                handle(at: left, width: width)
                handle(at: right, width: width)
            }
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard width > 0 else { return }
                    let movesStart = movingStart ?? (abs(value.startLocation.x - left) <= abs(value.startLocation.x - right))
                    movingStart = movesStart
                    let time = min(duration, max(0, Double(value.location.x / width) * duration))
                    if movesStart { update(time, end) }
                    else { update(start, time) }
                }
                .onEnded { _ in movingStart = nil })
        }
        .frame(height: 104)
        .accessibilityHidden(true)
    }

    private func position(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(1, max(0, seconds / duration))) * width
    }

    private func handle(at x: CGFloat, width: CGFloat) -> some View {
        Rectangle().fill(palette.accent).frame(width: 3)
            .overlay(alignment: .center) {
                Capsule().fill(palette.accent).frame(width: 7, height: 22)
            }
            .offset(x: min(max(0, x - 1.5), max(0, width - 3)))
    }
}

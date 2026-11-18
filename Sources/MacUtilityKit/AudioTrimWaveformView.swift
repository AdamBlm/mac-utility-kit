import SwiftUI

struct AudioTrimWaveformView: View {
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
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.32))
                Canvas { context, size in
                    let middle = size.height / 2
                    var waveform = Path()
                    for (index, peak) in peaks.enumerated() {
                        let x = Double(index) / Double(max(1, peaks.count - 1)) * size.width
                        let amplitude = CGFloat(min(1, peak)) * (middle - 5)
                        waveform.move(to: CGPoint(x: x, y: middle - amplitude))
                        waveform.addLine(to: CGPoint(x: x, y: middle + amplitude))
                    }
                    context.stroke(waveform, with: .color(Color.primary.opacity(0.6)), lineWidth: 1)
                }
                if left < right {
                    Rectangle().fill(Color.accentColor.opacity(0.17))
                        .frame(width: right - left).offset(x: left)
                }
                if let playhead {
                    Rectangle().fill(.primary).frame(width: 1)
                        .offset(x: position(playhead, width: width))
                }
                handle(at: left)
                handle(at: right)
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

    private func handle(at x: CGFloat) -> some View {
        Rectangle().fill(Color.accentColor).frame(width: 3)
            .offset(x: x - 1)
    }
}

import SwiftUI
import UtilityCore

struct ImageMaskCanvas: View {
    let image: CGImage
    let masks: [ImageMaskRegion]
    @Binding var selected: UUID?
    @Binding var drawing: Bool
    let onChange: ([ImageMaskRegion]) -> Void

    @State private var temporary: CGRect?
    @State private var original: CGRect?

    private let coordinate = "ImageMaskCanvas"

    private enum Corner: CaseIterable {
        case upperLeft, upperRight, lowerLeft, lowerRight
        var left: Bool { self == .upperLeft || self == .lowerLeft }
        var top: Bool { self == .upperLeft || self == .upperRight }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size.width, height: size.height)
                ForEach(masks) { mask in
                    overlay(mask, size: size)
                        .zIndex(selected == mask.id ? 1 : 0)
                }
                if drawing {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(draw(in: size))
                        .zIndex(2)
                    if let temporary {
                        let rect = frame(for: temporary, size: size)
                        Rectangle()
                            .fill(.black.opacity(0.15))
                            .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                            .zIndex(3)
                    }
                }
            }
            .coordinateSpace(name: coordinate)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func overlay(_ mask: ImageMaskRegion, size: CGSize) -> some View {
        let rect = frame(for: mask.rect, size: size)
        let focused = selected == mask.id
        Rectangle()
            .fill(.black.opacity(0.12))
            .strokeBorder(focused ? Color.white : Color.white.opacity(0.72), lineWidth: focused ? 2 : 1)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .gesture(adjust(mask, in: size, corner: nil))
        if focused && !drawing {
            ForEach(Corner.allCases, id: \.self) { corner in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .frame(width: 8, height: 8)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .position(x: corner.left ? rect.minX : rect.maxX, y: corner.top ? rect.minY : rect.maxY)
                    .gesture(adjust(mask, in: size, corner: corner))
            }
        }
    }

    private func draw(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinate))
            .onChanged { sample in
                let a = point(sample.startLocation, in: size)
                let b = point(sample.location, in: size)
                temporary = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            .onEnded { _ in
                defer { temporary = nil }
                guard let temporary, temporary.width > 0, temporary.height > 0 else { return }
                let added = ImageMaskRegion(rect: temporary)
                onChange(masks + [added])
                selected = added.id
                drawing = false
            }
    }

    private func adjust(_ mask: ImageMaskRegion, in size: CGSize, corner: Corner?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinate))
            .onChanged { sample in
                guard size.width > 0, size.height > 0 else { return }
                let start = original ?? mask.rect
                original = start
                selected = mask.id
                let dx = sample.translation.width / size.width
                let dy = sample.translation.height / size.height
                let rect: CGRect
                if let corner {
                    let minW = min(start.width, 1 / CGFloat(image.width))
                    let minH = min(start.height, 1 / CGFloat(image.height))
                    let left = corner.left ? max(0, min(start.maxX - minW, start.minX + dx)) : start.minX
                    let right = corner.left ? start.maxX : min(1, max(start.minX + minW, start.maxX + dx))
                    let top = corner.top ? max(0, min(start.maxY - minH, start.minY + dy)) : start.minY
                    let bottom = corner.top ? start.maxY : min(1, max(start.minY + minH, start.maxY + dy))
                    rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                } else {
                    rect = CGRect(x: max(0, min(1 - start.width, start.minX + dx)),
                                  y: max(0, min(1 - start.height, start.minY + dy)),
                                  width: start.width, height: start.height)
                }
                onChange(masks.map { $0.id == mask.id ? ImageMaskRegion(id: $0.id, rect: rect) : $0 })
            }
            .onEnded { _ in original = nil }
    }

    private func frame(for normalized: CGRect, size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }

    private func point(_ value: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: max(0, min(1, value.x / size.width)), y: max(0, min(1, value.y / size.height)))
    }
}

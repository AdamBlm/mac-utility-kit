import SwiftUI
import UtilityCore

struct VideoCropCanvas: View {
    let image: CGImage
    let sourceSize: CGSize
    let region: VideoCropRegion
    let aspect: VideoCropAspect
    let update: (VideoCropRegion) -> Void

    @State private var startingRegion: VideoCropRegion?
    private let coordinateSpace = "VideoCropCanvas"

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var left: Bool { self == .topLeft || self == .bottomLeft }
        var top: Bool { self == .topLeft || self == .topRight }

        func location(in rect: CGRect) -> CGPoint {
            CGPoint(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / sourceSize.width, geometry.size.height / sourceSize.height)
            if scale > 0 && scale.isFinite {
                let size = CGSize(width: scale * sourceSize.width, height: scale * sourceSize.height)
                let crop = region.rect.applying(CGAffineTransform(scaleX: scale, y: scale))
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(crop)
                    }
                    .fill(.black.opacity(0.53), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .background(.white.opacity(0.001))
                        .frame(width: crop.width, height: crop.height)
                        .position(x: crop.midX, y: crop.midY)
                        .gesture(drag(scale: scale, corner: nil))
                    ForEach(Corner.allCases, id: \.self) { corner in
                        let position = corner.location(in: crop)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.55), radius: 2)
                            .frame(width: 9, height: 9)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                            .position(position)
                            .gesture(drag(scale: scale, corner: corner))
                    }
                }
                .frame(width: size.width, height: size.height)
                .coordinateSpace(name: coordinateSpace)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func drag(scale: CGFloat, corner: Corner?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                let origin = startingRegion ?? region
                startingRegion = origin
                let maxX = Int(sourceSize.width.rounded(.down))
                let maxY = Int(sourceSize.height.rounded(.down))
                let dx = Int((value.translation.width / scale).rounded())
                let dy = Int((value.translation.height / scale).rounded())
                if let corner {
                    update(resize(origin, maxX: maxX, maxY: maxY, corner: corner, dx: dx, dy: dy))
                } else {
                    update(VideoCropRegion(x: min(max(0, origin.x + dx), maxX - origin.width),
                                           y: min(max(0, origin.y + dy), maxY - origin.height),
                                           width: origin.width, height: origin.height))
                }
            }
            .onEnded { _ in startingRegion = nil }
    }

    private func resize(_ origin: VideoCropRegion, maxX: Int, maxY: Int, corner: Corner,
                        dx: Int, dy: Int) -> VideoCropRegion {
        let anchorX = corner.left ? origin.x + origin.width : origin.x
        let anchorY = corner.top ? origin.y + origin.height : origin.y
        let widthLimit = min(VideoCropLayout.maximumDimension, corner.left ? anchorX : maxX - anchorX)
        let heightLimit = min(VideoCropLayout.maximumDimension, corner.top ? anchorY : maxY - anchorY)
        let rawWidth = origin.width + (corner.left ? -dx : dx)
        let rawHeight = origin.height + (corner.top ? -dy : dy)
        let width: Int
        let height: Int
        if let unit = aspect.unit {
            let unitWidth = Int(unit.width)
            let unitHeight = Int(unit.height)
            let projected = (Double(rawWidth) * unit.width + Double(rawHeight) * unit.height)
                / (unit.width * unit.width + unit.height * unit.height)
            let count = min(max(1, Int(projected.rounded())), min(widthLimit / unitWidth, heightLimit / unitHeight))
            width = unitWidth * count
            height = unitHeight * count
        } else {
            width = min(max(2, rawWidth - rawWidth % 2), widthLimit - widthLimit % 2)
            height = min(max(2, rawHeight - rawHeight % 2), heightLimit - heightLimit % 2)
        }
        return VideoCropRegion(x: corner.left ? anchorX - width : anchorX,
                               y: corner.top ? anchorY - height : anchorY, width: width, height: height)
    }
}

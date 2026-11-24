import AVKit
import Combine
import SwiftUI

struct VideoPreviewPlayer: View {
    let player: AVPlayer

    @State private var presentationSize = CGSize.zero

    var body: some View {
        PlayerSurface(player: player, aspectRatio: aspectRatio)
            .clipShape(.rect(cornerRadius: 8))
            .frame(maxWidth: .infinity)
            .onReceive(
                player.publisher(for: \.currentItem)
                    .map { item -> AnyPublisher<CGSize, Never> in
                        item?.publisher(for: \.presentationSize).eraseToAnyPublisher()
                            ?? Just(.zero).eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .receive(on: DispatchQueue.main)
            ) { _ in
                // Read the current item so a queued notification cannot restore a replaced item's size.
                presentationSize = player.currentItem?.presentationSize ?? .zero
            }
    }

    private var aspectRatio: CGFloat {
        let ratio = presentationSize.width / presentationSize.height
        return ratio.isFinite && ratio > 0 ? ratio : 16.0 / 9.0
    }
}

/// Hosts AVKit directly to avoid a SwiftUI VideoPlayer runtime abort on macOS 27.2.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let aspectRatio: CGFloat

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        MediaPreviewSizing.fit(aspectRatio, in: proposal, maximumHeight: 340)
    }
}

enum MediaPreviewSizing {
    static func fit(_ aspectRatio: CGFloat, in proposal: ProposedViewSize, maximumHeight: CGFloat) -> CGSize {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 480
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? maximumHeight
        let fittedHeight = max(0, min(height, maximumHeight, width / aspectRatio))
        return CGSize(width: fittedHeight * aspectRatio, height: fittedHeight)
    }
}

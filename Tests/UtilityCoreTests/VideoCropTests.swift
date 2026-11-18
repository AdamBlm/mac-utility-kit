import AVFoundation
import Testing
import UtilityCore

struct VideoCropTests {
    @Test func centersPresetAndIgnoresPreviousSourceOrientationInCropCoordinates() throws {
        var options = VideoCropOptions()
        options.aspect = .square
        let plan = try VideoCropLayout.plan(sourceSize: CGSize(width: 1920, height: 1080), options: options)
        #expect(plan.region == VideoCropRegion(x: 420, y: 0, width: 1080, height: 1080))
        #expect(CGPoint(x: 420, y: 0).applying(plan.displayedTransform) == .zero)
    }

    @Test func rejectsEmptyOddMismatchedOrOutOfFrameCrops() throws {
        let source = CGSize(width: 1920, height: 1080)
        var options = VideoCropOptions()
        for region in [VideoCropRegion(x: 0, y: 0, width: 0, height: 20),
                       VideoCropRegion(x: 0, y: 0, width: 21, height: 20),
                       VideoCropRegion(x: 1901, y: 0, width: 20, height: 20),
                       VideoCropRegion(x: Int.max, y: 0, width: 20, height: 20)] {
            options.region = region
            #expect(throws: ToolError.self) { try VideoCropLayout.plan(sourceSize: source, options: options) }
        }
        options.aspect = .landscape
        options.region = VideoCropRegion(x: 0, y: 0, width: 20, height: 20)
        #expect(throws: ToolError.self) { try VideoCropLayout.plan(sourceSize: source, options: options) }
    }

    @Test func previewAndExportAgreeOnCropRotationAndMirrorWithRotatedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoResizeTests.makePortraitVideo(in: directory)
        #expect(try await VideoCrop.sourceSize(source) == CGSize(width: 64, height: 128))
        var options = VideoCropOptions()
        options.region = VideoCropRegion(x: 8, y: 16, width: 48, height: 96)
        options.rotation = .clockwise
        options.mirrorsHorizontally = true
        let preview = try await VideoCrop.preview(source, options: options)
        try checkOutput(preview, label: "Preview")
        let output = directory.appending(path: "cropped.mp4")
        _ = try await VideoCrop.export(source, to: output, options: options) { _ in }
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (encodedSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        #expect(encodedSize == CGSize(width: 96, height: 48))
        #expect(transform.isIdentity)
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(value: 1, timescale: 4)).image
        try checkOutput(frame, label: "MP4")
    }

    private func checkOutput(_ image: CGImage, label: String) throws {
        try #require(image.width == 96 && image.height == 48)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let left = bytes.advanced(by: 24 * context.bytesPerRow + 20 * 4)
        let right = bytes.advanced(by: 24 * context.bytesPerRow + 72 * 4)
        #expect(left[0] > 140 && Int(left[0]) - Int(left[1]) > 95, "\(label): \(left[0]), \(left[1]), \(left[2])")
        #expect(right[1] > 140 && Int(right[1]) - Int(right[0]) > 95, "\(label): \(right[0]), \(right[1]), \(right[2])")
    }
}

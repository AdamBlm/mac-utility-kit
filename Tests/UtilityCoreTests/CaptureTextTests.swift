import CoreGraphics
import CoreText
import Foundation
import Testing
import UtilityCore

@Suite struct CaptureTextTests {
    @Test func convertsAppKitCoordinatesForDisplaysAboveAndLeft() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let selected = CGRect(x: -60, y: 860, width: 260, height: 130)
        let result = CaptureRegionGeometry.displayRect(appKit: selected, primaryScreen: primary)
        #expect(result == CGRect(x: -60, y: -90, width: 260, height: 130))
    }

    @Test func clipsDisplayLocalRectsAcrossDisplayBoundary() {
        let left = CGRect(x: -960, y: 80, width: 960, height: 600)
        let right = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: -20, y: 650, width: 60, height: 100)
        #expect(CaptureRegionGeometry.croppedRect(selection, on: left) == CGRect(x: 940, y: 0, width: 20, height: 30))
        #expect(CaptureRegionGeometry.croppedRect(selection, on: right) == CGRect(x: 0, y: 150, width: 40, height: 100))
        #expect(CaptureRegionGeometry.croppedRect(CGRect(x: 0, y: 0, width: 60, height: 5), on: left) == nil)
        #expect(CaptureRegionGeometry.displayRect(appKit: .null, primaryScreen: right) == nil)
    }

    @Test func usesExistingVisionPipelineForInMemoryImages() async throws {
        let width = 650
        let height = 150
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 42, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let source = NSAttributedString(string: "Screen Capture Fixture", attributes: attributes)
        context.textPosition = CGPoint(x: 30, y: 65)
        CTLineDraw(CTLineCreateWithAttributedString(source), context)
        let image = try #require(context.makeImage())
        let recognition = try await TextExtraction.recognizeImage(image, language: "en-US")
        #expect(recognition.contains("Screen Capture Fixture"))
    }
}

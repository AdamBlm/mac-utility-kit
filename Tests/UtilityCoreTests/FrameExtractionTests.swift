import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Suite struct FrameExtractionTests {
    @Test func timestampPlanSortsAndDeduplicates() throws {
        var options = FrameExtractionOptions()
        #expect(try FrameExtraction.times(duration: 3, options: options) == [0])
        options.timestamps = [2, 0.5, 0, 0.5]
        #expect(try FrameExtraction.times(duration: 3, options: options) == [0, 0.5, 2])
        options.timestamps.append(3)
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 3, options: options) }
        options.timestamps = [.nan]
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 3, options: options) }
    }

    @Test func intervalPlanBoundsCountAndExcludesDuration() throws {
        var options = FrameExtractionOptions()
        options.selection = .interval
        options.interval = 0.5
        #expect(try FrameExtraction.times(duration: 1.5, options: options) == [0, 0.5, 1])
        #expect(try FrameExtraction.times(duration: 250, options: options).count == 500)
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 250.01, options: options) }
        options.interval = 0
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 3, options: options) }
    }

    @Test(arguments: FrameImageFormat.allCases)
    func exportsDecodableFramesInOrder(_ format: FrameImageFormat) async throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(format.contentType.identifier) == true else {
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try await conversionFixture(in: folder)
        let length = try await FrameExtraction.duration(of: input)
        let preview = try await FrameExtraction.preview(input, at: length * 0.51)
        #expect(preview.width == 128)
        #expect(preview.height == 96)

        var options = FrameExtractionOptions()
        options.timestamps = [length * 0.51, 0]
        options.format = format
        options.naming = .sequence
        let result = try await FrameExtraction.export(input, into: folder, options: options) { _ in }

        #expect(result.outputs.map(\.lastPathComponent) == ["Frame-001.\(format.fileExtension)", "Frame-002.\(format.fileExtension)"])
        #expect(result.failures.isEmpty)
        for url in result.outputs {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let type = try #require(CGImageSourceGetType(source))
            #expect(type as String == format.contentType.identifier)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 128)
            #expect(image.height == 96)
        }
    }
}

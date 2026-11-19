import Foundation

/// Owns a temporary compression result for as long as its comparison is open.
package final class ImageCompressionSample: Sendable {
    package let comparison: ImageComparisonResult
    package let summary: String
    private let directory: URL

    private init(comparison: ImageComparisonResult, summary: String, directory: URL) {
        self.comparison = comparison
        self.summary = summary
        self.directory = directory
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    package static func make(_ input: URL, options: ImageCompressionOptions) async throws -> ImageCompressionSample {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacUtilityKit-ImagePreview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            var settings = ToolOptions()
            settings.imageCompression = options
            let report = try await ToolRunner.run(.compressImages, inputs: [input], destination: folder,
                                                  imageSize: 0, options: settings) { _ in }
            try Task.checkCancellation()
            guard let comparison = report.imageComparisons.first, let summary = report.summaries.first else {
                throw ToolError.invalid(report.failures.first ?? "Could not create the compression preview.")
            }
            return ImageCompressionSample(comparison: comparison, summary: summary, directory: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

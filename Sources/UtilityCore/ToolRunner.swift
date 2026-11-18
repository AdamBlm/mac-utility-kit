import Foundation

public struct JobReport: Sendable {
    public let outputs: [URL]
    public let failures: [String]
    public let summaries: [String]
}

public enum ToolError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public struct VideoSample: Sendable {
    public let url: URL
    public let estimatedBytes: Int64?
}

public enum ToolRunner {
    public static func run(
        _ tool: Tool, inputs: [URL], destination: URL, imageSize: Int, options: ToolOptions = ToolOptions(),
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> JobReport {
        guard !inputs.isEmpty else { throw ToolError.invalid("Choose at least one file.") }
        if tool == .resizeImages, options.imageSizing == .longestEdge, !(1...16_384).contains(imageSize) {
            throw ToolError.invalid("Enter an image size between 1 and 16,384 pixels.")
        }

        let manager = FileManager.default
        let id = UUID().uuidString
        let staging = destination.appendingPathComponent(".MacUtilityKit-" + id, isDirectory: true)
        let result = destination.appendingPathComponent(tool.title + " - " + id, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        var outputs: [URL] = []
        var failures: [String] = []
        var summaries: [String] = []

        if tool == .mergePDFs {
            let name = options.pdfOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
                throw ToolError.invalid("Enter a valid PDF filename.")
            }
            let output = staging.appendingPathComponent(name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf")
            try await PDFOperations.merge(inputs, ranges: options.pageRanges, passwords: options.pdfPasswords, into: output, progress: progress)
            outputs.append(output)
        } else {
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let ext = tool == .resizeImages ? options.imageFormat.rawValue : options.videoFormat.rawValue
                let output = staging.appendingPathComponent(
                    "\(index + 1) - \(input.deletingPathExtension().lastPathComponent).\(ext)"
                )
                do {
                    switch tool {
                    case .resizeImages: try await ImageResizing.resize(input, output: output, imageSize: imageSize, options: options)
                    case .compressVideo:
                        let summary = try await VideoOperations.compress(input, output: output, options: options) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .mergePDFs: break
                    }
                    outputs.append(output)
                } catch {
                    try Task.checkCancellation()
                    try? manager.removeItem(at: output)
                    failures.append("\(input.lastPathComponent) — \(error.localizedDescription)")
                }
                await progress(Double(index + 1) / Double(inputs.count))
            }
        }

        try Task.checkCancellation()
        guard !outputs.isEmpty else { return JobReport(outputs: [], failures: failures, summaries: []) }
        try manager.moveItem(at: staging, to: result)
        return JobReport(
            outputs: outputs.map { result.appendingPathComponent($0.lastPathComponent) },
            failures: failures, summaries: summaries
        )
    }

    public static func imagePreview(_ input: URL, longestEdge: Int, options: ToolOptions) throws -> String {
        try ImageResizing.preview(input, longestEdge: longestEdge, options: options)
    }

    public static func sampleVideo(_ input: URL, destination: URL, options: ToolOptions) async throws -> VideoSample {
        try await VideoOperations.sample(input, destination: destination, options: options)
    }
}

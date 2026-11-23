import ArgumentParser
import Darwin
import Foundation
import UtilityCore

protocol FileJobCatalogCommand: CatalogCommandBinding {
    var job: FileJobArguments { get }
}

struct FileJobArguments: ParsableArguments, Sendable {
    @Option(name: .shortAndLong, help: "Existing folder for the new job result.")
    var destination: String

    @Argument(help: "One or more input paths.")
    var files: [String]

    func execute(_ tool: Tool, imageSize: Int = 0, options: ToolOptions = ToolOptions()) async throws {
        let target = URL(filePath: destination, directoryHint: .isDirectory).standardizedFileURL
        guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ValidationError("Choose an existing destination folder.")
        }
        let inputs = files.map { URL(filePath: $0).standardizedFileURL }
        let worker = Task {
            try await ToolRunner.run(tool, inputs: inputs, destination: target,
                                     imageSize: imageSize, options: options) { _ in }
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { worker.cancel() }
        interrupt.resume()
        defer {
            interrupt.cancel()
            signal(SIGINT, SIG_DFL)
        }
        let report: JobReport
        do {
            report = try await worker.value
        } catch is CancellationError {
            throw ExitCode(130)
        }
        let result = FileJobOutput(
            outputs: report.outputs.map(\.path), failures: report.failures, summaries: report.summaries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(result)
        print(String(decoding: json, as: UTF8.self))
        if !report.failures.isEmpty { throw ExitCode.failure }
    }

    private struct FileJobOutput: Encodable {
        let outputs: [String]
        let failures: [String]
        let summaries: [String]
    }
}

struct ResizeImages: AsyncParsableCommand, FileJobCatalogCommand {
    static let configuration = CommandConfiguration(commandName: "resize-images", abstract: "Resize images by their longest edge.")
    static let catalogTool = Tool.resizeImages

    @OptionGroup var job: FileJobArguments
    @Option(help: "Maximum pixels on the longest edge.") var longestEdge = 1600
    @Option(help: "Output format.") var format = Format.png
    @Flag(help: "Permit enlarging smaller inputs.") var upscale = false

    enum Format: String, CaseIterable, ExpressibleByArgument {
        case png, jpg, heic, tiff
    }

    func run() async throws {
        var options = ToolOptions()
        options.imageFormat = ImageFormat(rawValue: format.rawValue) ?? .png
        options.upscale = upscale
        try await job.execute(Self.catalogTool, imageSize: longestEdge, options: options)
    }
}

struct MergePDFs: AsyncParsableCommand, FileJobCatalogCommand {
    static let configuration = CommandConfiguration(commandName: "merge-pdfs", abstract: "Merge unencrypted PDFs or images in argument order.")
    static let catalogTool = Tool.mergePDFs

    @OptionGroup var job: FileJobArguments
    @Option(help: "Output PDF filename.") var name = "Merged.pdf"
    @Option(parsing: .singleValue, help: "Page ranges in source order. Repeat once per input or leave unset for all pages.")
    var pages: [String] = []

    func run() async throws {
        guard pages.isEmpty || pages.count == job.files.count else {
            throw ValidationError("Supply one --pages value per input, or omit --pages.")
        }
        var options = ToolOptions()
        options.pdfOutputName = name
        options.pageRanges = pages
        try await job.execute(Self.catalogTool, options: options)
    }
}

struct MediaInfo: AsyncParsableCommand, FileJobCatalogCommand {
    static let configuration = CommandConfiguration(commandName: "media-info", abstract: "Write local media inspection reports.")
    static let catalogTool = Tool.mediaInfo
    @OptionGroup var job: FileJobArguments
    @Option(help: "Path to ffprobe for detailed reports and additional formats such as WebM.")
    var ffprobe: String?

    func run() async throws {
        var options = ToolOptions()
        if let ffprobe {
            let executable = URL(filePath: ffprobe).standardizedFileURL
            let resolved = executable.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isExecutableFile(atPath: resolved.path) else {
                throw ValidationError("Choose an executable ffprobe file.")
            }
            options.inspection.ffprobeExecutable = executable
        }
        try await job.execute(Self.catalogTool, options: options)
    }
}

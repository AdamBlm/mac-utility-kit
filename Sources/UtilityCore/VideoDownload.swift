import Foundation
import Synchronization

public struct VideoDownloadFormat: Decodable, Identifiable, Sendable {
    public let id: String
    public let ext: String?
    public let height: Int?
    public let language: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let videoExtension: String?
    public let audioExtension: String?
    public let note: String?

    public var hasVideo: Bool { (videoCodec ?? videoExtension).map { $0 != "none" } ?? false }
    public var hasAudio: Bool { (audioCodec ?? audioExtension).map { $0 != "none" } ?? false }

    enum CodingKeys: String, CodingKey {
        case id = "format_id"
        case ext, height, language
        case videoCodec = "vcodec"
        case audioCodec = "acodec"
        case videoExtension = "video_ext"
        case audioExtension = "audio_ext"
        case note = "format_note"
    }
}

public struct VideoDownloadInfo: Decodable, Sendable {
    public let title: String
    public let duration: Double?
    public let formats: [VideoDownloadFormat]
}

public enum VideoDownloadOutput: String, CaseIterable, Identifiable, Sendable {
    case original = "Original stream format"
    case mp4 = "MP4"
    case mkv = "MKV"
    case m4a = "M4A audio"
    case mp3 = "MP3 audio"

    public var id: Self { self }
    public var audioOnly: Bool { self == .m4a || self == .mp3 }
    fileprivate var fileExtension: String? {
        switch self {
        case .original: nil
        case .mp4: "mp4"
        case .mkv: "mkv"
        case .m4a: "m4a"
        case .mp3: "mp3"
        }
    }
}

public struct VideoDownloadSelection: Sendable {
    public var output = VideoDownloadOutput.original
    public var videoID: String?
    public var audioID: String?
    public var ffmpeg: URL?

    public init() {}
}

package enum VideoDownloadProgress: Equatable, Sendable {
    case transfer(Kind, Double?)
    case processing
    case complete

    package enum Kind: Equatable, Sendable {
        case video, audio, combined
    }
}

public enum VideoDownload {
    private static let baseline = ["--ignore-config", "--no-playlist", "--no-warnings", "--no-colors"]

    public static func sourceURL(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, url.user() == nil, url.password() == nil else {
            throw ToolError.invalid("Enter a complete HTTP or HTTPS video URL.")
        }
        return url
    }

    public static func inspect(_ source: URL, executable: URL) async throws -> VideoDownloadInfo {
        let url = try sourceURL(source.absoluteString)
        let directory = try temporaryDirectory(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("formats.json")
        try Data().write(to: report)
        let writer = try FileHandle(forWritingTo: report)
        defer { try? writer.close() }
        try await ExternalTool.run(executable, name: "yt-dlp",
                                   arguments: baseline + ["--dump-single-json", "--skip-download", "--", url.absoluteString],
                                   directory: directory, standardOutput: writer)
        guard let bytes = try report.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 24 * 1024 * 1024,
              let info = try? JSONDecoder().decode(VideoDownloadInfo.self, from: Data(contentsOf: report)),
              info.formats.contains(where: { $0.hasVideo || $0.hasAudio }) else {
            throw ToolError.invalid("This link did not provide a supported single video or audio item.")
        }
        return info
    }

    public static func download(
        _ source: URL, info: VideoDownloadInfo, executable: URL, selection: VideoDownloadSelection,
        destination: URL, progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        try await downloadWithProgress(source, info: info, executable: executable, selection: selection,
                                       destination: destination) { update in
            if case let .transfer(_, fraction?) = update { await progress(min(0.95, fraction)) }
            if update == .complete { await progress(1) }
        }
    }

    package static func downloadWithProgress(
        _ source: URL, info: VideoDownloadInfo, executable: URL, selection: VideoDownloadSelection,
        destination: URL, progress: @escaping @Sendable (VideoDownloadProgress) async -> Void
    ) async throws -> URL {
        let url = try sourceURL(source.absoluteString)
        let manager = FileManager.default
        guard destination.isFileURL else { throw ToolError.invalid("Choose a local output folder.") }
        let options = try arguments(info: info, selection: selection)
        let staging = try temporaryDirectory(in: destination)
        defer { try? manager.removeItem(at: staging) }
        let media = staging.appendingPathComponent("media", isDirectory: true)
        try manager.createDirectory(at: media, withIntermediateDirectories: false)
        let log = staging.appendingPathComponent("progress.txt")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let processExited = Mutex(false)
        let monitor = Task {
            guard let reader = try? FileHandle(forReadingFrom: log) else { return }
            defer { try? reader.close() }
            var pending = Data()
            while !Task.isCancelled {
                let finished = processExited.withLock { $0 }
                if let data = try? reader.read(upToCount: 16_384), !data.isEmpty {
                    pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        if let update = progressUpdate(String(decoding: pending[..<end], as: UTF8.self)) {
                            await progress(update)
                        }
                        pending.removeSubrange(...end)
                    }
                    if pending.count > 16_384 { pending.removeAll() }
                    continue
                }
                if finished { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        defer { monitor.cancel() }

        let template = media.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path
        try await ExternalTool.run(executable, name: "yt-dlp", arguments: baseline + options + [
            "--newline", "--progress",
            "--progress-template", "download:MUK:download\t%(info.vcodec)s\t%(info.acodec)s\t%(progress._percent_str)s",
            "--progress-template", "postprocess:MUK:processing",
            "--restrict-filenames", "--trim-filenames", "100", "--output", template, "--", url.absoluteString
        ], directory: staging, standardOutput: output)
        processExited.withLock { $0 = true }
        await monitor.value
        try Task.checkCancellation()

        let files = try manager.contentsOfDirectory(at: media, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard files.count == 1, let candidate = files.first,
              let properties = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              properties.isRegularFile == true, properties.isSymbolicLink == false, (properties.fileSize ?? 0) > 0,
              !["", "part", "ytdl"].contains(candidate.pathExtension.lowercased()),
              selection.output.fileExtension.map({ $0 == candidate.pathExtension.lowercased() }) ?? true else {
            throw ToolError.invalid("The downloader did not produce one completed file in the expected format.")
        }
        let namedOutput = destination.appendingPathComponent("Download - " + UUID().uuidString, isDirectory: true)
        try Task.checkCancellation()
        try manager.moveItem(at: media, to: namedOutput)
        await progress(.complete)
        return namedOutput.appendingPathComponent(candidate.lastPathComponent)
    }

    static func arguments(info: VideoDownloadInfo, selection: VideoDownloadSelection) throws -> [String] {
        func stream(_ id: String?, suitable: (VideoDownloadFormat) -> Bool) throws -> VideoDownloadFormat? {
            guard let id else { return nil }
            guard !id.isEmpty, id.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }), let match = info.formats.first(where: { $0.id == id && suitable($0) }) else {
                throw ToolError.invalid("Choose an available stream from the inspected source.")
            }
            return match
        }
        let audio = try stream(selection.audioID) { $0.hasAudio && !$0.hasVideo }
        let video = selection.output.audioOnly ? nil : try stream(selection.videoID) { $0.hasVideo }
        let selector: String
        let needsMerge: Bool
        if selection.output.audioOnly {
            selector = audio?.id ?? "bestaudio/best"
            needsMerge = false
        } else if let video, video.hasAudio {
            guard audio == nil else { throw ToolError.invalid("Choose a video-only stream to use a separate audio stream.") }
            selector = video.id
            needsMerge = false
        } else if let video, video.videoCodec == nil, audio == nil {
            // The generic extractor can describe a directly playable file
            // without knowing whether it contains a soundtrack.
            selector = video.id
            needsMerge = false
        } else if let video {
            selector = video.id + "+" + (audio?.id ?? "bestaudio")
            needsMerge = true
        } else if let audio {
            selector = "bestvideo+" + audio.id
            needsMerge = true
        } else {
            selector = selection.ffmpeg == nil ? "best" : "bestvideo*+bestaudio/best"
            needsMerge = false
        }
        let requiresFFmpeg = needsMerge || selection.output != .original
        if requiresFFmpeg, selection.ffmpeg == nil {
            throw ToolError.invalid("Choose FFmpeg to combine streams or change the output format.")
        }
        var arguments = ["--format", selector]
        if let ffmpeg = selection.ffmpeg {
            guard ffmpeg.isFileURL, FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
                throw ToolError.invalid("Choose a local FFmpeg executable.")
            }
            arguments += ["--ffmpeg-location", ffmpeg.path]
        }
        if let ext = selection.output.fileExtension {
            arguments += selection.output.audioOnly ? ["--extract-audio", "--audio-format", ext] : ["--remux-video", ext]
        }
        return arguments
    }

    static func progressUpdate(_ line: String) -> VideoDownloadProgress? {
        if line == "MUK:processing" { return .processing }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        if fields.count == 4, fields[0] == "MUK:download" {
            let kind: VideoDownloadProgress.Kind = if fields[1] == "none", fields[2] != "none" {
                .audio
            } else if fields[2] == "none", fields[1] != "none" {
                .video
            } else {
                .combined
            }
            return .transfer(kind, progressFraction("MUK:" + fields[3]))
        }
        return progressFraction(line).map { .transfer(.combined, $0) }
    }

    static func progressFraction(_ line: String) -> Double? {
        guard line.hasPrefix("MUK:") else { return nil }
        let number = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.hasSuffix("%"), let percent = Double(number.dropLast()),
              percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent / 100
    }

    private static func temporaryDirectory(in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(".MacUtilityKit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
}

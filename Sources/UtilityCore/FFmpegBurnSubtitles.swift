import Foundation

enum FFmpegBurnSubtitles {
    static func export(_ input: URL, cues: [SubtitleCue], to output: URL, options: BurnSubtitlesOptions) async throws {
        let filter = styleFilter(options) + ",pad=ceil(iw/2)*2:ceil(ih/2)*2"
        try await render(input, cues: cues, to: output, options: options, arguments: [
            "-vf", filter, "-map", "0:a?", "-c:v", "libx264", "-crf", "18", "-preset", "medium",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"
        ])
    }

    static func preview(
        _ input: URL, at seconds: Double, cues: [SubtitleCue], to output: URL, options: BurnSubtitlesOptions
    ) async throws {
        let time = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        let scale = "scale=w='min(720,iw)':h=-1:flags=lanczos"
        let filter = styleFilter(options) + "," + scale
        try await render(input, cues: cues, to: output, options: options, inputFlags: ["-ss", time], arguments: [
            "-vf", filter, "-frames:v", "1", "-update", "1"
        ])
    }

    private static func render(
        _ input: URL, cues: [SubtitleCue], to output: URL, options: BurnSubtitlesOptions,
        inputFlags: [String] = [], arguments: [String]
    ) async throws {
        guard let ffmpeg = options.ffmpegExecutable else {
            throw ToolError.invalid("Choose an FFmpeg build with libass to render subtitles.")
        }
        let directory = output.deletingLastPathComponent()
        if !cues.isEmpty {
            try SubRip.render(cues).write(to: directory.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
        }
        do {
            try await ExternalTool.run(ffmpeg, name: "FFmpeg", arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file",
                "-copyts", "-start_at_zero"
            ] + inputFlags + ["-i", input.path, "-map", "0:V:0"] + arguments + [output.path], directory: directory)
        } catch let error as ToolError {
            if error.localizedDescription.contains("No such filter:") && error.localizedDescription.contains("subtitles") {
                throw ToolError.invalid("This FFmpeg build does not include the libass subtitles filter.")
            }
            throw error
        }
    }

    private static func styleFilter(_ options: BurnSubtitlesOptions) -> String {
        let box = options.background != .outline
        let alpha: UInt32 = options.background == .translucent ? 80 : 0
        let styles = [
            "Fontname=Arial", "FontSize=\(options.fontSize)", "Alignment=\(options.position.alignment)",
            "PrimaryColour=\(assColor(options.textRGB))",
            "OutlineColour=\(assColor(options.backgroundRGB, alpha: alpha))",
            "BackColour=\(assColor(options.backgroundRGB, alpha: alpha))",
            "BorderStyle=\(box ? 3 : 1)", "Outline=\(box ? 3 : 2)", "Shadow=0",
            "MarginV=22", "MarginL=20", "MarginR=20"
        ]
        // Both the relative path and ASS values are built from validated numeric values or fixed strings.
        return "subtitles=filename=captions.srt:force_style='\(styles.joined(separator: ","))'"
    }

    private static func assColor(_ rgb: UInt32, alpha: UInt32 = 0) -> String {
        let bgr = ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
        return String(format: "&H%08X", (alpha << 24) | bgr)
    }
}

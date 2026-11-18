import Foundation

enum FFmpegVideoGIF {
    static func encode(
        _ input: URL, range: VideoTrimRange, to output: URL, options: VideoGIFOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        guard let ffmpeg = options.ffmpegExecutable else {
            throw ToolError.invalid("Choose an FFmpeg executable to encode a GIF.")
        }
        let directory = output.deletingLastPathComponent()
        let palette = directory.appendingPathComponent("palette.png")
        let locale = Locale(identifier: "en_US_POSIX")
        let start = String(format: "%.6f", locale: locale, range.start)
        let duration = String(format: "%.6f", locale: locale, range.duration)
        let source = ["-protocol_whitelist", "file", "-ss", start, "-t", duration, "-i", input.path]
        let global = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-filter_threads", "1", "-filter_complex_threads", "1"]
        let sampling = "fps=\(options.fps),scale=w='min(\(options.width),max(1,round(1280*dar)))':h='max(1,round(ow/dar))':flags=lanczos,setsar=1"
        let generation = "palettegen=max_colors=\(options.palette.rawValue):reserve_transparent=1:stats_mode=diff"
        try await ExternalTool.run(ffmpeg, name: "FFmpeg", arguments: global + source + [
            "-map", "0:V:0", "-vf", "\(sampling),\(generation)", "-frames:v", "1",
            "-update", "1", palette.path
        ], directory: directory)
        await progress(0.5)
        let dither = options.dithering ? "sierra2_4a" : "none"
        try await ExternalTool.run(ffmpeg, name: "FFmpeg", arguments: global + source + [
            "-protocol_whitelist", "file", "-i", palette.path,
            "-filter_complex", "[0:V:0]\(sampling)[clip];[clip][1:v]paletteuse=dither=\(dither):diff_mode=rectangle[gif]",
            "-map", "[gif]", "-an", "-loop", String(options.loopValue), "-f", "gif", output.path
        ], directory: directory)
        await progress(0.95)
    }
}

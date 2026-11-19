import Foundation

enum FFmpegChangeSpeed {
    static func export(_ input: URL, to output: URL, multiplier: Double, executable: URL,
                       start: Double, durationLimit: Double?, includeAudio: Bool) async throws {
        // Relabel PCM samples to change pitch along with tempo. Resampling back to
        // a standard rate keeps the result compatible with the MP4 audio encoder.
        let sampleRate = 48_000
        let adjustedRate = Int((Double(sampleRate) * multiplier).rounded())
        let audioSpeed = Double(adjustedRate) / Double(sampleRate)
        let adjustment = "aresample=\(sampleRate):async=1:first_pts=0,asetrate=\(adjustedRate),aresample=\(sampleRate),apad"
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n"
        ]
        if start > 0 { arguments += ["-seek_timestamp", "1", "-ss", String(start)] }
        arguments += [
            "-protocol_whitelist", "file", "-i", input.path,
            "-map", "0:V:0",
            "-vf", "setpts=PTS/\(audioSpeed),scale=ceil(iw/2)*2:ceil(ih/2)*2",
            "-fps_mode", "vfr", "-enc_time_base:v", "1/90000",
            "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart"
        ]
        if includeAudio {
            arguments += ["-map", "0:a:0", "-af", adjustment, "-c:a", "aac", "-shortest"]
        }
        if let durationLimit { arguments += ["-t", String(durationLimit)] }
        arguments += ["-f", "mp4", output.path]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments,
                                   directory: output.deletingLastPathComponent())
    }
}

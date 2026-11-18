import Foundation

enum FFmpegChangeSpeed {
    static func export(_ input: URL, to output: URL, multiplier: Double, executable: URL) async throws {
        // Relabel PCM samples to change pitch along with tempo. Resampling back to
        // a standard rate keeps the result compatible with the MP4 audio encoder.
        let sampleRate = 48_000
        let adjustedRate = Int((Double(sampleRate) * multiplier).rounded())
        let audioSpeed = Double(adjustedRate) / Double(sampleRate)
        let adjustment = "aresample=\(sampleRate):async=1:first_pts=0,asetrate=\(adjustedRate),aresample=\(sampleRate),apad"
        let arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n",
            "-protocol_whitelist", "file", "-i", input.path,
            "-map", "0:V:0", "-map", "0:a:0",
            "-vf", "setpts=PTS/\(audioSpeed),scale=ceil(iw/2)*2:ceil(ih/2)*2",
            "-af", adjustment,
            "-fps_mode", "vfr", "-enc_time_base:v", "1/90000", "-shortest",
            "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-movflags", "+faststart",
            "-f", "mp4", output.path
        ]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments,
                                   directory: output.deletingLastPathComponent())
    }
}

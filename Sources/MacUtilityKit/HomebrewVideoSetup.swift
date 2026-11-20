import AppKit
import SwiftUI

struct HomebrewVideoTools {
    var downloader: URL?
    var deno: URL?
    var ffmpeg: URL?

    private static var prefixes: [String] {
        #if arch(arm64)
        ["/opt/homebrew", "/usr/local"]
        #else
        ["/usr/local", "/opt/homebrew"]
        #endif
    }

    static func discover() -> Self {
        for prefix in prefixes {
            guard let downloader = executable(prefix + "/bin/yt-dlp") else { continue }
            return Self(downloader: downloader, deno: executable(prefix + "/bin/deno"),
                        ffmpeg: ffmpegPair(in: prefix)?.ffmpeg)
        }
        return Self()
    }

    static func ffmpegPair() -> (ffmpeg: URL, ffprobe: URL)? {
        prefixes.lazy.compactMap { ffmpegPair(in: $0) }.first
    }

    private static func ffmpegPair(in prefix: String) -> (ffmpeg: URL, ffprobe: URL)? {
        for path in ["/opt/ffmpeg-full/bin", "/bin"] {
            guard let ffmpeg = executable(prefix + path + "/ffmpeg"),
                  let ffprobe = executable(prefix + path + "/ffprobe") else { continue }
            return (ffmpeg, ffprobe)
        }
        return nil
    }

    private static func executable(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: path),
              (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return url
    }
}

struct HomebrewVideoSetup: View {
    var refresh: (() -> Void)?
    @State private var copied = false
    private let command = "brew install yt-dlp ffmpeg-full"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button(copied ? "Copied" : "Copy Setup Command", systemImage: "doc.on.doc") {
                    DeveloperToolFiles.copy(command)
                    copied = true
                }
                if let refresh { Button("Detect Installed Tools", action: refresh) }
            }
            Text("Run the command in Terminal to install the video tools.")
                .font(.callout).foregroundStyle(.secondary)
            if let guide = URL(string: "https://docs.brew.sh/Installation") {
                Link("Install Homebrew", destination: guide)
            }
        }
    }
}

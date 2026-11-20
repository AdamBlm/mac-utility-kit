import AppKit
import SwiftUI

struct HomebrewVideoTools {
    var downloader: URL?
    var deno: URL?
    var ffmpeg: URL?

    static func discover() -> Self {
        #if arch(arm64)
        let prefixes = ["/opt/homebrew", "/usr/local"]
        #else
        let prefixes = ["/usr/local", "/opt/homebrew"]
        #endif
        func executable(_ path: String) -> URL? {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: path),
                  (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
        for prefix in prefixes {
            guard let downloader = executable(prefix + "/bin/yt-dlp") else { continue }
            let ffmpeg = ["/opt/ffmpeg-full/bin", "/bin"].lazy.compactMap { path -> URL? in
                guard executable(prefix + path + "/ffprobe") != nil else { return nil }
                return executable(prefix + path + "/ffmpeg")
            }.first
            return Self(downloader: downloader, deno: executable(prefix + "/bin/deno"), ffmpeg: ffmpeg)
        }
        return Self()
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

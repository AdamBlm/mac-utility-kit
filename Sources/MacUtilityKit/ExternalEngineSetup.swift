import Foundation
import SwiftUI

enum HomebrewEngine: String, Identifiable {
    case ffmpeg = "FFmpeg"
    case ffprobe
    case whisper = "whisper-cli"
    case qpdf
    case ghostscript = "Ghostscript"
    case libreOffice = "LibreOffice"
    case forms = "Python with pypdf"
    case imagemagick = "ImageMagick"
    case exiftool = "ExifTool"
    case pandoc = "Pandoc"

    var id: Self { self }
    static let whisperModels = URL(string: "https://github.com/ggml-org/whisper.cpp/tree/master/models")

    var command: String {
        switch self {
        case .ffmpeg, .ffprobe: "brew install ffmpeg-full"
        case .whisper: "brew install whisper.cpp"
        case .qpdf: "brew install qpdf"
        case .ghostscript: "brew install ghostscript"
        case .libreOffice: "brew install --cask libreoffice"
        case .forms:
            #"brew install python && "$(brew --prefix)/bin/python3" -m venv "$HOME/.local/share/mac-utility-kit/pdf-forms" && "$HOME/.local/share/mac-utility-kit/pdf-forms/bin/python3" -m pip install 'pypdf==6.21.4'"#
        case .imagemagick: "brew install imagemagick"
        case .exiftool: "brew install exiftool"
        case .pandoc: "brew install pandoc"
        }
    }

    var installed: URL? {
        switch self {
        case .ffmpeg: return HomebrewVideoTools.ffmpegPair()?.ffmpeg
        case .ffprobe: return HomebrewVideoTools.ffmpegPair()?.ffprobe
        case .whisper: return HomebrewVideoTools.findExecutable("whisper-cli")
        case .qpdf: return HomebrewVideoTools.findExecutable("qpdf")
        case .ghostscript: return HomebrewVideoTools.findExecutable("gs")
        case .libreOffice:
            let candidates = [URL(filePath: "/Applications/LibreOffice.app"),
                              URL.homeDirectory.appending(path: "Applications/LibreOffice.app")]
            return candidates.first {
                HomebrewVideoTools.executable($0.appending(path: "Contents/MacOS/soffice").path) != nil
            } ?? HomebrewVideoTools.findExecutable("soffice")
        case .forms:
            let environment = URL.homeDirectory.appending(path: ".local/share/mac-utility-kit/pdf-forms")
            let versions = (try? FileManager.default.contentsOfDirectory(
                at: environment.appending(path: "lib"), includingPropertiesForKeys: nil
            )) ?? []
            guard versions.contains(where: {
                FileManager.default.fileExists(atPath: $0.appending(path: "site-packages/pypdf/__init__.py").path)
            }) else { return nil }
            return HomebrewVideoTools.executable(environment.appending(path: "bin/python3").path)
        case .imagemagick: return HomebrewVideoTools.findExecutable("magick")
        case .exiftool: return HomebrewVideoTools.findExecutable("exiftool")
        case .pandoc: return HomebrewVideoTools.findExecutable("pandoc")
        }
    }
}

struct ExternalEngineSetupButton: View {
    let engine: HomebrewEngine
    var onDetect: ((URL) -> Void)?
    @State private var presented = false
    @State private var missing = false

    var body: some View {
        Button("Set Up \(engine.rawValue)…", systemImage: "arrow.down.circle") {
            missing = false
            presented = true
        }
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 12) {
                HomebrewSetupCommand(command: engine.command, toolName: engine.rawValue) {
                    guard let executable = engine.installed else { missing = true; return }
                    onDetect?(executable)
                    presented = false
                }
                if engine == .whisper, let link = HomebrewEngine.whisperModels {
                    Link("Get a Whisper model", destination: link)
                }
                if missing {
                    Text("\(engine.rawValue) wasn’t found in its standard location.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(width: 400, alignment: .leading)
        }
    }
}

import AVFoundation
import Foundation
import Testing
@testable import UtilityCore

struct VideoDownloadTests {
    @Test func validatesNetworkURLAndStreamSelection() throws {
        #expect(try VideoDownload.sourceURL("https://example.test/movie").host() == "example.test")
        #expect(throws: ToolError.self) { try VideoDownload.sourceURL("file:///tmp/video.mp4") }
        #expect(throws: ToolError.self) { try VideoDownload.sourceURL("https://user:pass@example.test/movie") }
        let info = try JSONDecoder().decode(VideoDownloadInfo.self, from: Data(Self.fixture.utf8))
        var selection = VideoDownloadSelection()
        selection.videoID = "combined"
        #expect(try VideoDownload.arguments(info: info, selection: selection) == ["--format", "combined"])
        selection.audioID = "audio"
        #expect(throws: ToolError.self) { try VideoDownload.arguments(info: info, selection: selection) }
        selection.videoID = "video"
        #expect(throws: ToolError.self) { try VideoDownload.arguments(info: info, selection: selection) }
        selection.ffmpeg = URL(fileURLWithPath: "/usr/bin/true")
        #expect(try VideoDownload.arguments(info: info, selection: selection).prefix(2) == ["--format", "video+audio"])
        #expect(VideoDownload.progressFraction("MUK: 34.2%") == 0.342)
        #expect(VideoDownload.progressFraction("MUK: nan%") == nil)
    }

    @Test func inspectsAndPublishesOneFileAndCleansUpCancelledDownload() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "mock-yt-dlp")
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            --dump-single-json)
              printf '%s\\n' '\(Self.fixture)'
              exit 0
              ;;
            *cancel)
              : > media/mock.mp4.part
              exec /bin/sleep 5
              ;;
          esac
        done
        printf 'MUK: 42.0%%\\n'
        printf 'mock video' > media/mock.mp4
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let source = try VideoDownload.sourceURL("https://example.test/video")
        let info = try await VideoDownload.inspect(source, executable: executable)
        #expect(info.formats.count == 3)
        let output = try await VideoDownload.download(
            source, info: info, executable: executable, selection: .init(), destination: folder
        ) { _ in }
        #expect(try Data(contentsOf: output) == Data("mock video".utf8))
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let cancelled = Task {
            try await VideoDownload.download(
                VideoDownload.sourceURL("https://example.test/cancel"), info: info, executable: executable,
                selection: .init(), destination: folder
            ) { _ in }
        }
        try await Task.sleep(for: .milliseconds(150))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    }

    @Test func reportsVideoAudioAndPostProcessingBeforePublishing() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "mock-phases")
        let script = #"""
        #!/bin/sh
        printf 'MUK:download\tavc1\tnone\t100%%\n'
        printf 'MUK:download\tnone\taac\t0%%\n'
        printf 'MUK:download\tnone\taac\t50%%\n'
        printf 'MUK:download\tnone\taac\t100%%\n'
        printf 'MUK:processing\n'
        printf 'merged video' > media/mock.mp4
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        actor Events {
            var values: [VideoDownloadProgress] = []
            func add(_ value: VideoDownloadProgress) { values.append(value) }
        }
        let events = Events()
        let source = try VideoDownload.sourceURL("https://example.test/video")
        let info = try JSONDecoder().decode(VideoDownloadInfo.self, from: Data(Self.fixture.utf8))
        var selection = VideoDownloadSelection()
        selection.videoID = "video"
        selection.audioID = "audio"
        selection.ffmpeg = URL(fileURLWithPath: "/usr/bin/true")
        let output = try await VideoDownload.downloadWithProgress(
            source, info: info, executable: executable, selection: selection, destination: folder
        ) { await events.add($0) }
        #expect(await events.values == [
            .transfer(.video, 1), .transfer(.audio, 0), .transfer(.audio, 0.5), .transfer(.audio, 1),
            .processing, .complete
        ])
        #expect(try Data(contentsOf: output) == Data("merged video".utf8))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_YTDLP_TEST"] != nil
        && ProcessInfo.processInfo.environment["MAC_UTILITY_YTDLP_URL_TEST"] != nil))
    func realDownloaderPublishesPlayableMedia() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: try #require(environment["MAC_UTILITY_YTDLP_TEST"]))
        let source = try VideoDownload.sourceURL(#require(environment["MAC_UTILITY_YTDLP_URL_TEST"]))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deno = environment["MAC_UTILITY_YTDLP_DENO_TEST"].map { URL(fileURLWithPath: $0) }
        let ffmpeg = environment["MAC_UTILITY_YTDLP_FFMPEG_TEST"].map { URL(fileURLWithPath: $0) }
        let info = try await VideoDownload.inspect(source, executable: executable, deno: deno, ffmpeg: ffmpeg)
        var selection = VideoDownloadSelection()
        if let ffmpeg {
            selection.ffmpeg = ffmpeg
            selection.videoID = try #require(info.formats.first { $0.hasVideo && !$0.hasAudio }?.id)
            selection.audioID = try #require(info.formats.first { $0.hasAudio && !$0.hasVideo }?.id)
        }
        let output = try await VideoDownload.downloadWithProgress(
            source, info: info, executable: executable, selection: selection, destination: folder, deno: deno
        ) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        if ffmpeg != nil {
            #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
            #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        }
    }

    private static let fixture = """
    {"title":"Fixture","duration":2,"formats":[{"format_id":"combined","ext":"mp4","height":720,"vcodec":"avc1","acodec":"aac"},{"format_id":"video","vcodec":"avc1","acodec":"none"},{"format_id":"audio","language":"en","vcodec":"none","acodec":"aac"}]}
    """
}

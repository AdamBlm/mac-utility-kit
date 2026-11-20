import Foundation
import Testing
@testable import UtilityCore

struct SubtitleExtractionTests {
    @Test func showsTrackLanguageAndDisablesImageSubtitles() throws {
        let data = Data("""
        [
            {"index": 2, "codec_name": "subrip", "tags": {"language": "eng", "TITLE": "Dialogue"},
             "disposition": {"forced": 1, "hearing_impaired": 1}},
            {"index": 4, "codec_name": "hdmv_pgs_subtitle"}
        ]
        """.utf8)
        let tracks = try JSONDecoder().decode([EmbeddedSubtitleTrack].self, from: data)
        #expect(tracks[0].supportsTextExport)
        #expect(tracks[0].label == "Track 2 · eng · Dialogue · subrip · Forced · SDH")
        #expect(!tracks[1].supportsTextExport)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil
                    && ProcessInfo.processInfo.environment["MAC_UTILITY_FFPROBE_TEST"] != nil))
    func extractsSelectedTrackAsSRTAndWebVTTAndRejectsChangedSource() async throws {
        let environment = ProcessInfo.processInfo.environment
        let ffmpeg = URL(fileURLWithPath: try #require(environment["MAC_UTILITY_FFMPEG_TEST"]))
        let ffprobe = URL(fileURLWithPath: try #require(environment["MAC_UTILITY_FFPROBE_TEST"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("english.srt")
        let second = directory.appendingPathComponent("french.srt")
        try Data("1\n00:00:00,100 --> 00:00:01,800\nFirst track\n".utf8).write(to: first)
        try Data("1\n00:00:00,300 --> 00:00:01,200\nDeuxième piste\n".utf8).write(to: second)
        let source = directory.appendingPathComponent("sample.mkv")
        try await ExternalTool.run(ffmpeg, name: "FFmpeg", arguments: [
            "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=black:size=64x48:duration=2",
            "-i", first.path, "-i", second.path, "-map", "0:v", "-map", "1:s", "-map", "2:s",
            "-c:v", "mpeg4", "-c:s", "srt", "-metadata:s:s:0", "language=eng",
            "-metadata:s:s:1", "language=fra", "-metadata:s:s:1", "title=French", source.path
        ], directory: directory)
        let inventory = try await SubtitleExtraction.inspect(source, executable: ffprobe)
        #expect(inventory.tracks.map(\.id) == [1, 2])
        let track = try #require(inventory.tracks.last)
        #expect(track.label.contains("fra"))
        #expect(track.label.contains("French"))

        let data = try await SubtitleExtraction.extract(track, from: inventory, as: .srt, executable: ffmpeg)
        let srt = String(decoding: data, as: UTF8.self)
        #expect(srt.contains("00:00:00,300 --> 00:00:01,200"))
        #expect(srt.contains("Deuxième piste"))
        #expect(!srt.contains("First track"))

        let vtt = try await SubtitleExtraction.extract(track, from: inventory, as: .vtt, executable: ffmpeg)
        let text = String(decoding: vtt, as: UTF8.self)
        #expect(text.hasPrefix("WEBVTT"))
        #expect(text.contains("00:00.300 --> 00:01.200"))
        #expect(text.contains("Deuxième piste"))

        let selection = directory.appendingPathComponent("picked-video.mkv")
        let manager = FileManager.default
        try manager.createSymbolicLink(at: selection, withDestinationURL: source)
        let linkedInventory = try await SubtitleExtraction.inspect(selection, executable: ffprobe)
        try manager.removeItem(at: selection)
        try manager.createSymbolicLink(at: selection, withDestinationURL: first)
        await #expect(throws: ToolError.self) {
            try await SubtitleExtraction.extract(track, from: linkedInventory, as: .vtt, executable: ffmpeg)
        }

        let playlist = directory.appendingPathComponent("playlist.ffconcat")
        try Data("ffconcat version 1.0\nfile sample.mkv\n".utf8).write(to: playlist)
        await #expect(throws: ToolError.self) {
            try await SubtitleExtraction.inspect(playlist, executable: ffprobe)
        }

        try Data().write(to: source, options: .atomic)
        await #expect(throws: ToolError.self) {
            try await SubtitleExtraction.extract(track, from: inventory, as: .srt, executable: ffmpeg)
        }
    }
}

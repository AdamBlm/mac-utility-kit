import AVFoundation
import Testing
import UtilityCore

@Suite(.serialized)
struct ScreenRecordingTests {
    @Test
    func scalesRetinaAndPortraitSourcesWithoutStretchingOrUpscaling() throws {
        let retina = try ScreenRecordingGeometry(points: CGSize(width: 1512, height: 982), scale: 2, resolution: .p1080)
        #expect(retina.height == 1080)
        #expect(retina.width == 1662)
        let portrait = try ScreenRecordingGeometry(points: CGSize(width: 480, height: 960), scale: 2, resolution: .p720)
        #expect(portrait.width == 640)
        #expect(portrait.height == 1280)
        let smaller = try ScreenRecordingGeometry(points: CGSize(width: 301, height: 199), scale: 1, resolution: .p2160)
        #expect(smaller.width == 300)
        #expect(smaller.height == 198)
        #expect(throws: ToolError.self) {
            try ScreenRecordingGeometry(points: CGSize(width: CGFloat.infinity, height: 600), scale: 2, resolution: .source)
        }
    }

    @Test
    func joinsSyntheticSegmentsAndKeepsBothAudioTracks() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = try await VideoResizeTests.makePortraitVideo(in: folder)
        let source = try await audioAndPicture(in: folder, picture: picture)
        let segment = try await ScreenRecordingFile.inspect(source)
        #expect(segment.audioTrackCount == 2)
        let output = folder.appending(path: "joined.mp4")
        let joined = try await ScreenRecordingFile.join([segment, segment], to: output)
        #expect(joined.audioTrackCount == 2)
        #expect(abs(joined.duration - 2 * segment.duration) < 0.1)
        #expect(joined.dimensions == segment.dimensions)
        let saved = folder.appending(path: "saved.mp4")
        try await joined.save(to: saved)
        #expect(try Data(contentsOf: saved) == Data(contentsOf: output))
    }

    private func audioAndPicture(in folder: URL, picture: URL) async throws -> URL {
        let audio = folder.appending(path: "track.m4a")
        do {
            let file = try AVAudioFile(forWriting: audio, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
            buffer.frameLength = buffer.frameCapacity
            let channel = try #require(buffer.floatChannelData?.pointee)
            for index in 0..<48_000 { channel[index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000) * 0.25) }
            try file.write(from: buffer)
        }
        let videoAsset = AVURLAsset(url: picture)
        let audioAsset = AVURLAsset(url: audio)
        let video = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let videoRange = try await video.load(.timeRange)
        try videoTrack.insertTimeRange(videoRange, of: video, at: .zero)
        videoTrack.preferredTransform = try await video.load(.preferredTransform)
        let audioRange = try await sound.load(.timeRange).intersection(videoRange)
        for _ in 0..<2 {
            let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try audioTrack.insertTimeRange(audioRange, of: sound, at: .zero)
        }
        let file = folder.appending(path: "segment.mp4")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.exportMedia(to: file, as: .mp4)
        return file
    }
}

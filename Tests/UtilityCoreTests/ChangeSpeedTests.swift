import AVFoundation
import Testing
import UtilityCore

@Suite(.serialized)
struct ChangeSpeedTests {
    @Test(arguments: [0.5, 2.0], [false, true])
    func adjustsVideoAndAudioDurations(multiplier: Double, withAudio: Bool) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.makeVideo(in: directory, audio: withAudio)
        let output = directory.appending(path: "speed.mp4")
        let originalDuration = try await ChangeSpeed.sourceDuration(source)
        var options = ChangeSpeedOptions()
        options.multiplier = multiplier
        _ = try await ChangeSpeed.export(source, to: output, options: options) { _ in }
        let result = AVURLAsset(url: output)
        let track = try #require(try await result.loadTracks(withMediaType: .video).first)
        let expected = originalDuration / multiplier
        let videoEnd = try await track.load(.timeRange).end.seconds
        #expect(abs(videoEnd - expected) < 0.1)
        let audio = try await result.loadTracks(withMediaType: .audio)
        if withAudio {
            let track = try #require(audio.first)
            let range = try await track.load(.timeRange)
            #expect(abs(range.end.seconds - videoEnd) < 0.1)
        } else {
            #expect(audio.isEmpty)
        }
    }

    @Test
    func scalesAudioStartOffsetAlongWithVideo() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.makeVideo(in: directory, audio: true, audioOffset: 0.5)
        let output = directory.appending(path: "offset.mp4")
        var options = ChangeSpeedOptions()
        options.multiplier = 2
        _ = try await ChangeSpeed.export(source, to: output, options: options) { _ in }
        let samples = try await Self.audioSamples(output)
        let leadingSilence = try #require(samples.firstIndex { abs(Int($0)) > 2_000 })
        #expect(abs(Double(leadingSilence) / 48_000 - 0.25) < 0.06)
    }

    @Test
    func preservesPitch() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.makeVideo(in: directory, audio: true)
        let output = directory.appending(path: "pitch.mp4")
        var options = ChangeSpeedOptions()
        options.multiplier = 2
        _ = try await ChangeSpeed.export(source, to: output, options: options) { _ in }
        let pitch = try await Self.audioFrequency(output)
        #expect(abs(pitch - 440) < 35)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func speedsUpPitchUsingFFmpeg() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.makeVideo(in: directory, audio: true)
        let output = directory.appending(path: "pitch.mp4")
        var options = ChangeSpeedOptions()
        options.multiplier = 2
        options.preservesPitch = false
        await #expect(throws: ToolError.self) {
            try await ChangeSpeed.export(source, to: output, options: options) { _ in }
        }
        options.ffmpegExecutable = URL(fileURLWithPath: executable)
        _ = try await ChangeSpeed.export(source, to: output, options: options) { _ in }
        let pitch = try await Self.audioFrequency(output)
        #expect(abs(pitch - 880) < 35)
    }

    @Test(arguments: [0, 0.1, 5, -1, Double.infinity, Double.nan])
    func rejectsUnsupportedMultipliers(multiplier: Double) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "speed.mp4")
        var options = ChangeSpeedOptions()
        options.multiplier = multiplier
        await #expect(throws: ToolError.self) {
            try await ChangeSpeed.export(directory.appending(path: "source.mov"), to: output, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func makeVideo(in directory: URL, audio: Bool, audioOffset: Double = 0) async throws -> URL {
        let url = directory.appending(path: "fixture.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
        let frame = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(frame, [])
        if let bytes = CVPixelBufferGetBaseAddress(frame) {
            memset(bytes, 120, CVPixelBufferGetBytesPerRow(frame) * 96)
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<48 {
            for _ in 0..<500 where !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require(input.isReadyForMoreMediaData)
            try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        if !audio { return url }

        let wave = directory.appending(path: "tone.wav")
        try writeTone(to: wave)
        let composition = AVMutableComposition()
        for (file, type) in [(url, AVMediaType.video), (wave, .audio)] {
            let asset = AVURLAsset(url: file)
            let source = try #require(try await asset.loadTracks(withMediaType: type).first)
            let track = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            let offset = type == .audio ? CMTime(seconds: audioOffset, preferredTimescale: 48_000) : .zero
            try await track.insertTimeRange(source.load(.timeRange), of: source, at: offset)
        }
        let combined = directory.appending(path: "combined.mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: combined, as: .mov)
        return combined
    }

    private static func writeTone(to url: URL) throws {
        let sampleRate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<Int(buffer.frameLength) {
            channel[index] = Float(0.6 * sin(2 * .pi * 440 * Double(index) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func audioFrequency(_ url: URL) async throws -> Double {
        let samples = try await audioSamples(url)
        try #require(samples.count > 28_800)
        let middle = samples[9600..<28800]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) * 48_000 / Double(middle.count)
    }

    private static func audioSamples(_ url: URL) async throws -> [Int16] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
        ])
        reader.add(output)
        try #require(reader.startReading())
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples += repeatElement(0, count: length / MemoryLayout<Int16>.size)
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: bytes.baseAddress!.advanced(by: start * MemoryLayout<Int16>.size))
            }
            try #require(status == kCMBlockBufferNoErr)
        }
        return samples
    }
}

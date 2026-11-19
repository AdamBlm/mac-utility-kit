import AVFoundation
import Testing
import UtilityCore

struct ReplaceAudioTests {
    @Test func mixExportsAudibleClipAndSkipsSilentClipInSharedRunner() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = try await VideoResizeTests.makePortraitVideo(in: directory)
        let originals = try [440.0, 550].enumerated().map { index, frequency in
            try Self.writeTone("original-\(index).wav", in: directory, length: 1, frequency: frequency)
        }
        let replacements = try [660.0, 770].enumerated().map { index, frequency in
            try Self.writeTone("replacement-\(index).wav", in: directory, length: 1, frequency: frequency)
        }
        let replacementFolder = directory.appending(path: "replacement", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: replacementFolder, withIntermediateDirectories: false)
        let audible = try await Self.attachAudio(originals, to: silent, in: directory)
        let replacement = try await Self.attachAudio(replacements, to: silent, in: replacementFolder)
        var options = ToolOptions()
        options.replaceAudio.mode = .mix
        options.replaceAudio.source = replacement
        options.replaceAudio.sourceTrackIndex = 1
        options.replaceAudio.originalTracks[audible] = 1
        options.replaceAudio.newVolume = 0.5
        let report = try await ToolRunner.run(.replaceAudio, inputs: [silent, audible], destination: directory,
                                              imageSize: 0, options: options) { _ in }
        #expect(report.outputs.count == 1)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("no original audio track") == true)
        let output = try #require(report.outputs.first)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let audioOutput = directory.appending(path: "verification.m4a")
        _ = try await AudioExtraction.extract(output, to: audioOutput, options: .init()) { _ in }
        let mix = try Self.readSamples(audioOutput)
        #expect(mix.magnitude(at: 550) > 0.2 && mix.magnitude(at: 770) > 0.2)
        #expect(mix.magnitude(at: 440) < 0.05 && mix.magnitude(at: 660) < 0.05)
    }

    @Test func preservesVideoDurationAndPlacesReplacementAtOffset() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoResizeTests.makePortraitVideo(in: directory)
        var options = ReplaceAudioOptions()
        options.source = try Self.writeTone("short.wav", in: directory, length: 0.3, frequency: 770)
        options.offsetSeconds = 0.25
        let output = directory.appending(path: "replaced.mp4")
        _ = try await ReplaceAudio.export(source, to: output, options: options) { _ in }
        let result = AVURLAsset(url: output)
        #expect(abs(try await result.load(.duration).seconds - 1) < 0.06)
        let sourcePicture = try await Self.orientedFrame(AVURLAsset(url: source))
        let outputPicture = try await Self.orientedFrame(result)
        #expect(sourcePicture.width == outputPicture.width && sourcePicture.height == outputPicture.height)
        #expect(try Self.upperQuarterIsRed(sourcePicture) == Self.upperQuarterIsRed(outputPicture))
        let preview = try await ReplaceAudio.sample(source, options: options, preview: .result)
        let samples = try Self.readSample(preview, in: directory)
        #expect(samples.rms(in: 0.01..<0.15) < 0.025)
        #expect(samples.rms(in: 0.30..<0.46) > 0.35)
    }

    @Test func loopsShortAudioAndTrimsVideoWhenRequested() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoResizeTests.makePortraitVideo(in: directory)
        var options = ReplaceAudioOptions()
        options.source = try Self.writeTone("short.wav", in: directory, length: 0.3, frequency: 770)
        options.offsetSeconds = -0.1
        options.durationPolicy = .loop
        let sample = try await ReplaceAudio.sample(source, options: options, preview: .result)
        let mixed = try Self.readSample(sample, in: directory)
        #expect(mixed.rms(in: 0.02..<0.10) > 0.35)
        #expect(mixed.rms(in: 0.82..<0.91) > 0.35)
        options.offsetSeconds = 0.2
        options.durationPolicy = .shortest
        let output = directory.appending(path: "trimmed.mp4")
        _ = try await ReplaceAudio.export(source, to: output, options: options) { _ in }
        #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - 0.5) < 0.07)
    }

    @Test func mixesChosenOriginalTrackAtItsGainAndRejectsMissingOriginal() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = try await VideoResizeTests.makePortraitVideo(in: directory)
        let first = try Self.writeTone("first.wav", in: directory, length: 1, frequency: 440)
        let second = try Self.writeTone("second.wav", in: directory, length: 1, frequency: 550)
        let replacement = try Self.writeTone("new.wav", in: directory, length: 1, frequency: 770)
        let source = try await Self.attachAudio([first, second], to: silent, in: directory)
        var options = ReplaceAudioOptions()
        options.source = replacement
        options.mode = .mix
        options.originalTracks[source] = 1
        options.originalVolume = 0.5
        options.newVolume = 0.25
        let original = try Self.readSample(await ReplaceAudio.sample(source, options: options, preview: .original), in: directory)
        let result = try Self.readSample(await ReplaceAudio.sample(source, options: options, preview: .result), in: directory)
        #expect(original.magnitude(at: 550) > 0.7)
        #expect(result.magnitude(at: 550) > 0.3)
        #expect(result.magnitude(at: 770) > 0.14)
        #expect(result.magnitude(at: 440) < 0.025)
        #expect(abs(original.magnitude(at: 550) * 0.5 - result.magnitude(at: 550)) < 0.08)
        let absent = directory.appending(path: "missing-mix.mp4")
        await #expect(throws: ToolError.self) {
            try await ReplaceAudio.export(silent, to: absent, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    @Test func previewsOriginalWithoutReplacementAndIgnoresReplacementTiming() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = try await VideoResizeTests.makePortraitVideo(in: directory)
        let tone = try Self.writeTone("tone.wav", in: directory, length: 1, frequency: 550)
        let source = try await Self.attachAudio([tone], to: silent, in: directory)
        var options = ReplaceAudioOptions()
        options.durationPolicy = .shortest
        options.offsetSeconds = 10

        let original = try await ReplaceAudio.sample(source, options: options, preview: .original)
        #expect(original.startSeconds == 0)
        #expect(try Self.readSample(original, in: directory).magnitude(at: 550) > 0.7)
        await #expect(throws: ToolError.self) {
            try await ReplaceAudio.sample(source, options: options, preview: .result)
        }
    }

    @Test func originalAuditionFindsAudioThatStartsLate() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = try await VideoResizeTests.makePortraitVideo(in: directory)
        let tone = try Self.writeTone("tone.wav", in: directory, length: 1, frequency: 550)
        let source = try await Self.attachAudio([tone], to: silent, in: directory, delay: CMTime(value: 6, timescale: 1))

        let original = try await ReplaceAudio.sample(source, options: .init(), preview: .original)
        #expect(abs(original.startSeconds - 5.5) < 0.1)
        #expect(original.peak > 0.7)
    }

    private static func orientedFrame(_ asset: AVURLAsset) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(value: 1, timescale: 4)).image
    }

    private static func upperQuarterIsRed(_ image: CGImage) throws -> Bool {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let sample = buffer.advanced(by: image.height / 4 * context.bytesPerRow + image.width / 2 * 4)
        #expect(abs(Int(sample[0]) - Int(sample[1])) > 95)
        return sample[0] > sample[1]
    }

    private struct Samples {
        let values: [Float]
        let rate: Double

        func rms(in seconds: Range<Double>) -> Double {
            let a = min(values.count, Int(seconds.lowerBound * rate))
            let b = min(values.count, Int(seconds.upperBound * rate))
            guard a < b else { return 0 }
            return sqrt(values[a..<b].reduce(0) { $0 + Double($1 * $1) } / Double(b - a))
        }

        func magnitude(at frequency: Double) -> Double {
            let a = Int(rate * 0.20)
            let b = min(values.count, Int(rate * 0.60))
            guard a < b else { return 0 }
            var inPhase = 0.0
            var quadrature = 0.0
            for index in a..<b {
                let phase = 2 * .pi * frequency * Double(index) / rate
                inPhase += Double(values[index]) * cos(phase)
                quadrature += Double(values[index]) * sin(phase)
            }
            return hypot(inPhase, quadrature) * 2 / Double(b - a)
        }
    }

    private static func readSample(_ sample: ReplaceAudio.Sample, in directory: URL) throws -> Samples {
        let url = directory.appending(path: UUID().uuidString + ".m4a")
        try sample.data.write(to: url)
        return try readSamples(url)
    }

    private static func readSamples(_ url: URL) throws -> Samples {
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let channel = try #require(pcm.floatChannelData?.pointee)
        return Samples(values: Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength))), rate: pcm.format.sampleRate)
    }

    private static func attachAudio(
        _ tracks: [URL], to picture: URL, in directory: URL, delay: CMTime = .zero
    ) async throws -> URL {
        let composition = AVMutableComposition()
        for (file, type) in [(picture, AVMediaType.video)] + tracks.map({ ($0, .audio) }) {
            let asset = AVURLAsset(url: file)
            let source = try #require(try await asset.loadTracks(withMediaType: type).first)
            let track = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: type == .video ? .zero : delay)
            if type == .video {
                track.preferredTransform = try await source.load(.preferredTransform)
                if delay > .zero {
                    track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: range.duration + delay)
                }
            }
        }
        let output = directory.appending(path: "original.mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.exportMedia(to: output, as: .mov)
        return output
    }

    private static func writeTone(_ name: String, in directory: URL, length: Double, frequency: Double) throws -> URL {
        let url = directory.appending(path: name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frameCount = AVAudioFrameCount(length * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let values = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<Int(frameCount) { values[index] = Float(0.8 * sin(2 * .pi * frequency * Double(index) / format.sampleRate)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

import AVFoundation
import Testing
import UtilityCore

struct MuteVideoTests {
    @Test func removesSelectedAudioAndKeepsLanguageMetadataOrientationAndEncodedVideo() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try await Self.fixture(in: directory)
        let source = try await MuteVideo.inspect(input)
        let audio = source.filter(\.isAudio)
        #expect(audio.count == 2)
        let removed = try #require(audio.first { $0.language == "en" || $0.language == "eng" })
        let remaining = try #require(audio.first { $0.id != removed.id })
        var options = MuteVideoOptions()
        options.removal = .selected
        options.removedTrackIDs[input] = [removed.id]
        let output = directory.appending(path: "selected.mov")
        _ = try await MuteVideo.export(input, to: output, options: options) { _ in }
        let result = try await MuteVideo.inspect(output)
        #expect(result.filter(\.isAudio).map(\.language) == [remaining.language])
        #expect(try await Self.compressedVideo(input) == Self.compressedVideo(output))
        let original = AVURLAsset(url: input)
        let exported = AVURLAsset(url: output)
        let inputTrack = try #require(try await original.loadTracks(withMediaType: .video).first)
        let outputTrack = try #require(try await exported.loadTracks(withMediaType: .video).first)
        #expect(try await inputTrack.load(.preferredTransform) == outputTrack.load(.preferredTransform))
        let title = try #require(try await exported.load(.commonMetadata).first { $0.commonKey == .commonKeyTitle })
        #expect(try await title.load(.stringValue) == "Mute Video fixture")
    }

    @Test func removesAllAudioToMP4AndFlagsAlreadySilentInput() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try await Self.fixture(in: directory)
        var options = MuteVideoOptions()
        options.container = .mp4
        let output = directory.appending(path: "silent.mp4")
        #expect(try MuteVideo.outputExtension(input, options: options) == "mp4")
        _ = try await MuteVideo.export(input, to: output, options: options) { _ in }
        #expect(try await MuteVideo.inspect(output).allSatisfy { !$0.isAudio })
        #expect(try await Self.compressedVideo(input) == Self.compressedVideo(output))
        let absent = directory.appending(path: "unexpected.mp4")
        await #expect(throws: ToolError.self) {
            try await MuteVideo.export(output, to: absent, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    @Test func rejectsStaleTrackSelectionAndUnsupportedOriginalContainer() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.fixture(in: directory)
        let output = directory.appending(path: "unexpected.mov")
        var options = MuteVideoOptions()
        options.removal = .selected
        options.removedTrackIDs[source] = [Int32.max]
        await #expect(throws: ToolError.self) {
            try await MuteVideo.export(source, to: output, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: ToolError.self) {
            try MuteVideo.outputExtension(directory.appending(path: "movie.mkv"), options: options)
        }
    }

    @Test func checksRetainedTracksAndExportsOnlyCompatibleFilesInAMixedBatch() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compatibleFolder = directory.appending(path: "compatible", directoryHint: .isDirectory)
        let incompatibleFolder = directory.appending(path: "incompatible", directoryHint: .isDirectory)
        for folder in [compatibleFolder, incompatibleFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let compatible = try await Self.fixture(in: compatibleFolder)
        let proRes = try await Self.fixture(in: incompatibleFolder, videoCodec: .proRes422)
        var options = ToolOptions()
        options.mute.container = .mp4
        let report = try await ToolRunner.run(.muteVideo, inputs: [proRes, compatible], destination: directory,
                                              imageSize: 0, options: options) { _ in }
        #expect(report.outputs.count == 1)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("cannot be copied into MP4") == true)
        let output = try #require(report.outputs.first)
        #expect(try await MuteVideo.inspect(output).allSatisfy { !$0.isAudio })
        #expect(try await Self.compressedVideo(output) == Self.compressedVideo(compatible))
    }

    @Test func checksContainerCompatibilityBeforeCreatingAnOutput() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.fixture(in: directory, videoCodec: .proRes422)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var options = MuteVideoOptions()
        try await MuteVideo.checkCompatibility(source, options: options)
        options.container = .mp4
        do {
            try await MuteVideo.checkCompatibility(source, options: options)
            Issue.record("Expected the ProRes stream to be incompatible with MP4 passthrough.")
        } catch {
            #expect(error.localizedDescription.contains("cannot be copied into MP4"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func fixture(in directory: URL, videoCodec: AVVideoCodecType = .h264) async throws -> URL {
        let picture = directory.appending(path: "picture.mov")
        let writer = try AVAssetWriter(outputURL: picture, fileType: .mov)
        let sink = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: videoCodec, AVVideoWidthKey: 64, AVVideoHeightKey: 48
        ])
        sink.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: sink, sourcePixelBufferAttributes: nil)
        writer.add(sink)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let frame = try #require(pixel)
        CVPixelBufferLockBaseAddress(frame, [])
        if let bytes = CVPixelBufferGetBaseAddress(frame) {
            memset(bytes, 180, CVPixelBufferGetBytesPerRow(frame) * 48)
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<12 {
            for _ in 0..<200 where !sink.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require(sink.isReadyForMoreMediaData)
            try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        sink.markAsFinished()
        await writer.finishMediaWriting()
        try #require(writer.status == .completed)

        let wav = directory.appending(path: "tone.wav")
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let samples = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 24_000))
        samples.frameLength = 24_000
        let channel = try #require(samples.floatChannelData?.pointee)
        for index in 0..<Int(samples.frameLength) { channel[index] = Float(sin(Double(index) * .pi / 54)) }
        do {
            let sound = try AVAudioFile(forWriting: wav, settings: mono.settings)
            try sound.write(from: samples)
        }

        let composition = AVMutableComposition()
        let visual = AVURLAsset(url: picture)
        let sound = AVURLAsset(url: wav)
        let video = try #require(try await visual.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await sound.loadTracks(withMediaType: .audio).first)
        let screen = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1))
        try await screen.insertTimeRange(video.load(.timeRange), of: video, at: .zero)
        screen.preferredTransform = try await video.load(.preferredTransform)
        for (id, language) in [(Int32(2), "en"), (Int32(3), "fr")] {
            let copy = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: id))
            copy.extendedLanguageTag = language
            try await copy.insertTimeRange(audio.load(.timeRange), of: audio, at: .zero)
        }
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Mute Video fixture" as NSString
        export.metadata = [title]
        let output = directory.appending(path: "two-languages.mov")
        try await export.exportMedia(to: output, as: .mov)
        return output
    }

    private static func compressedVideo(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let packets = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(packets)
        try #require(reader.startReading())
        var results: [Data] = []
        while let packet = packets.copyNextSampleBuffer() {
            guard let block = packet.dataBuffer else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let length = bytes.count
            let status = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination.baseAddress!)
            }
            try #require(status == kCMBlockBufferNoErr)
            results.append(bytes)
        }
        try #require(!results.isEmpty && reader.status == .completed)
        return results
    }
}

import AVFoundation
import VideoToolbox

enum AVFoundationEncoding {
    private struct Stream {
        let reader: AVAssetReaderTrackOutput
        let writer: AVAssetWriterInput
    }

    static func export(
        _ asset: AVURLAsset, to output: URL, options: ToolOptions, sample: Bool,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError.invalid("The file has no video track.")
        }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        guard size.width > 0, size.height > 0, duration.seconds.isFinite, duration.seconds > 0 else {
            throw ToolError.invalid("Could not read the video dimensions or duration.")
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: options.videoFormat.fileType)
        let frameRate = Double(try await video.load(.nominalFrameRate))
        let sourceRate = Double(try await video.load(.estimatedDataRate))
        let quality = options.videoQuality
        let ratio: Double = quality == .smaller ? 0.45 : quality == .balanced ? 0.75 : 0.92
        let bitsPerPixel: Double = quality == .smaller ? 0.065 : quality == .balanced ? 0.13 : 0.22
        let qualityRate = size.width * size.height * max(24, frameRate) * bitsPerPixel
        let target = sourceRate > 0 ? min(qualityRate, sourceRate * ratio) : qualityRate
        let formats = try await video.load(.formatDescriptions)
        let format = formats.first
        let transfer = format.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let hdr = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let hevc = options.videoCodec == .hevc || hdr
        var compression: [String: Any] = [AVVideoAverageBitRateKey: Int(max(64_000, target))]
        if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
        var settings: [String: Any] = [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width.rounded()),
            AVVideoHeightKey: Int(size.height.rounded()),
            AVVideoCompressionPropertiesKey: compression
        ]
        if let format,
           let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries),
           let transfer,
           let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix
            ]
        }
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoStream = try add(
            video, read: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat], write: settings,
            to: reader, writer: writer
        )
        videoStream.writer.transform = transform
        var streams = [videoStream]
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            let format = try await audio.load(.formatDescriptions).first
            let layout = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let channels = Int(layout?.mChannelsPerFrame ?? 2)
            let sampleRate = layout?.mSampleRate ?? 48_000
            streams.append(try add(
                audio, read: [AVFormatIDKey: kAudioFormatLinearPCM],
                write: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: min(320_000, 96_000 * channels)],
                to: reader, writer: writer
            ))
        }
        let exportDuration = sample ? min(duration, CMTime(seconds: 5, preferredTimescale: 600)) : duration
        if sample { reader.timeRange = CMTimeRange(start: .zero, duration: exportDuration) }
        guard writer.startWriting() else {
            throw writer.error ?? ToolError.invalid("Could not start the encoder.")
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard reader.startReading() else {
            throw reader.error ?? ToolError.invalid("Could not read video samples.")
        }
        writer.startSession(atSourceTime: .zero)
        let readers = streams.map { AsyncAssetReaderSamples(reader: reader, output: $0.reader) }
        var active = Array(streams.indices)
        var lastProgress = 0.0
        while !active.isEmpty {
            try Task.checkCancellation()
            if let error = writer.error ?? reader.error { throw error }
            var madeProgress = false
            for index in active.reversed() where streams[index].writer.isReadyForMoreMediaData {
                madeProgress = true
                let stream = streams[index]
                if let buffer = try await readers[index].next() {
                    guard stream.writer.append(buffer) else {
                        throw writer.error ?? ToolError.invalid("Could not encode a media sample.")
                    }
                    if index == 0 {
                        let fraction = min(1, buffer.presentationTimeStamp.seconds / exportDuration.seconds)
                        if fraction >= lastProgress + 0.01 {
                            lastProgress = fraction
                            await progress(fraction)
                        }
                    }
                } else {
                    stream.writer.markAsFinished()
                    active.removeAll { $0 == index }
                }
            }
            if !madeProgress { try await Task.sleep(for: .milliseconds(4)) }
        }
        if let error = reader.error { throw error }
        if sample { writer.endSession(atSourceTime: exportDuration) }
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? ToolError.invalid("Could not finish encoding the video.")
        }
        let result = AVURLAsset(url: output)
        guard let resultTrack = try await result.loadTracks(withMediaType: .video).first,
              try await resultTrack.load(.naturalSize) == size else {
            throw ToolError.invalid("The encoder could not preserve the source resolution.")
        }
        await progress(1)
    }

    private static func add(
        _ track: AVAssetTrack, read: [String: Any], write: [String: Any],
        to reader: AVAssetReader, writer: AVAssetWriter
    ) throws -> Stream {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: read)
        output.alwaysCopiesSampleData = false
        guard writer.canApply(outputSettings: write, forMediaType: track.mediaType) else {
            throw ToolError.invalid("The selected format does not support these media settings.")
        }
        let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: write)
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw ToolError.invalid("The selected format could not handle one of the media tracks.")
        }
        reader.add(output)
        writer.add(input)
        return Stream(reader: output, writer: input)
    }
}

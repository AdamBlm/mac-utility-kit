import CoreMedia
import VideoToolbox

final class NativeVideoScaler {
    private let transfer: VTPixelTransferSession
    private let pool: CVPixelBufferPool

    init(size: CGSize, pixelFormat: OSType) throws {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr,
              let session else { throw ToolError.invalid("Could not initialize native video scaling.") }
        self.transfer = session
        var pool: CVPixelBufferPool?
        let attributes = [
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferPoolCreate(nil, nil, attributes, &pool) == kCVReturnSuccess, let pool else {
            throw ToolError.invalid("Could not allocate scaled video buffers.")
        }
        self.pool = pool
    }

    func resize(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        var result: CVPixelBuffer?
        guard let source = sample.imageBuffer,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess,
              let result else { throw ToolError.invalid("Could not read a source video frame.") }
        CVBufferPropagateAttachments(source, result)
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: result) == noErr else {
            throw ToolError.invalid("The native scaler could not resize this video frame.")
        }
        var format: CMVideoFormatDescription?
        var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: sample.presentationTimeStamp,
                                        decodeTimeStamp: sample.decodeTimeStamp)
        var output: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: result,
                                                            formatDescriptionOut: &format) == noErr,
              let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: result,
                                                      formatDescription: format, sampleTiming: &timing,
                                                      sampleBufferOut: &output) == noErr,
              let output else { throw ToolError.invalid("Could not create a scaled video frame.") }
        return output
    }
}

import AVFoundation
import Dispatch

/// Keeps synchronous AVFoundation media reads off Swift's cooperative executor.
final class AsyncAssetReaderSamples: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let queue = DispatchQueue(label: "MacUtilityKit.asset-reader", qos: .userInitiated)

    init(reader: AVAssetReader, output: AVAssetReaderOutput) {
        self.reader = reader
        self.output = output
    }

    func next() async throws -> CMSampleBuffer? {
        try Task.checkCancellation()
        let result: Transfer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(returning: Transfer(buffer: output.copyNextSampleBuffer()))
                }
            }
        } onCancel: { [self] in
            // Cancelling must not wait behind a potentially blocked sample read.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                reader.cancelReading()
            }
        }
        try Task.checkCancellation()
        return result.buffer
    }

    // AVFoundation returns a retained sample. The read queue gives it to one
    // awaiting consumer and never accesses or mutates that sample afterward.
    private struct Transfer: @unchecked Sendable {
        let buffer: CMSampleBuffer?
    }
}

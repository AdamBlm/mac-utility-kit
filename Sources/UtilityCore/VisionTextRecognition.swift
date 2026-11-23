import CoreGraphics
import Dispatch
import os
import Vision

enum VisionTextRecognition {
    // Vision can block while waiting for its inference workers. Suspend Swift tasks
    // during inference and keep only one text recognition request in flight.
    private static let queue = DispatchQueue(label: "MacUtilityKit.VisionTextRecognition", qos: .userInitiated)

    static func languages() throws -> [String] {
        try makeRequest().supportedRecognitionLanguages()
    }

    static func perform(
        on image: CGImage, language: String?, region: CGRect? = nil
    ) async throws -> [VNRecognizedTextObservation] {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let observations: [VNRecognizedTextObservation] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                        let request = makeRequest()
                        if let language {
                            request.recognitionLanguages = [language]
                        } else {
                            request.automaticallyDetectsLanguage = true
                        }
                        if let region {
                            request.regionOfInterest = CGRect(x: region.minX, y: 1 - region.maxY,
                                                              width: region.width, height: region.height)
                        }
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        return request.results ?? []
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return observations
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        return request
    }
}

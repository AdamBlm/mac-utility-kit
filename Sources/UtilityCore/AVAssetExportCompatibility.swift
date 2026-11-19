import AVFoundation

extension AVAssetExportSession {
    package func exportMedia(to output: URL, as fileType: AVFileType) async throws {
        if #available(macOS 26, *) {
            try await export(to: output, as: fileType)
            return
        }

        guard supportedFileTypes.contains(fileType) else {
            throw ToolError.invalid("The selected container is unavailable for this export.")
        }
        outputURL = output
        outputFileType = fileType
        let cancellation = LegacyExportCancellation(session: self)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                exportAsynchronously { completion.resume() }
                if Task.isCancelled { cancelExport() }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        switch status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw error ?? ToolError.invalid("The media export did not complete.")
        }
    }
}


// AVFoundation provides cancelExport for interrupting an export from another thread.
private struct LegacyExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession

    func cancel() { session.cancelExport() }
}

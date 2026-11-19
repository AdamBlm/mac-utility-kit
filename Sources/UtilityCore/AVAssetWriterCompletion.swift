import AVFoundation
import Synchronization

extension AVAssetWriter {
    package func finishMediaWriting() async {
        if #available(macOS 26, *) {
            await finishWriting()
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = Mutex<CheckedContinuation<Void, Never>?>(continuation)
            finishWriting {
                let completion = pending.withLock { current in
                    defer { current = nil }
                    return current
                }
                completion?.resume()
            }
        }
    }
}

import AVFoundation

public struct TextToSpeechVoice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: String?
}

public struct TextToSpeechRequest: Equatable, Sendable {
    public static let maximumCharacters = 20_000
    public var text: String
    public var voiceID: String?
    public var rate: Float

    public init(text: String, voiceID: String? = nil, rate: Float = 1) {
        self.text = text
        self.voiceID = voiceID
        self.rate = rate
    }
}

public struct TextToSpeechAudio: Sendable {
    public let wave: Data
    public let duration: Double

    public func encoded(as format: SpeechAudioFormat) async throws -> Data {
        try Task.checkCancellation()
        guard format == .m4a else { return wave }
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: ".speech-export-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let input = folder.appending(path: "Speech.wav")
        let output = folder.appending(path: "Speech.m4a")
        try wave.write(to: input)
        var options = AudioConvertOptions()
        options.format = .m4a
        options.bitrate = 64
        options.preservesMetadata = false
        _ = try await AudioConvert.export(input, to: output, options: options) { _ in }
        let file = try AVAudioFile(forReading: output)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        guard seconds.isFinite, seconds > 0, abs(seconds - duration) < 0.15 else {
            throw ToolError.invalid("The exported speech did not match the generated duration.")
        }
        try Task.checkCancellation()
        return try Data(contentsOf: output)
    }
}

public enum SpeechAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case wav = "WAV"
    case m4a = "M4A"

    public var id: Self { self }
    public var fileExtension: String { rawValue.lowercased() }
}

@MainActor
public enum TextToSpeech {
    public static func voices() -> [TextToSpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: String?
            switch voice.quality {
            case .enhanced: quality = "Enhanced"
            case .premium: quality = "Premium"
            default: quality = nil
            }
            return TextToSpeechVoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
        }.sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func render(_ request: TextToSpeechRequest) async throws -> TextToSpeechAudio {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("Enter or select the text to speak.")
        }
        guard request.text.count <= TextToSpeechRequest.maximumCharacters else {
            throw ToolError.invalid("Select up to 20,000 characters at a time.")
        }
        guard (0.5...1.5).contains(request.rate) else {
            throw ToolError.invalid("Choose a speech rate from 50% to 150%.")
        }
        let voice: AVSpeechSynthesisVoice
        if let id = request.voiceID {
            guard let selected = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == id }) else {
                throw ToolError.invalid("The selected voice is unavailable. Choose an installed macOS voice.")
            }
            voice = selected
        } else {
            guard let automatic = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
                    ?? AVSpeechSynthesisVoice.speechVoices().first else {
                throw ToolError.invalid("Install a voice in macOS System Settings to synthesize speech.")
            }
            voice = automatic
        }

        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: ".text-to-speech-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let url = folder.appending(path: "Speech.wav")
        let collector = SpeechBufferCollector(url: url)
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = voice
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * request.rate))
        let run = SpeechRenderRun()
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                if collector.isStalled {
                    collector.finish(.failure(ToolError.invalid(
                        "This voice produced no further audio. Choose another voice or download it in macOS System Settings."
                    )))
                    run.stop()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        let duration = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard collector.attach(continuation) else { return }
                run.render(utterance, callback: collector.callback())
            }
        } onCancel: {
            collector.finish(.failure(CancellationError()))
            Task { @MainActor in run.stop() }
        }
        try Task.checkCancellation()
        return TextToSpeechAudio(wave: try Data(contentsOf: url), duration: duration)
    }
}

@MainActor
private final class SpeechRenderRun {
    private let synthesizer = AVSpeechSynthesizer()

    func render(_ utterance: AVSpeechUtterance, callback: @escaping AVSpeechSynthesizer.BufferCallback) {
        synthesizer.write(utterance, toBufferCallback: callback)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

private final class SpeechBufferCollector: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double, any Error>?
    private var result: Result<Double, any Error>?
    private var writer: AVAudioFile?
    private var totalFrames: Int64 = 0
    private var lastBuffer = ContinuousClock.now

    init(url: URL) { self.url = url }

    var isStalled: Bool {
        lock.withLock { result == nil && lastBuffer.duration(to: .now) > .seconds(16) }
    }

    func attach(_ continuation: CheckedContinuation<Double, any Error>) -> Bool {
        lock.withLock {
            if let result {
                continuation.resume(with: result)
                return false
            }
            self.continuation = continuation
            return true
        }
    }

    func callback() -> AVSpeechSynthesizer.BufferCallback {
        { [self] buffer in accept(buffer) }
    }

    private func accept(_ buffer: AVAudioBuffer) {
        lock.withLock {
            guard result == nil else { return }
            lastBuffer = .now
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                complete(.failure(ToolError.invalid("The selected voice returned an unsupported audio format.")))
                return
            }
            guard pcm.frameLength > 0 else {
                if let sampleRate = writer?.processingFormat.sampleRate, totalFrames > 0 {
                    complete(.success(Double(totalFrames) / sampleRate))
                } else {
                    complete(.failure(ToolError.invalid(
                        "The selected voice produced no audio. Choose another voice or download it in macOS System Settings."
                    )))
                }
                return
            }
            do {
                if writer == nil {
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: pcm.format.sampleRate,
                        AVNumberOfChannelsKey: pcm.format.channelCount,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false
                    ]
                    writer = try AVAudioFile(forWriting: url, settings: settings,
                                             commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                guard let writer, writer.processingFormat == pcm.format else {
                    throw ToolError.invalid("The selected voice changed audio format while rendering.")
                }
                try writer.write(from: pcm)
                totalFrames += Int64(pcm.frameLength)
            } catch {
                complete(.failure(error))
            }
        }
    }

    func finish(_ result: Result<Double, any Error>) {
        lock.withLock { complete(result) }
    }

    private func complete(_ result: Result<Double, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        writer = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

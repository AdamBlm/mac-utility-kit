import Foundation

public struct ImageRedactEdit: Equatable, Sendable {
    public var regions: [ImageMaskRegion] = []
    public var effect = ImageRedactionEffect.solid
    public var strength = 0.8
    public var removesMetadata = true

    public init() {}
}

public struct ImageRedactOptions: Equatable, Sendable {
    private struct Timeline: Equatable, Sendable {
        let digest: String
        var current = ImageRedactEdit()
        var past: [ImageRedactEdit] = []
        var future: [ImageRedactEdit] = []
    }

    private var timelines: [URL: Timeline] = [:]

    public init() {}

    public func edit(for input: URL) -> ImageRedactEdit {
        timelines[input]?.current ?? ImageRedactEdit()
    }

    public func hasMasks(_ input: URL) -> Bool { !edit(for: input).regions.isEmpty }
    public func canUndo(_ input: URL) -> Bool { timelines[input]?.past.isEmpty == false }
    public func canRedo(_ input: URL) -> Bool { timelines[input]?.future.isEmpty == false }

    public mutating func discardIfChanged(_ input: URL, source: ImageRedaction.Source) {
        if let active = timelines[input], active.digest != source.digest { timelines[input] = nil }
    }

    public mutating func apply(_ edit: ImageRedactEdit, to input: URL, source: ImageRedaction.Source) {
        discardIfChanged(input, source: source)
        var state = timelines[input] ?? Timeline(digest: source.digest)
        guard state.current != edit else { return }
        state.past.append(state.current)
        if state.past.count > 64 { state.past.removeFirst() }
        state.current = edit
        state.future.removeAll()
        timelines[input] = state
    }

    public mutating func undo(_ input: URL) {
        guard var state = timelines[input], let previous = state.past.popLast() else { return }
        state.future.append(state.current)
        state.current = previous
        timelines[input] = state
    }

    public mutating func redo(_ input: URL) {
        guard var state = timelines[input], let next = state.future.popLast() else { return }
        state.past.append(state.current)
        state.current = next
        timelines[input] = state
    }

    func matches(_ input: URL, source: ImageRedaction.Source) -> Bool {
        timelines[input]?.digest == source.digest
    }
}

public enum ImageRedact {
    public static func export(_ input: URL, to output: URL, options: ImageRedactOptions) throws -> String {
        guard output.standardizedFileURL != input.standardizedFileURL, options.hasMasks(input) else {
            throw ToolError.invalid("Add at least one mask and choose a separate output file.")
        }
        let source = try ImageRedaction.load(input)
        guard options.matches(input, source: source) else {
            throw ToolError.invalid("The source image changed. Reopen it and draw the masks again.")
        }
        let edit = options.edit(for: input)
        let flattened = try ImageRedaction.render(source.image, regions: edit.regions, effect: edit.effect, strength: edit.strength)
        try ImageRedaction.writePNG(flattened, to: output, preserving: edit.removesMetadata ? nil : source.metadata)
        return "\(input.lastPathComponent) · \(edit.regions.count) mask\(edit.regions.count == 1 ? "" : "s") · Flattened PNG"
    }
}

import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageMetadataGroup: String, CaseIterable, Identifiable, Sendable {
    case location, camera, dates, iptc, xmp

    public var id: Self { self }
    public var title: String {
        switch self {
        case .location: "Location"
        case .camera: "Camera"
        case .dates: "Dates"
        case .iptc: "IPTC"
        case .xmp: "XMP"
        }
    }
}

public struct ImageMetadataOptions: Sendable {
    public var groups: Set<ImageMetadataGroup> = [.location]
    public var exifToolExecutable: URL?

    public init() {}
}

public struct ImageMetadataSnapshot: Sendable {
    public let groups: [ImageMetadataGroup: [String]]
}

public struct ImageMetadataRemoval: Sendable {
    public let before: ImageMetadataSnapshot
    public let after: ImageMetadataSnapshot
    public let summary: String
}

public enum ImageMetadata {
    public static func outputExtension(_ input: URL) throws -> String {
        try source(input).fileExtension
    }

    public static func inspect(_ input: URL, options: ImageMetadataOptions = .init()) async throws -> ImageMetadataSnapshot {
        let source = try source(input)
        if let executable = options.exifToolExecutable {
            return try await ExifToolMetadata.inspect(input, executable: executable)
        }
        return nativeSnapshot(source)
    }

    public static func remove(
        _ input: URL, to output: URL, options: ImageMetadataOptions
    ) async throws -> ImageMetadataRemoval {
        guard !options.groups.isEmpty else {
            throw ToolError.invalid("Select at least one metadata group.")
        }
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose an output file that does not already exist.")
        }
        let original = try source(input)
        if options.exifToolExecutable == nil, options.groups != [.location] {
            throw ToolError.invalid("Choose ExifTool to remove camera, date, IPTC, or XMP metadata.")
        }

        let scratch = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let candidate = scratch.appendingPathComponent("image").appendingPathExtension(original.fileExtension)
        let before: ImageMetadataSnapshot
        let after: ImageMetadataSnapshot
        try Task.checkCancellation()
        if let executable = options.exifToolExecutable {
            (before, after) = try await ExifToolMetadata.remove(
                input, to: candidate, groups: options.groups, executable: executable
            )
        } else {
            before = nativeSnapshot(original)
            try copyWithoutGPS(original, to: candidate)
            after = nativeSnapshot(try source(candidate))
        }

        let remaining = ImageMetadataGroup.allCases.filter {
            options.groups.contains($0) && !(after.groups[$0] ?? []).isEmpty
        }
        guard remaining.isEmpty else {
            let verification = "Could not verify removal of " + remaining.map(\.title).joined(separator: ", ") + "."
            if options.exifToolExecutable == nil {
                throw ToolError.invalid(verification + " Choose ExifTool for additional location records.")
            }
            throw ToolError.invalid(verification)
        }

        let result = try source(candidate)
        guard result.fileExtension == original.fileExtension,
              result.dimensions == original.dimensions,
              result.orientation == original.orientation,
              try result.colorProfile() == original.colorProfile() else {
            throw ToolError.invalid("The metadata copy changed the image format, dimensions, orientation, or color profile.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: candidate, to: output)

        let removedCount = options.groups.reduce(0) { $0 + (before.groups[$1]?.count ?? 0) }
        let status = removedCount == 0
            ? "No selected fields found"
            : "\(removedCount) selected metadata \(removedCount == 1 ? "field" : "fields") removed"
        return ImageMetadataRemoval(before: before, after: after, summary: "\(input.lastPathComponent) · \(status)")
    }

    private struct Source {
        let image: CGImageSource
        let type: CFString
        let fileExtension: String
        let properties: [String: Any]

        var orientation: Int { properties[kCGImagePropertyOrientation as String] as? Int ?? 1 }
        var dimensions: [Int] {
            [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight].compactMap { properties[$0 as String] as? Int }
        }

        func colorProfile() throws -> Data? {
            guard let pixels = CGImageSourceCreateImageAtIndex(image, 0, nil) else {
                throw ToolError.invalid("Could not verify the image pixels.")
            }
            return pixels.colorSpace?.copyICCData() as Data?
        }
    }

    private static func source(_ url: URL) throws -> Source {
        guard url.isFileURL,
              let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(image),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else {
            throw ToolError.invalid("Could not read the image.")
        }
        let fileExtension: String
        switch type as String {
        case UTType.jpeg.identifier: fileExtension = "jpg"
        case UTType.png.identifier: fileExtension = "png"
        default: throw ToolError.invalid("Metadata removal supports single-image JPEG and PNG files.")
        }
        guard CGImageSourceGetCount(image) == 1 else {
            throw ToolError.invalid("Metadata removal does not support multi-image files.")
        }
        return Source(image: image, type: type, fileExtension: fileExtension, properties: properties)
    }

    private static func copyWithoutGPS(_ source: Source, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, source.type, 1, nil) else {
            throw ToolError.invalid("Could not create a metadata copy.")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source.image, 0, nil) ?? CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source.image, [
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true
        ] as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw ToolError.invalid("Image I/O could not remove location metadata without recompressing.")
        }
    }

    private static func nativeSnapshot(_ source: Source) -> ImageMetadataSnapshot {
        var recognized: [ImageMetadataGroup: Set<String>] = [:]
        for (key, value) in source.properties {
            if let entries = value as? [String: Any] {
                let namespace = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                for tag in entries.keys {
                    for group in MetadataField.groups(namespace: namespace, name: tag) {
                        recognized[group, default: []].insert("\(namespace):\(tag)")
                    }
                }
            } else {
                for group in MetadataField.groups(namespace: "", name: key) {
                    recognized[group, default: []].insert(key)
                }
            }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source.image, 0, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [
                kCGImageMetadataEnumerateRecursively: true
            ] as CFDictionary) { path, tag in
                let namespace = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
                let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                for group in MetadataField.groups(namespace: namespace, name: name) {
                    // Image I/O mirrors standard EXIF GPS in both views. Keep its property names
                    // when they are visible, but also inspect fields that only occur in the metadata tree.
                    if group == .location, namespace == "exif", name.hasPrefix("GPS"),
                       recognized[.location]?.contains("GPS:" + String(name.dropFirst(3))) == true { continue }
                    recognized[group, default: []].insert(path as String)
                }
                return true
            }
        }
        return ImageMetadataSnapshot(groups: recognized.mapValues { $0.sorted() })
    }
}

enum MetadataField {
    static func groups(namespace: String, name: String) -> Set<ImageMetadataGroup> {
        let namespace = namespace.lowercased()
        let name = normalized(name)
        guard !["file", "system", "composite", "exiftool"].contains(namespace),
              !namespace.hasPrefix("icc") else { return [] }

        var groups: Set<ImageMetadataGroup> = []
        if namespace == "gps" || name.hasPrefix("gps")
            || locations.contains(name) || name.hasPrefix("locationcreated") || name.hasPrefix("locationshown") {
            groups.insert(.location)
        }
        if cameraFields.contains(name) || name.hasPrefix("lens") || name.hasPrefix("camera")
            || name.hasSuffix("serialnumber") || name == "makernote" || name == "makernotes" {
            groups.insert(.camera)
        }
        if dates.contains(name) {
            groups.insert(.dates)
        }
        if namespace == "iptc" { groups.insert(.iptc) }
        if namespace.hasPrefix("xmp") { groups.insert(.xmp) }
        return groups
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let locations: Set = [
        "location", "locationname", "locationid", "sublocation", "city", "state",
        "province", "provincestate", "country", "countrycode", "countryprimarylocationname",
        "countryprimarylocationcode", "worldregion"
    ]
    private static let cameraFields: Set = [
        "make", "model", "serialnumber", "bodyserialnumber", "internalserialnumber",
        "ownername", "uniqueid", "imageuniqueid"
    ]
    private static let dates: Set = [
        "datetime", "datetimeoriginal", "datetimedigitized", "createdate", "modifydate",
        "metadatadate", "datecreated", "timecreated", "digitalcreationdate", "digitalcreationtime",
        "gpsdatestamp", "gpstimestamp", "datetimedate", "dateacquired", "dateoriginal", "creationtime",
        "creationdate", "offsettime", "offsettimeoriginal", "offsettimedigitized", "subsectime",
        "subsectimeoriginal", "subsectimedigitized", "datecreate", "datemodify", "datetimestamp",
        "modificationtime", "modificationdate", "contentcreatedate"
    ]
}

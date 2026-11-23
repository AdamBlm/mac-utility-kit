import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Test func metadataNativeGPSCopyPreservesPixelsOrientationAndColor() async throws {
    let folder = try metadataFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try metadataFixture(in: folder)
    let output = folder.appendingPathComponent("clean.jpg")
    let originalContents = try Data(contentsOf: input)

    let result = try await ImageMetadata.remove(input, to: output, options: .init())
    #expect(result.before.groups[.location]?.contains("GPS:Latitude") == true)
    #expect(result.after.groups[.location]?.isEmpty ?? true)
    #expect(result.after.groups[.camera]?.contains("TIFF:Make") == true)
    #expect(try Data(contentsOf: input) == originalContents)

    let original = try #require(CGImageSourceCreateWithURL(input as CFURL, nil))
    let sanitized = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let originalPixels = try #require(CGImageSourceCreateImageAtIndex(original, 0, nil))
    let sanitizedPixels = try #require(CGImageSourceCreateImageAtIndex(sanitized, 0, nil))
    let cleanedProperties = try #require(CGImageSourceCopyPropertiesAtIndex(sanitized, 0, nil) as NSDictionary?)
    #expect(cleanedProperties[kCGImagePropertyOrientation] as? Int == 6)
    #expect(sanitizedPixels.colorSpace?.copyICCData() as Data? == originalPixels.colorSpace?.copyICCData() as Data?)
    #expect(sanitizedPixels.dataProvider?.data as Data? == originalPixels.dataProvider?.data as Data?)
}

@Test func metadataBatchLabelsSameNamedResultsByInputPosition() async throws {
    let folder = try metadataFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try metadataFixture(in: folder)
    let other = folder.appending(path: "Other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let second = other.appending(path: first.lastPathComponent)
    try FileManager.default.copyItem(at: first, to: second)
    let name = first.lastPathComponent
    let report = try await ToolRunner.run(.removeMetadata, inputs: [first, second], destination: folder,
                                          imageSize: 0) { _ in }
    #expect(report.failures.isEmpty)
    #expect(report.outputs.count == 2)
    #expect(report.metadataResults.map(\.filename) == [name, name])
    #expect(report.metadataResults.map(\.inputLabel) == ["1 - " + name, "2 - " + name])
    #expect(report.metadataResults.allSatisfy { $0.removal.after.groups[.location]?.isEmpty ?? true })
}

@Test func metadataUnsupportedScopeAndExistingDestinationLeaveNoChanges() async throws {
    let folder = try metadataFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try metadataFixture(in: folder)
    let output = folder.appendingPathComponent("clean.jpg")
    let original = try Data(contentsOf: input)
    var options = ImageMetadataOptions()
    options.groups = [.camera]
    await #expect(throws: ToolError.self) {
        try await ImageMetadata.remove(input, to: output, options: options)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    try Data("reserved".utf8).write(to: output)
    await #expect(throws: ToolError.self) {
        try await ImageMetadata.remove(input, to: output, options: .init())
    }
    #expect(try Data(contentsOf: output) == Data("reserved".utf8))
    #expect(try Data(contentsOf: input) == original)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_EXIFTOOL_TEST"] != nil))
func metadataExifToolRemovesOnlyRequestedGroupsAndPreservesAppearance() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_EXIFTOOL_TEST"])
    let folder = try metadataFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try metadataFixture(in: folder)
    let seed = Process()
    seed.executableURL = URL(fileURLWithPath: executable)
    seed.arguments = ["-config", "", "-overwrite_original", "-IPTC:City=Paris", "-XMP:Creator=Example", input.path]
    seed.standardOutput = FileHandle.nullDevice
    try seed.run()
    seed.waitUntilExit()
    #expect(seed.terminationStatus == 0)
    let original = try Data(contentsOf: input)
    let output = folder.appendingPathComponent("clean.jpg")
    var options = ImageMetadataOptions()
    options.exifToolExecutable = URL(fileURLWithPath: executable)
    options.groups = [.location, .camera, .dates]

    let result = try await ImageMetadata.remove(input, to: output, options: options)
    for group in options.groups {
        #expect(result.before.groups[group]?.isEmpty == false)
        #expect(result.after.groups[group]?.isEmpty ?? true)
    }
    #expect(result.after.groups[.xmp]?.contains("XMP-dc:Creator") == true)
    #expect(try Data(contentsOf: input) == original)
    let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
    #expect(properties[kCGImagePropertyOrientation] as? Int == 6)

    options.groups = [.xmp]
    let secondary = folder.appendingPathComponent("no-xmp.jpg")
    let xmp = try await ImageMetadata.remove(input, to: secondary, options: options)
    #expect(xmp.before.groups[.xmp]?.isEmpty == false)
    #expect(xmp.after.groups[.xmp]?.isEmpty ?? true)
    #expect(xmp.after.groups[.camera]?.isEmpty == false)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_EXIFTOOL_TEST"] != nil))
func metadataExifToolPublishesIndependentCopiesForSymbolicLinkInputs() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_EXIFTOOL_TEST"])
    let folder = try metadataFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try metadataFixture(in: folder)
    let bytes = try Data(contentsOf: source)
    let link = folder.appending(path: "link.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    var options = ImageMetadataOptions()
    options.exifToolExecutable = URL(fileURLWithPath: executable)
    options.groups = [.xmp]
    let output = folder.appending(path: "clean.jpg")
    let result = try await ImageMetadata.remove(link, to: output, options: options)
    #expect(result.before.groups[.xmp]?.isEmpty ?? true)
    #expect(try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    let updated = folder.appending(path: "no-gps.jpg")
    options.groups = [.location]
    let removal = try await ImageMetadata.remove(link, to: updated, options: options)
    #expect(removal.before.groups[.location]?.isEmpty == false)
    #expect(removal.after.groups[.location]?.isEmpty ?? true)
    #expect(try updated.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    #expect(try Data(contentsOf: source) == bytes)
    try FileManager.default.removeItem(at: source)
    #expect(try Data(contentsOf: output) == bytes)
}

private func metadataFixtureFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func metadataFixture(in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent("metadata.jpg")
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(
        data: nil, width: 36, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(red: 0.15, green: 0.4, blue: 0.85, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 36, height: 20))
    context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 7, y: 3, width: 16, height: 12))
    let image = try #require(context.makeImage())
    let writer = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(writer, image, [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Test Camera",
            kCGImagePropertyTIFFDateTime: "2026:06:01 12:00:00"
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:06:01 12:00:00"
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 48.8566,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.3522,
            kCGImagePropertyGPSLongitudeRef: "E"
        ]
    ] as CFDictionary)
    try #require(CGImageDestinationFinalize(writer))
    return url
}

@Test func metadataNativeRejectsCustomXMPGPSIfItCannotBeRemoved() async throws {
    let folder = try metadataFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pixels = try metadataFixture(in: folder)
    let pixelSource = try #require(CGImageSourceCreateWithURL(pixels as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(pixelSource, 0, nil))
    let input = folder.appendingPathComponent("custom.png")
    let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:custom="https://example.invalid/custom/">
        <custom:GPSLatitude>48.85</custom:GPSLatitude>
        <custom:GPSLongitude>2.35</custom:GPSLongitude>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
    let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData))
    let writer = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImageAndMetadata(writer, image, metadata, nil)
    try #require(CGImageDestinationFinalize(writer))
    let before = try await ImageMetadata.inspect(input)
    #expect(before.groups[.location]?.contains(where: { $0.contains("GPSLatitude") }) == true)

    let output = folder.appendingPathComponent("clean.png")
    do {
        let report = try await ImageMetadata.remove(input, to: output, options: .init())
        // Accept future Image I/O versions that remove the custom XMP, but never publish the coordinates unchanged.
        #expect(report.after.groups[.location]?.isEmpty ?? true)
        let clean = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        if let cleanMetadata = CGImageSourceCopyMetadataAtIndex(clean, 0, nil),
           let xmp = CGImageMetadataCreateXMPData(cleanMetadata, nil) as Data? {
            #expect(!String(decoding: xmp, as: UTF8.self).contains("GPSLatitude"))
        }
    } catch let error as ToolError {
        #expect(error.localizedDescription.contains("Choose ExifTool"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

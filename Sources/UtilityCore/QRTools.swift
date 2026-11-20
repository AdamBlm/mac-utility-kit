import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum QRPayload: Equatable, Sendable {
    public enum Security: String, CaseIterable, Sendable {
        case wpa = "WPA/WPA2", wep = "WEP", open = "Open"
    }

    case text(String)
    case url(String)
    case wiFi(name: String, security: Security, password: String, hidden: Bool)

    public func encoded() throws -> String {
        switch self {
        case .text(let value):
            guard !value.isEmpty else { throw QRToolError.emptyText }
            return value
        case .url(let value):
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text, encodingInvalidCharacters: false),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host(), !host.isEmpty else {
                throw QRToolError.invalidURL
            }
            return text
        case .wiFi(let name, let security, let password, let hidden):
            guard !name.isEmpty else { throw QRToolError.emptyNetwork }
            guard security == .open || !password.isEmpty else { throw QRToolError.emptyPassword }
            let type = switch security {
            case .wpa: "WPA"
            case .wep: "WEP"
            case .open: "nopass"
            }
            let secret = security == .open ? "" : "P:\(Self.escape(password));"
            return "WIFI:T:\(type);S:\(Self.escape(name));\(secret)\(hidden ? "H:true;" : "");"
        }
    }

    private static func escape(_ value: String) -> String {
        let delimiters = "\\;,:\"".unicodeScalars
        return value.unicodeScalars.reduce(into: "") { result, scalar in
            if delimiters.contains(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
    }
}

public struct QRColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    private var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func isLighter(than other: QRColor) -> Bool { luminance > other.luminance }

    public func contrast(against other: QRColor) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

public struct QRCodeOptions: Equatable, Sendable {
    public enum Correction: String, CaseIterable, Sendable {
        case low = "L", medium = "M", quartile = "Q", high = "H"

        public var title: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .quartile: "Quartile"
            case .high: "High"
            }
        }
    }

    public var size = 512
    public var correction: Correction = .medium
    public var foreground = QRColor(red: 0, green: 0, blue: 0)
    public var background = QRColor(red: 255, green: 255, blue: 255)

    public init() {}
}

public struct QRDetection: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let type: String
    public let payload: String
}

public enum QRToolError: LocalizedError {
    case emptyText, invalidURL, emptyNetwork, emptyPassword, unsupportedSize, encoding, export, unreadableImage

    public var errorDescription: String? {
        switch self {
        case .emptyText: "Enter text to generate a QR code."
        case .invalidURL: "Enter a complete HTTP or HTTPS URL."
        case .emptyNetwork: "Enter the Wi-Fi network name."
        case .emptyPassword: "Enter the Wi-Fi password."
        case .unsupportedSize: "Choose an image size between 128 and 4096 pixels."
        case .encoding: "The payload could not be encoded at this error correction level."
        case .export: "The QR code could not be exported as PNG."
        case .unreadableImage: "This image could not be read."
        }
    }
}

public enum QRTools {
    package static func selectedText(
        from detections: [QRDetection], ids: Set<QRDetection.ID>
    ) -> (text: String, concealed: Bool)? {
        let selected = detections.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        return (selected.map(\.payload).joined(separator: "\n"),
                selected.contains { isWiFiPayload($0.payload) })
    }

    package static func isWiFiPayload(_ payload: String) -> Bool {
        // ZXing strips a leading byte order mark before parsing Wi-Fi payloads.
        let text = payload.first == "\u{FEFF}" ? payload.dropFirst() : payload[...]
        return text.prefix(5).uppercased() == "WIFI:"
    }

    private static let context = CIContext()

    public static func generate(_ payload: QRPayload, options: QRCodeOptions = QRCodeOptions()) throws -> CGImage {
        guard (128...4096).contains(options.size) else { throw QRToolError.unsupportedSize }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(try payload.encoded().utf8)
        filter.correctionLevel = options.correction.rawValue
        guard let output = filter.outputImage, !output.extent.isEmpty else {
            throw QRToolError.encoding
        }
        let size = options.size
        let modules = Int(output.extent.width)
        let scale = size / (modules + 8)
        guard scale > 0 else { throw QRToolError.encoding }
        let width = modules * scale
        let origin = (size - width) / 2
        let rect = CGRect(x: origin, y: origin, width: width, height: width)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw QRToolError.encoding
        }
        func color(_ value: QRColor) -> CGColor {
            CGColor(red: CGFloat(value.red) / 255, green: CGFloat(value.green) / 255, blue: CGFloat(value.blue) / 255, alpha: 1)
        }
        let remap = CIFilter.falseColor()
        remap.inputImage = output
        remap.color0 = CIColor(cgColor: color(options.foreground))
        remap.color1 = CIColor(cgColor: color(options.background))
        guard let colored = remap.outputImage, let pixels = context.createCGImage(colored, from: output.extent) else {
            throw QRToolError.encoding
        }
        bitmap.setFillColor(color(options.background))
        bitmap.fill(CGRect(x: 0, y: 0, width: size, height: size))
        bitmap.interpolationQuality = .none
        bitmap.draw(pixels, in: rect)
        guard let image = bitmap.makeImage() else { throw QRToolError.encoding }
        return image
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw QRToolError.export
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw QRToolError.export }
        return data as Data
    }

    public static func detect(in url: URL) throws -> [QRDetection] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw QRToolError.unreadableImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        func decode(maximumEdge: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumEdge
            ] as CFDictionary)
        }
        try Task.checkCancellation()
        guard let overview = decode(maximumEdge: 4_096) else { throw QRToolError.unreadableImage }
        let edge = max(width, height)
        let detail: CGImage
        if edge > 4_096, canScanTiles(width: width, height: height) {
            try Task.checkCancellation()
            detail = decode(maximumEdge: edge) ?? overview
        } else {
            detail = overview
        }
        return try detect(in: detail, overview: overview)
    }

    private struct LocatedDetection {
        let detection: QRDetection
        let bounds: CGRect
    }

    public static func detect(in image: CGImage) throws -> [QRDetection] {
        try detect(in: image, overview: image)
    }

    private static func detect(in image: CGImage, overview: CGImage) throws -> [QRDetection] {
        let width = image.width
        let height = image.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        var results = try scan(overview, in: full)
        if canScanTiles(width: width, height: height), max(width, height) > 2_048 {
            let tileWidth = min(width, 1_024)
            let tileHeight = min(height, 1_024)
            for y in tileStarts(length: height, size: tileHeight) {
                for x in tileStarts(length: width, size: tileWidth) {
                    try Task.checkCancellation()
                    let tile = CGRect(x: x, y: y, width: tileWidth, height: tileHeight)
                    guard let cropped = image.cropping(to: tile) else { continue }
                    let visionRect = CGRect(x: x, y: height - y - tileHeight,
                                            width: tileWidth, height: tileHeight)
                    for match in try scan(cropped, in: visionRect) {
                        if !results.contains(where: { isSameDetection($0, match) }) {
                            results.append(match)
                        }
                    }
                }
            }
        }
        return results.sorted { left, right in
            if left.bounds.midY == right.bounds.midY { return left.bounds.minX < right.bounds.minX }
            return left.bounds.midY > right.bounds.midY
        }.map(\.detection)
    }

    private static func canScanTiles(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && max(width, height) <= 16_384 && width <= 24_000_000 / height
    }

    private static func tileStarts(length: Int, size: Int) -> [Int] {
        let last = length - size
        guard last > 0 else { return [0] }
        return Array(stride(from: 0, to: last, by: 768)) + [last]
    }

    private static func isSameDetection(_ first: LocatedDetection, _ second: LocatedDetection) -> Bool {
        guard first.detection.type == second.detection.type, first.detection.payload == second.detection.payload else { return false }
        let overlap = first.bounds.intersection(second.bounds)
        let area = min(first.bounds.width * first.bounds.height, second.bounds.width * second.bounds.height)
        return !overlap.isNull && area > 0 && overlap.width * overlap.height >= 0.6 * area
    }

    private static func scan(_ image: CGImage, in rect: CGRect) throws -> [LocatedDetection] {
        try Task.checkCancellation()
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            let payload: String
            if let text = observation.payloadStringValue {
                payload = text
            } else if let data = observation.payloadData {
                payload = data.base64EncodedString()
            } else {
                return nil
            }
            let type = observation.symbology == .qr ? "QR Code" : observation.symbology.rawValue
                .replacingOccurrences(of: "VNBarcodeSymbology", with: "")
            let bounds = observation.boundingBox
            return LocatedDetection(
                detection: QRDetection(type: observation.payloadStringValue == nil ? "\(type) (Base64)" : type, payload: payload),
                bounds: CGRect(x: rect.minX + bounds.minX * rect.width, y: rect.minY + bounds.minY * rect.height,
                               width: bounds.width * rect.width, height: bounds.height * rect.height)
            )
        }
    }
}

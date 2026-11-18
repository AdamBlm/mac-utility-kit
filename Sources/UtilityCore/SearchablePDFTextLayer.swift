import CoreGraphics
import CoreText
import Foundation
import PDFKit

enum SearchablePDFTextLayer {
    struct Line {
        let text: String
        let bounds: CGRect
    }

    struct Raster {
        let image: CGImage
        let bounds: CGRect
        let rasterToPage: CGAffineTransform

        func pixelBounds(for recognition: CGRect) -> CGRect {
            CGRect(x: recognition.minX * bounds.width, y: recognition.minY * bounds.height,
                   width: recognition.width * bounds.width, height: recognition.height * bounds.height)
        }

        func pageBounds(for recognition: CGRect) -> CGRect {
            pixelBounds(for: recognition).applying(rasterToPage)
        }
    }

    static func rasterize(_ page: PDFPage, limit: Int) throws -> Raster {
        guard let reference = page.pageRef else { throw ToolError.invalid("This page has no readable content.") }
        let crop = reference.getBoxRect(.cropBox).intersection(reference.getBoxRect(.mediaBox))
        let quarterTurn = abs(reference.rotationAngle % 180) == 90
        let width = quarterTurn ? crop.height : crop.width
        let height = quarterTurn ? crop.width : crop.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw ToolError.invalid("This page has invalid dimensions.")
        }
        let scale = min(4, Double(limit) / max(width, height))
        let pixelsWide = max(1, Int((width * scale).rounded()))
        let pixelsHigh = max(1, Int((height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
        let pointBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = reference.getDrawingTransform(.cropBox, rect: pointBounds, rotate: 0, preserveAspectRatio: true)
            .concatenating(CGAffineTransform(scaleX: bounds.width / width, y: bounds.height / height))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError.invalid("Could not render this page for recognition.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.clip(to: bounds)
        context.concatenate(transform)
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw ToolError.invalid("Could not rasterize this page.") }
        return Raster(image: image, bounds: bounds, rasterToPage: transform.inverted())
    }

    static func thumbnail(_ image: CGImage) -> CGImage {
        let scale = min(1, 1000 / Double(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func pageWithText(_ original: PDFPage, raster: Raster, lines: [Line]) throws -> PDFPage {
        guard let reference = original.pageRef else { throw ToolError.invalid("This page has no readable content.") }
        var userUnit: CGPDFReal = 1
        if let dictionary = reference.dictionary, CGPDFDictionaryGetNumber(dictionary, "UserUnit", &userUnit), userUnit != 1 {
            throw ToolError.invalid("This page uses a custom PDF unit and its geometry could not be preserved.")
        }
        var media = reference.getBoxRect(.mediaBox)
        let storage = NSMutableData()
        guard let consumer = CGDataConsumer(data: storage as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw ToolError.invalid("Could not create the searchable page.")
        }
        let boxes: [CFString: Data] = [
            kCGPDFContextMediaBox: encoded(media),
            kCGPDFContextCropBox: encoded(reference.getBoxRect(.cropBox)),
            kCGPDFContextBleedBox: encoded(reference.getBoxRect(.bleedBox)),
            kCGPDFContextTrimBox: encoded(reference.getBoxRect(.trimBox)),
            kCGPDFContextArtBox: encoded(reference.getBoxRect(.artBox))
        ]
        context.beginPDFPage(boxes as CFDictionary)
        context.drawPDFPage(reference)
        context.concatenate(raster.rasterToPage)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for line in lines {
            let bounds = raster.pixelBounds(for: line.bounds)
            guard !bounds.isEmpty else { continue }
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            let rendering = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(rendering, &ascent, &descent, nil)
            let height = ascent + descent
            guard width > 0, height > 0 else { continue }
            context.saveGState()
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / width, y: bounds.height / height)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: descent)
            context.setTextDrawingMode(.invisible)
            CTLineDraw(rendering, context)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: storage as Data), let page = document.page(at: 0) else {
            throw ToolError.invalid("Could not reopen the searchable page.")
        }
        page.rotation = original.rotation
        for annotation in original.annotations {
            guard let copied = annotation.copy() as? PDFAnnotation else {
                throw ToolError.invalid("A page annotation could not be preserved.")
            }
            page.addAnnotation(copied)
        }
        return page
    }

    private static func encoded(_ rectangle: CGRect) -> Data {
        withUnsafeBytes(of: rectangle) { Data($0) }
    }
}

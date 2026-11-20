import AppKit
import PDFKit

public struct PDFPageNumberOptions: Sendable {
    public enum Placement: String, CaseIterable, Identifiable, Sendable {
        case topLeft = "Top left"
        case topCenter = "Top center"
        case topRight = "Top right"
        case bottomLeft = "Bottom left"
        case bottomCenter = "Bottom center"
        case bottomRight = "Bottom right"

        public var id: Self { self }
    }

    public var range = ""
    public var startNumber = 1
    public var placement: Placement = .bottomCenter

    public init() {}
}

package enum PDFPageNumbers {
    package static func labels(pageCount: Int, options: PDFPageNumberOptions) throws -> [Int: String] {
        guard (1...999_999).contains(options.startNumber) else {
            throw ToolError.invalid("Choose a starting page number from 1 to 999,999.")
        }
        let selected = try PageSelection.indices(options.range, pageCount: pageCount).sorted()
        guard !selected.isEmpty else { throw ToolError.invalid("Choose pages to number.") }
        guard selected.count - 1 <= Int.max - options.startNumber else {
            throw ToolError.invalid("The page numbering sequence is too long.")
        }
        return Dictionary(uniqueKeysWithValues: selected.enumerated().map {
            ($0.element, String(options.startNumber + $0.offset))
        })
    }

    package static func add(_ label: String, to page: PDFPage, placement: PDFPageNumberOptions.Placement) throws -> PDFAnnotation {
        let geometry = try PDFRedactionGeometry(page)
        let size = geometry.displaySize
        let fontSize = min(12, min(size.height / 8, size.width / CGFloat(max(label.count + 3, 12))))
        guard fontSize >= 3 else { throw ToolError.invalid("This PDF page is too small to number.") }
        let margin = min(20, min(size.height / 12, size.width / 12))
        let font = NSFont.systemFont(ofSize: fontSize)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        let width = textWidth + fontSize
        let height = fontSize * 1.7
        let x: CGFloat = switch placement {
        case .topLeft, .bottomLeft: margin
        case .topCenter, .bottomCenter: (size.width - width) / 2
        case .topRight, .bottomRight: size.width - margin - width
        }
        let y: CGFloat = switch placement {
        case .topLeft, .topCenter, .topRight: size.height - margin - height
        case .bottomLeft, .bottomCenter, .bottomRight: margin
        }
        let displayBounds = CGRect(x: x, y: y, width: width, height: height)
        let pageBounds = displayBounds.applying(geometry.pageToDisplay.inverted()).standardized
        let number = PDFAnnotation(bounds: pageBounds, forType: .freeText, withProperties: nil)
        number.contents = label
        number.userName = "Page Number"
        number.font = font
        number.fontColor = .black
        number.alignment = .center
        number.color = .clear
        number.shouldPrint = true
        let border = PDFBorder()
        border.lineWidth = 0
        number.border = border
        page.addAnnotation(number)
        return number
    }
}

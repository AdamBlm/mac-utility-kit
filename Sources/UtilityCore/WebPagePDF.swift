import CoreGraphics
import Foundation

public enum WebPagePDFLayout: String, CaseIterable, Identifiable, Sendable {
    case paginated = "Paginated"
    case continuous = "Continuous"

    public var id: Self { self }
}

public struct WebPagePDFOptions: Equatable, Sendable {
    public var layout = WebPagePDFLayout.paginated
    public var paper = PDFPrintPaper.a4
    public var margin = PDFPrintMargin.comfortable
    public var printBackgrounds = false

    public init() {}
}

public enum WebPagePDF {
    public static func address(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text, encodingInvalidCharacters: false), permits(url) else {
            throw ToolError.invalid("Enter a complete HTTP or HTTPS webpage URL.")
        }
        return url
    }

    static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty, url.user() == nil, url.password() == nil else { return false }
        return true
    }

    public static func continuousSize(width: Double, height: Double) throws -> CGSize {
        let width = width.rounded(.up)
        let height = height.rounded(.up)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 14_400, height <= 14_400, width * height <= 24_000_000 else {
            throw ToolError.invalid("This webpage is too large for one continuous PDF page. Choose Paginated output.")
        }
        return CGSize(width: width, height: height)
    }
}

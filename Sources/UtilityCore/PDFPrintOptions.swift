import CoreGraphics

public enum PDFPrintPaper: String, CaseIterable, Identifiable, Sendable {
    case a4 = "A4"
    case letter = "US Letter"
    case legal = "US Legal"

    public var id: Self { self }

    public var size: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        }
    }
}

public enum PDFPrintMargin: String, CaseIterable, Identifiable, Sendable {
    case compact = "0.5 in"
    case comfortable = "0.75 in"
    case wide = "1 in"

    public var id: Self { self }

    public var points: CGFloat {
        switch self {
        case .compact: 36
        case .comfortable: 54
        case .wide: 72
        }
    }
}

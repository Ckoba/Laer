import CoreGraphics
import Foundation
import PDFKit
import Vision

public struct DocumentOCRBatch: Sendable {
    public let startPage: Int
    public let pages: [DocumentSearchPage]
    public let nextPage: Int?

    public init(startPage: Int, pages: [DocumentSearchPage], nextPage: Int?) {
        self.startPage = startPage
        self.pages = pages
        self.nextPage = nextPage
    }
}

/// Apple Vision fallback for saved PDF pages with little or no embedded text.
public enum DocumentOCR {
    private static let maxRasterDimension: CGFloat = 1_536
    private static let maxPagesPerBatch = 16
    private static let maxScansPerBatch = 2

    /// Runs on a utility executor. A batch owns at most one rendered page at a time.
    public static func readPDF(from url: URL, startPage: Int) throws -> DocumentOCRBatch {
        try readPDF(from: url, startPage: startPage, recognize: recognizeText)
    }

    static func readPDF(
        from url: URL, startPage: Int, recognize: (CGImage) throws -> String
    ) throws -> DocumentOCRBatch {
        try Task.checkCancellation()
        let start = max(0, startPage)
        let finished = DocumentOCRBatch(startPage: start, pages: [], nextPage: nil)
        guard url.pathExtension.lowercased() == "pdf",
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let bytes = values.fileSize, bytes <= DocumentSearchText.maxFileSize,
              let document = PDFDocument(url: url), !document.isLocked else { return finished }

        let end = min(document.pageCount, DocumentSearchText.maxPDFPages)
        guard start < end else { return finished }
        var pages: [DocumentSearchPage] = []
        var page = start
        var scans = 0
        while page < end, page - start < maxPagesPerBatch, scans < maxScansPerBatch {
            try Task.checkCancellation()
            let index = page
            try autoreleasepool {
                guard let source = document.page(at: index), needsRecognition(source.string),
                      let reference = source.pageRef else { return }
                scans += 1
                guard let raster = rasterize(reference) else { return }
                do {
                    let text = try recognize(raster).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        // At most 400 pages, keeping derived text bounded even across resumptions.
                        pages.append(DocumentSearchPage(index: index, text: String(text.prefix(1_000))))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A damaged or unrecognizable page does not discard the rest of the batch.
                }
            }
            try Task.checkCancellation()
            page += 1
        }
        return DocumentOCRBatch(startPage: start, pages: pages, nextPage: page < end ? page : nil)
    }

    static func needsRecognition(_ text: String?) -> Bool {
        guard let text else { return true }
        // Page numbers and short running headers do not count as a usable text layer.
        return text.lazy.filter(\.isLetter).prefix(24).count < 24
    }

    private static func rasterize(_ page: CGPDFPage) -> CGImage? {
        let bounds = page.getBoxRect(.cropBox)
        let rotated = !page.rotationAngle.isMultiple(of: 180)
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let longest = max(width, height)
        let pixelsWide = max(1, Int(maxRasterDimension * (width / longest)))
        let pixelsHigh = max(1, Int(maxRasterDimension * (height / longest)))
        let canvas = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
        guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(canvas)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = ["da-DK", "en-US"].filter(supported.contains)
        if !languages.isEmpty { request.recognitionLanguages = languages }
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

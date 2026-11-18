import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import LaerCore

@Suite struct DocumentOCRTests {
    @Test func skipsEmbeddedTextAndResumesAfterTheLastScannedPage() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reading.pdf")
        try writePDF(file, imagePages: [false, true, true, true])

        let first = try DocumentOCR.readPDF(from: file, startPage: 0) { raster in
            #expect(raster.width <= 1_536 && raster.height <= 1_536)
            return "Field observations"
        }
        #expect(first.pages.compactMap(\.index) == [1, 2])
        #expect(first.nextPage == 3)
        let second = try DocumentOCR.readPDF(from: file, startPage: try #require(first.nextPage)) { _ in
            "Field observations"
        }
        #expect(second.pages.compactMap(\.index) == [3])
        #expect(second.nextPage == nil)
        #expect(DocumentOCR.needsRecognition("Page 2"))
    }

    @Test func visionRecognizesTextInARasterPDF() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scan.pdf")
        try writePDF(file, imagePages: [true])
        let pdf = try #require(PDFDocument(url: file))
        #expect(pdf.page(at: 0)?.string?.isEmpty != false)
        let batch = try DocumentOCR.readPDF(from: file, startPage: 0)
        #expect(batch.pages.first?.index == 0)
        #expect(batch.pages.first?.text.lowercased().contains("field observations") == true)
    }

    @Test func cancellationStopsBeforeRendering() async throws {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentOCR.readPDF(from: URL(fileURLWithPath: "/unused.pdf"), startPage: 0)
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePDF(_ url: URL, imagePages: [Bool]) throws {
        var box = CGRect(x: 0, y: 0, width: 800, height: 600)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let bitmap = try #require(CGContext(data: nil, width: 1_600, height: 1_200, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                           bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.scaleBy(x: 2, y: 2)
        draw(in: bitmap, box: box)
        let image = try #require(bitmap.makeImage())
        for rendered in imagePages {
            pdf.beginPDFPage(nil)
            if rendered { pdf.draw(image, in: box) }
            else { draw(in: pdf, box: box) }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    private func draw(in context: CGContext, box: CGRect) {
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        let font = CTFontCreateWithName("Helvetica" as CFString, 50, nil)
        let text = NSAttributedString(string: "Summer field observations today", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 55, y: 360)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
}

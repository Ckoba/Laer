import Foundation
import PDFKit
import Testing
@testable import LaerCore

@Suite struct LinearizedPDFPreviewTests {
    @Test func reconstructsAReadableFirstPageBeforeThePageTreeArrives() throws {
        let (prefix, length) = Self.documentPrefix()
        let header = try #require(LinearizedPDFPreview.header(in: prefix, length: length))
        #expect(header.byteCount == prefix.count)
        let bytes = try #require(LinearizedPDFPreview.page(from: prefix, header: header))
        let document = try #require(PDFDocument(data: bytes))
        let page = try #require(document.page(at: 0))
        #expect(document.pageCount == 1)
        #expect(page.string == "Preview text")
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 300, height: 200))
    }

    @Test func rejectsIncompleteAndMismatchedRepresentations() throws {
        let (prefix, length) = Self.documentPrefix()
        let header = try #require(LinearizedPDFPreview.header(in: prefix, length: length))
        #expect(LinearizedPDFPreview.header(in: prefix, length: length + 1) == nil)
        #expect(LinearizedPDFPreview.page(from: Data(prefix.dropLast()), header: header) == nil)
    }

    @Test func defersEncryptedAndAnnotatedPDFsToTheOrdinaryReader() throws {
        for variant in [Self.documentPrefix(encrypted: true), Self.documentPrefix(annotated: true)] {
            let header = try #require(LinearizedPDFPreview.header(in: variant.0, length: variant.1))
            #expect(LinearizedPDFPreview.page(from: variant.0, header: header) == nil)
        }
    }

    private static func documentPrefix(encrypted: Bool = false, annotated: Bool = false) -> (Data, Int) {
        let header = "%PDF-1.5\n"
        let linearization = "1 0 obj\n<< /Linearized 1 /L SOURCE_LEN /O 3 /E PAGE_END__ /N 2 >>\nendobj\n"
        let stream = "BT /F1 12 Tf 30 60 Td (Preview text) Tj ET\n"
        let objects = [
            "2 0 obj\n<< /Type /Catalog /Pages 6 0 R >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 6 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R\(annotated ? " /Annots [7 0 R]" : "") >>\nendobj\n",
            "4 0 obj\n<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream\nendobj\n",
            "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
        ]
        let trailer = "trailer\n<< /Root 2 0 R /Size 8 /Prev 999999 \(encrypted ? "/Encrypt 7 0 R " : "")/ID [<AB><CD>] >>\nstartxref\n0\n%%EOF\n"
        let entryLength = "0000000000 00000 n \n".utf8.count
        let section = "xref\n1 5\n"
        let padding = "%" + String(repeating: " ", count: 900) + "\n"
        var offset = header.utf8.count + linearization.utf8.count + section.utf8.count + 5 * entryLength + trailer.utf8.count + padding.utf8.count
        var entries = String(format: "%010d 00000 n \n", header.utf8.count)
        for object in objects {
            entries += String(format: "%010d 00000 n \n", offset)
            offset += object.utf8.count
        }
        let length = offset + 2500
        let preface = linearization.replacingOccurrences(of: "SOURCE_LEN", with: String(format: "%010d", length))
            .replacingOccurrences(of: "PAGE_END__", with: String(format: "%010d", offset))
        let prefix = header + preface + section + entries + trailer + padding + objects.joined()
        return (Data(prefix.utf8), length)
    }
}

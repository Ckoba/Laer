import Foundation
import Testing
@testable import LaerCore

@Suite struct SearchBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LAER_SEARCH_BENCHMARK"] == "1"))
    func measuresMetadataAndDocumentQueries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("benchmark.sqlite")
        let clock = ContinuousClock()
        let start = clock.now
        let index = try SearchDatabase(url: url)
        for batch in 0..<10 {
            let hits = (0..<5_000).map { offset in
                let id = batch * 5_000 + offset
                return SearchHit(id: "metadata-\(id)", kind: .material,
                                 title: "Undervisningsplan \(Self.code("modul", id))",
                                 detail: "MAT101, økonomi, noter om CO2", courseId: id % 30)
            }
            try await index.update(group: "course-batch-\(batch)", hits: hits, complete: true)
        }
        let passage = "Lineær regression og variation. Beregn middelværdien for hver observation. "
        var bytes = 0
        for id in 0..<5_000 {
            let body = "\(Self.code("dokument", id)) " + String(repeating: passage, count: 14)
            bytes += body.utf8.count
            let asset = LocalAsset(id: "reading-\(id)", relativePath: "revision-1.pdf", displayName: "Læsning \(id).pdf",
                                   byteCount: Int64(body.utf8.count), contentType: "application/pdf", downloadedAt: .distantPast)
            try await index.replaceDocument(asset: asset, resource: nil, pages: [DocumentSearchPage(index: 0, text: body)])
        }
        let ingestion = start.duration(to: clock.now)
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let fresh = try SearchDatabase(url: url)
        let freshStart = clock.now
        _ = try await fresh.search("lineær regression", scope: .everywhere, activeCourseIds: [], limit: 60)
        let freshQuery = freshStart.duration(to: clock.now)

        var metadata: [Double] = []
        var documents: [Double] = []
        var broad: [Double] = []
        var topThree = 0
        for offset in 0..<40 {
            let metadataId = (offset * 1_009) % 50_000
            let documentId = (offset * 103) % 5_000
            let samples = [
                (Self.code("modul", metadataId), "metadata-\(metadataId)"),
                (Self.code("dokument", documentId), "document-reading-\(documentId)-0"),
                (offset.isMultiple(of: 2) ? "økonomi CO2" : "lineær regression", ""),
            ]
            for (category, sample) in samples.enumerated() {
                let began = clock.now
                let results = try await fresh.search(sample.0, scope: .everywhere, activeCourseIds: [], limit: 60)
                let elapsed = Self.milliseconds(began.duration(to: clock.now))
                #expect(!results.isEmpty)
                if results.prefix(3).contains(where: { $0.id == sample.1 }) { topThree += 1 }
                switch category {
                case 0: metadata.append(elapsed)
                case 1: documents.append(elapsed)
                default: broad.append(elapsed)
                }
            }
        }
        #expect(topThree == 80)
        print("SEARCH_BENCHMARK metadata=50000 documents=5000 pages=5000 text_bytes=\(bytes) index_bytes=\(fileSize) "
            + "ingest_ms=\(Self.milliseconds(ingestion)) fresh_connection_ms=\(Self.milliseconds(freshQuery)) "
            + "metadata_p95_ms=\(Self.p95(metadata)) documents_p95_ms=\(Self.p95(documents)) broad_p95_ms=\(Self.p95(broad)) top_three=\(topThree)/80")
    }

    private static func code(_ prefix: String, _ id: Int) -> String {
        prefix + String(format: "%05d", id)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func p95(_ samples: [Double]) -> Double {
        samples.sorted()[Int((Double(samples.count) * 0.95).rounded(.up)) - 1]
    }
}

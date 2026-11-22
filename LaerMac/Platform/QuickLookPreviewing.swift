import Foundation

/// Shared with the app, which keeps an identical copy so the targets stay independent.
@objc(QuickLookPreviewing)
protocol QuickLookPreviewing {
    func preparePreview(reply: @escaping () -> Void)
    func writePreview(sourcePath: String, outputPath: String, reply: @escaping (Bool) -> Void)
}

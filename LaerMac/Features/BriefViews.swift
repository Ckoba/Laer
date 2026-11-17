import LaerCore
import SwiftUI

/// A brief's short read on a lecture card: the 15-minute part, or a note that no teaching is expected.
struct BriefSummary: View {
    let note: LectureNote

    var body: some View {
        if note.status == .noTeaching {
            BriefLabel(title: "No teaching expected")
        } else if let section = note.brief?.summary {
            VStack(alignment: .leading, spacing: Space.s2) {
                BriefLabel(title: "Brief")
                Text(BriefMarkdown.text(section.displayText(linkScheme: nil)))
                    .font(Type.t12)
                    .foregroundStyle(Color.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The whole brief, in the note's order. Links to readings open in the viewer.
struct BriefBlock: View {
    @Environment(AppModel.self) private var model
    let note: LectureNote

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            BriefLabel(title: note.status == .noTeaching ? "Brief · No teaching expected" : "Brief")
            ForEach(note.brief?.sections ?? []) { section in
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let title = section.title {
                        Text(title)
                            .font(Type.t12)
                            .foregroundStyle(Color.textMuted)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(BriefMarkdown.text(section.displayText(linkScheme: AppModel.noteLinkScheme)))
                        .font(Type.body)
                        .lineSpacing(Type.bodyLineSpacing)
                        .foregroundStyle(section.kind == .lead ? Color.textMuted : Color.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == AppModel.noteLinkScheme {
                // SwiftUI calls this on the main thread.
                return MainActor.assumeIsolated { model.openNoteLink(url) } ? .handled : .discarded
            }
            return .systemAction
        })
    }
}

private struct BriefLabel: View {
    let title: String

    var body: some View {
        Label(title, systemImage: Symbol.brief)
            .labelStyle(CompactLabelStyle())
            .font(Type.t11)
            .foregroundStyle(Color.textMuted)
    }
}

enum BriefMarkdown {
    /// Inline Markdown with line breaks kept. Text that does not parse shows as written.
    static func text(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

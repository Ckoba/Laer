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

/// The brief on a plan: its first section (the summary) in view, the rest folded behind "Brief".
/// Links to readings open in the viewer.
struct BriefBlock: View {
    let note: LectureNote
    @State private var showsRest = false

    private var sections: [BriefSection] {
        (note.brief?.sections ?? []).filter { $0.kind != .lead }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            if note.status == .noTeaching {
                BriefLabel(title: "No teaching expected")
            }
            if let first = sections.first {
                sectionView(first, showsTitle: false)
                let rest = sections.dropFirst()
                if !rest.isEmpty {
                    Disclosure(title: "Brief", isExpanded: $showsRest)
                        .padding(.horizontal, -Space.s8)
                    if showsRest {
                        ForEach(Array(rest)) { sectionView($0, showsTitle: true) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            // Links to other notes have nowhere to go now that briefs come only from this Mac.
            if url.scheme == AppModel.noteLinkScheme { return .discarded }
            return .systemAction
        })
    }

    private func sectionView(_ section: BriefSection, showsTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if showsTitle, let title = section.title {
                Text(title)
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(BriefMarkdown.text(section.displayText(linkScheme: AppModel.noteLinkScheme)))
                .font(Type.body)
                .lineSpacing(Type.bodyLineSpacing)
                .foregroundStyle(Color.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .readingWidth()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

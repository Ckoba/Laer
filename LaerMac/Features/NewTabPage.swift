import LaerCore
import SwiftUI

/// What a New tab shows: search, the files opened most recently, and four ways into the rest of Laer.
/// A file picked here takes the New tab's place; a button that leads elsewhere closes it.
struct NewTabPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var showsAllRecent = false

    private static let recentShown = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s24) {
                searchField
                recent
                tiles
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, Space.s24)
            .padding(.vertical, Space.s32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .background(Color.viewerPanel)
    }

    // MARK: - Search

    private var searchField: some View {
        Button {
            navigation.isPaletteOpen = true
        } label: {
            HStack(spacing: Space.s8) {
                Image(systemName: Symbol.search)
                    .font(.system(size: 14))
                Text("Search courses, files and messages")
                    .font(.system(size: 14))
                Spacer(minLength: Space.s8)
                Text("⌘K")
                    .font(Type.t11)
                    .padding(.horizontal, Space.s4)
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Color.borderStrong, lineWidth: 1))
            }
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, Space.s16)
            .frame(height: 44)
            .background(Capsule().fill(Color.raised))
            .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
        .accessibilityIdentifier("newTab.search")
    }

    // MARK: - Recent

    private var shownRecent: [RecentFile] {
        showsAllRecent ? model.recentFiles : Array(model.recentFiles.prefix(Self.recentShown))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Recent")
                    .font(Type.t11.weight(.semibold))
                    .foregroundStyle(Color.textMuted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s8)
                if model.recentFiles.count > Self.recentShown {
                    Button {
                        withAnimation(Motion.base) { showsAllRecent.toggle() }
                    } label: {
                        HStack(spacing: Space.s4) {
                            Text(showsAllRecent ? "Show less" : "Show more")
                            Image(systemName: Symbol.expand)
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(showsAllRecent ? 180 : 0))
                        }
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .padding(.horizontal, Space.s6)
                        .padding(.vertical, Space.s2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("newTab.recentMore")
                }
            }
            .padding(.horizontal, Space.s8)
            if model.recentFiles.isEmpty {
                EmptyLine("Files you open show up here")
                    .padding(.horizontal, Space.s8)
                    .padding(.vertical, Space.s6)
            } else {
                VStack(spacing: Space.s2) {
                    ForEach(shownRecent) { file in
                        RowButton(action: { Task { await model.open(file.resource) } }) {
                            RecentRow(file: file, courseTitle: courseTitle(file.resource.courseId))
                        }
                    }
                }
            }
        }
    }

    private func courseTitle(_ id: Int?) -> String? {
        guard let id else { return nil }
        return model.courses.first { $0.courseId == id }?.title
    }

    // MARK: - Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s8), GridItem(.flexible(), spacing: Space.s8)], spacing: Space.s8) {
            Tile(symbol: Symbol.resources, title: "Resources", detail: "Browse course materials", identifier: "newTab.resources") {
                // The palette opens over the New tab, so the file picked there replaces it.
                navigation.paletteKind = .material
                navigation.isPaletteOpen = true
            }
            if ParityGate.messages {
                Tile(symbol: Symbol.message, title: "Messages", detail: "Your conversations", identifier: "newTab.messages") {
                    go(to: .messages)
                }
            }
            Tile(symbol: Symbol.announcements, title: "Announcements", detail: announcementsDetail, badge: newAnnouncements, identifier: "newTab.announcements") {
                go(to: .home)
            }
            Tile(symbol: Symbol.task, title: "Upcoming", detail: upcomingDetail, identifier: "newTab.upcoming") {
                go(to: .upcoming)
            }
        }
    }

    private func go(to selection: AppModel.Selection) {
        model.selection = selection
        model.closeNewTab()
    }

    private var newAnnouncements: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return model.updates.values.joined().filter { ($0.published ?? .distantPast) > weekAgo }.count
    }

    private var announcementsDetail: String {
        switch newAnnouncements {
        case 0: "From your courses"
        case 1: "1 new this week"
        case let count: "\(count) new this week"
        }
    }

    private var upcomingDetail: String {
        let now = Date()
        guard let next = model.tasks.compactMap(\.deadline).filter({ $0 > now }).min() else { return "Tasks and hand-ins" }
        return "Next: \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}

private struct RecentRow: View {
    let file: RecentFile
    let courseTitle: String?

    private var fileType: String {
        let ext = (file.resource.title as NSString).pathExtension
        return ext.isEmpty || ext.count > 4 ? "FILE" : ext.uppercased()
    }

    var body: some View {
        HStack(spacing: Space.s8) {
            Text(fileType)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 30, height: 20)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.textMuted))
            VStack(alignment: .leading, spacing: 0) {
                Text(file.resource.title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let courseTitle {
                    Text(courseTitle)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.s8)
            Text(file.openedAt, format: .relative(presentation: .named))
                .font(Type.t11)
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct Tile: View {
    let symbol: String
    let title: String
    let detail: String
    var badge = 0
    let identifier: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.text)
                    Spacer(minLength: Space.s8)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, Space.s6)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color.accentFill))
                    }
                }
                Spacer(minLength: Space.s16)
                Text(title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                Text(detail)
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            .padding(Space.s12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(isHovering ? Color.selected : Color.raised))
            .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(isHovering ? Color.borderStrong : Color.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

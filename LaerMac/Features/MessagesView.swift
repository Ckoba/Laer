import LaerCore
import SwiftUI

/// Message threads beside the open conversation.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var loader = CollectionLoader<MessageThread>(key: "message-threads", coverage: .recentWindow) { client in
        let list = try await client.messageThreads()
        return PagedResult(items: list.threads, isComplete: true)
    }
    /// In `Navigation`, so each conversation opened is a history entry.
    private var selectedThread: Int? {
        get { navigation.selectedThread }
        nonmutating set { navigation.selectedThread = newValue }
    }
    @State private var searchThread: MessageThread?
    @State private var composingNew = false

    var body: some View {
        HStack(spacing: 0) {
            threadList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
            Rectangle().fill(Color.border).frame(width: 1)
            Group {
                if composingNew {
                    NewMessageView(onClose: { composingNew = false }) { threadId in
                        composingNew = false
                        await loader.refresh(using: model)
                        selectedThread = threadId
                    }
                } else if let thread = loader.records.first(where: { $0.threadId == selectedThread })
                            ?? searchThread.flatMap({ $0.threadId == selectedThread ? $0 : nil }) {
                    ThreadView(thread: thread, me: myId) { await loader.refresh(using: model) }
                        .id(thread.threadId)
                } else {
                    // Centred in the pane, like Mail with no message selected.
                    Group {
                        if selectedThread != nil { EmptyLine("This conversation is unavailable") }
                        else { EmptyLine(loader.records.isEmpty ? "" : "Choose a conversation") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.stage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Messages")
        .task { await loader.load(using: model) }
        .task(id: navigation.searchTarget?.id) {
            guard case .thread(let id) = navigation.searchTarget?.destination else { return }
            let store = model.snapshots
            let saved = await store?.load(MessageThread.self, collection: "search-recent-threads")?.records
            guard !Task.isCancelled, store === model.snapshots else { return }
            composingNew = false
            searchThread = saved?.first { $0.threadId == id }
        }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await loader.refresh(using: model) })
    }

    private var myId: Int? {
        if case .ready(let person) = model.authState { return person.personId }
        return nil
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same title, leading inset and top inset as every other page. The button sits in the
            // header's own row, so it is centred on the title's line.
            PageHeader(title: "Messages") {
                if ParityGate.writes {
                    IconButton(Symbol.compose, label: "New message") {
                        composingNew = true
                        selectedThread = nil
                    }
                    .help("New message")
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .padding(.top, Size.contentInset)
            .padding(.leading, Space.page)
            // The glyph, not the button's hover square, ends where the rows' times end (12pt in).
            .padding(.trailing, Space.s6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FreshnessLine(state: loader.state)
                        .padding(.horizontal, Space.s8)
                    if loader.records.isEmpty {
                        EmptyState(state: loader.state, empty: "No messages")
                            .padding(.horizontal, Space.s8)
                    }
                    ForEach(loader.records) { thread in
                        RowButton(selected: thread.threadId == selectedThread, action: {
                            composingNew = false
                            selectedThread = thread.threadId
                        }) {
                            ThreadRow(thread: thread, isSelected: thread.threadId == selectedThread, me: myId,
                                      draft: navigation.replyDrafts[thread.threadId])
                        }
                        .overlay(alignment: .bottom) {
                            // A hairline between rows only, from the text's leading edge.
                            if thread.id != loader.records.last?.id {
                                Rectangle().fill(Color.border).frame(height: 1)
                                    .padding(.leading, Space.s8 + ThreadHeader.gutter + ThreadHeader.dotGap + 28 + Space.s6)
                                    .padding(.trailing, Space.s8)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.s4)
            }
        }
        .background(Color.stage)
    }
}

private struct ThreadRow: View {
    let thread: MessageThread
    let isSelected: Bool
    let me: Int?
    /// Unsent reply text, shown in place of the last message, as Mail marks a draft.
    var draft: String?

    var body: some View {
        let who = ThreadText.avatarPerson(thread, me: me)
        HStack(alignment: .center, spacing: ThreadHeader.dotGap) {
            // Unread is a dot and a semibold title; selection is the row's fill. The dot's gutter is
            // kept on every row so avatars and names align, with the avatar under the page title.
            Circle()
                .fill(thread.hasUnread ? Color.accent : Color.clear)
                .frame(width: ThreadHeader.dot, height: ThreadHeader.dot)
                .frame(width: ThreadHeader.gutter)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: Space.s6) {
                Avatar(name: who.name, imageURL: who.imageURL, size: 28)
                textColumn
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(thread.hasUnread ? "Unread" : "")
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s6) {
                Text(ThreadText.title(thread, me: me))
                    .font(Type.t13.weight(thread.hasUnread ? .semibold : .regular))
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                Spacer(minLength: Space.s4)
                if let date = thread.lastMessage?.created {
                    Text(ThreadText.listStamp(date))
                        .font(Type.t12.weight(.regular))
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let draft, !draft.isBlank {
                HStack(spacing: Space.s4) {
                    Text("Draft")
                        .foregroundStyle(Color.danger)
                    Text(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        .foregroundStyle(Color.textMuted)
                }
                .font(Type.t12.weight(.regular))
                .lineLimit(1)
            } else if let preview = ThreadText.preview(thread) {
                Text(preview)
                    .font(Type.t12.weight(.regular))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
        }
    }
}

@MainActor
enum ThreadText {
    /// The thread's name, or its other participants; the signed-in person is left out.
    static func title(_ thread: MessageThread, me: Int? = nil) -> String {
        if let name = thread.name, !name.isEmpty { return name }
        let others = (thread.participants ?? []).filter { me == nil || $0.personId != me }
        let names = (others.isEmpty ? thread.participants ?? [] : others).compactMap(\.fullName).filter { !$0.isEmpty }
        if !names.isEmpty { return names.formatted(.list(type: .and)) }
        return "Conversation"
    }

    /// Whose picture stands for a thread in a list: the other person in a one-to-one thread, the
    /// thread's own name (initials) in a named group, else its first other participant.
    static func avatarPerson(_ thread: MessageThread, me: Int?) -> (name: String, imageURL: String?) {
        let people = thread.participants ?? []
        let others = people.filter { me == nil || $0.personId != me }
        if others.count > 1, let name = thread.name, !name.isEmpty { return (name, nil) }
        if let person = others.first ?? people.first {
            return (person.fullName ?? title(thread, me: me), person.imageURLString)
        }
        return (title(thread, me: me), nil)
    }

    /// The other participants, when the thread has its own name and they add something to it.
    static func participants(_ thread: MessageThread, me: Int?) -> String? {
        guard let name = thread.name, !name.isEmpty else { return nil }
        let others = (thread.participants ?? []).filter { me == nil || $0.personId != me }
        let names = others.compactMap(\.fullName).filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }

    /// What sits under a thread's title: the other people in a named thread, else how many are in a group.
    static func subtitle(_ thread: MessageThread, me: Int?) -> String? {
        if let people = participants(thread, me: me) { return people }
        let count = thread.participants?.count ?? 0
        return count > 2 ? "\(count) participants" : nil
    }

    /// A list stamp: the time today, "Yesterday", the weekday within six days, else a short date.
    static func listStamp(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0: return date.formatted(.dateTime.day().month(.abbreviated))
        case 0: return StudyDates.time(date)
        case 1:
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            f.doesRelativeDateFormatting = true
            return f.string(from: date)
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default:
            return calendar.isDate(date, equalTo: now, toGranularity: .year)
                ? date.formatted(.dateTime.day().month(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    /// A message's time: the clock time today, else the day as `StudyDates.relative` gives it, with
    /// the time kept for older messages too.
    static func messageStamp(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return StudyDates.time(date) }
        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0)
        if days <= 6 { return StudyDates.relative(date, now: now) }
        return calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    static func preview(_ thread: MessageThread) -> String? {
        guard let message = thread.lastMessage else { return nil }
        let text = RichTextCache.preview(message.text ?? "")
        let body = text.isEmpty ? (message.attachmentName ?? "") : text
        guard !body.isEmpty else { return nil }
        // The sender is obvious in a one-to-one thread; name them only in groups.
        let isGroup = (thread.participants?.count ?? 0) > 2
        if isGroup, let author = message.createdByName, !author.isEmpty { return "\(author): \(body)" }
        return body
    }
}

private struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let thread: MessageThread
    let me: Int?
    let onChange: () async -> Void
    @State private var history: [Int64: InstantMessage] = [:]
    @State private var hasMoreHistory = false
    @State private var historyState = CollectionState()
    @State private var visibleMessage: Int64?
    @State private var composerHeight: CGFloat = 0

    private static let historyPageSize = 30
    private static let transcriptEnd = "messages.transcript.end"

    private var embeddedMessages: [InstantMessage] {
        var messages = [thread.lastMessage].compactMap { $0 }
        messages += thread.recentMessages?.items ?? []
        return messages
    }

    private var messages: [InstantMessage] {
        var messages = Dictionary(embeddedMessages.map { ($0.id, $0) }, uniquingKeysWith: { _, full in full })
        // The history request can supply a newer signed attachment URL for an embedded message.
        messages.merge(history) { _, fetched in fetched }
        return messages.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        let messages = messages
        let olderCursor = hasMoreHistory && messages.prefix(4).contains(where: { $0.id == visibleMessage })
            ? messages.first?.id : nil
        VStack(alignment: .leading, spacing: 0) {
            // The same row height and top padding as the list's "Messages" title, so the two titles
            // share a baseline; smaller than the page title so the conversation does not compete.
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(ThreadText.title(thread, me: me))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .frame(minHeight: Size.pageHeader, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = ThreadText.subtitle(thread, me: me) {
                    Text(subtitle)
                        .font(Type.t13)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.top, Size.contentInset)
            .padding(.bottom, Space.s12)
            .padding(.horizontal, Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.border).frame(height: 1)
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if case .failed(let message) = historyState.phase {
                                ErrorLine(message).padding(.bottom, Space.s8)
                            }
                            if messages.isEmpty, loadedHistory {
                                EmptyLine("No messages in this conversation")
                            }
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(MessagePlacement.place(messages, me: me)) { placement in
                                    MessageRow(message: placement.message, threadId: thread.threadId,
                                               placement: placement, isGroup: isGroup,
                                               imageURL: thread.senderImageURLString(for: placement.message), onChange: onChange)
                                        .padding(.top, placement.isFirst ? 0 : (placement.startsGroup ? Space.s12 : Space.s2))
                                        .id(placement.message.messageId)
                                }
                            }
                            .scrollTargetLayout()
                            Color.clear
                                .frame(height: composerHeight + Space.s16)
                                .accessibilityHidden(true)
                                .id(Self.transcriptEnd)
                        }
                        .frame(maxWidth: Size.readingColumn, alignment: .leading)
                        .padding(.horizontal, Space.page)
                        .padding(.top, Space.s16)
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                    }
                    .scrollPosition(id: $visibleMessage, anchor: .top)
                    .defaultScrollAnchor(.bottom)
                    .accessibilityIdentifier("messages.transcript")
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if historyState.phase == .loading { Spinner().padding(.top, Space.s4) }
                }
                .overlay(alignment: .bottom) {
                    if ParityGate.writes {
                        ReplyComposer(threadId: thread.threadId, onSent: onChange)
                            .frame(maxWidth: Size.readingColumn, alignment: .leading)
                            .padding(.horizontal, Space.page)
                            .padding(.bottom, Space.s12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                composerHeight = $0
                            }
                    }
                }
                .onChange(of: messages.last?.id, initial: true) { _, newest in
                    if newest != nil { proxy.scrollTo(Self.transcriptEnd, anchor: .bottom) }
                }
            }
        }
        .background(Color.stage)
        .onChange(of: thread) {
            for message in embeddedMessages where history[message.id] != nil {
                history[message.id] = message
            }
        }
        .task { await loadHistory(before: nil) }
        .task(id: olderCursor) {
            if let olderCursor {
                await loadHistory(before: olderCursor)
            } else if loadedHistory, historyState.phase == .loading {
                historyState.phase = .idle
            }
        }
    }

    private var loadedHistory: Bool { historyState.lastSuccess != nil }

    /// More than two people: received messages carry their sender's name and picture.
    private var isGroup: Bool { (thread.participants?.count ?? 0) > 2 }

    private func loadHistory(before cursor: Int64?) async {
        guard !Task.isCancelled else { return }
        historyState.phase = .loading
        do {
            let threadId = thread.threadId
            let pageSize = Self.historyPageSize
            let key = "messages-\(threadId)-\(cursor.map(String.init) ?? "latest")"
            let list = try await model.fetch(key: key) {
                try await $0.messages(threadId: threadId, before: cursor, pageSize: pageSize)
            }
            try Task.checkCancellation()
            let page = list.messages.filter { message in
                cursor.map { message.id < $0 } ?? true
            }
            for message in page {
                history[message.id] = message
            }
            hasMoreHistory = list.hasMore && (cursor == nil || !page.isEmpty)
            historyState = CollectionState(phase: .idle, lastSuccess: Date())
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            historyState.phase = .failed(model.message(for: error))
        }
    }
}

/// Where a message sits in its thread: whose side, and whether it opens a run of messages from
/// the same sender. A run breaks when the sender changes or after a quiet gap.
struct MessagePlacement: Identifiable {
    let message: InstantMessage
    /// Sent by the signed-in person. A sender the app cannot identify counts as received.
    let isMine: Bool
    let startsGroup: Bool
    let isFirst: Bool

    var id: Int64 { message.messageId }

    static let groupGap: TimeInterval = 15 * 60

    static func place(_ messages: [InstantMessage], me: Int?) -> [MessagePlacement] {
        var result: [MessagePlacement] = []
        var previous: InstantMessage?
        for message in messages {
            let isMine = me != nil && message.createdBy == me
            var starts = true
            if let previous, previous.isSystemMessage != true, message.isSystemMessage != true,
               sender(previous) == sender(message) {
                if let a = previous.created, let b = message.created {
                    starts = b.timeIntervalSince(a) > groupGap
                } else {
                    starts = false
                }
            }
            result.append(MessagePlacement(message: message, isMine: isMine, startsGroup: starts, isFirst: previous == nil))
            previous = message
        }
        return result
    }

    private static func sender(_ message: InstantMessage) -> String {
        if let id = message.createdBy { return "id:\(id)" }
        return "name:\(message.createdByName ?? "")"
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: InstantMessage
    let threadId: Int
    let placement: MessagePlacement
    let isGroup: Bool
    /// The sender's picture, resolved from the thread's participants.
    let imageURL: String?
    let onChange: () async -> Void
    @State private var confirmingDelete = false
    @State private var action = WriteAction()
    @State private var starred: Bool?
    @State private var isHovering = false

    private static let avatar: CGFloat = 28
    /// A bubble never takes the whole column, so the two sides stay apart.
    private static let bubbleWidth: CGFloat = 520

    private var isMine: Bool { placement.isMine }
    private var isDeleted: Bool { message.isDeleted == true }
    private var isStarred: Bool { starred ?? message.isStarred ?? false }
    private var showsToolbar: Bool { isHovering && ParityGate.writes && !isDeleted }
    /// Received messages in a group carry the sender's picture beside the run.
    private var showsAvatarColumn: Bool { isGroup && !isMine }
    private var tone: RichTextTone { isMine && !isDeleted ? .onAccent : .page }
    private var ink: Color { tone == .onAccent ? Color(nsColor: RichTextLayout.Colors(.onAccent).text) : Color.text }
    private var inkMuted: Color { tone == .onAccent ? Color(nsColor: RichTextLayout.Colors(.onAccent).muted) : Color.textMuted }

    private var senderName: String { isMine ? String(localized: "You") : (message.createdByName ?? String(localized: "Unknown sender")) }

    /// What VoiceOver reads for the message: who, when, then the text, so meaning never rests on side or colour.
    private var spokenLabel: String {
        var parts = [senderName]
        if let date = message.created { parts.append(ThreadText.messageStamp(date)) }
        let head = parts.joined(separator: ", ")
        var body = isDeleted ? String(localized: "Deleted") : RichTextCache.preview(message.text ?? "")
        if body.isEmpty, let name = message.attachmentName { body = name }
        var label = body.isEmpty ? head : "\(head): \(body)"
        if isStarred { label += ". " + String(localized: "Starred") }
        return label
    }

    var body: some View {
        if message.isSystemMessage == true {
            systemLine
        } else {
            VStack(alignment: isMine ? .trailing : .leading, spacing: Space.s4) {
                if placement.startsGroup { header }
                HStack(alignment: .bottom, spacing: Space.s6) {
                    if showsAvatarColumn {
                        // The picture sits once per run, beside its first message.
                        if placement.startsGroup {
                            Avatar(name: message.createdByName, imageURL: imageURL, size: Self.avatar)
                                .accessibilityHidden(true)
                        } else {
                            Color.clear.frame(width: Self.avatar, height: 1)
                        }
                    }
                    if isMine {
                        Spacer(minLength: Space.s32)
                        toolbar
                        starMark
                    }
                    bubble
                    if !isMine {
                        starMark
                        toolbar
                        Spacer(minLength: Space.s32)
                    }
                }
                if confirmingDelete {
                    HStack(spacing: Space.s8) {
                        Text("Delete this message for everyone in the conversation?")
                            .font(Type.t12)
                            .foregroundStyle(Color.text)
                        ConfirmInPlace(confirmTitle: "Delete", onConfirm: { Task { await delete() } }, onCancel: {
                            withMotion(Motion.fast, reduceMotion: reduceMotion) { confirmingDelete = false }
                        })
                    }
                }
                if case .failed(let text) = action.phase { ErrorLine(text) }
            }
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .contextMenu {
                if ParityGate.writes, !isDeleted { actions }
            }
        }
    }

    /// The sender (received messages in a group only) and the time, quiet above a run.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s6) {
            if isGroup, !isMine {
                Text(senderName)
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            if let date = message.created {
                Text(ThreadText.messageStamp(date))
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(date.formatted(date: .complete, time: .shortened))
            }
        }
        .padding(.leading, showsAvatarColumn ? Self.avatar + Space.s6 + Space.s4 : Space.s4)
        .padding(.trailing, isMine ? Space.s4 : 0)
        // VoiceOver hears both in the message's own label.
        .accessibilityHidden(true)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            if isDeleted {
                Text("Deleted")
                    .font(Type.body.italic())
                    .foregroundStyle(Color.textMuted)
                    .accessibilityLabel(spokenLabel)
            } else if let text = message.text, !text.isBlank {
                RichTextView(html: text, tone: tone, hugsWidth: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel)
            }
            if !isDeleted { attachment }
            if let link = message.link, let url = model.absoluteURL(link) {
                Link(message.linkTitle.flatMap { $0.isEmpty ? nil : $0 } ?? link, destination: url)
                    .font(Type.t12)
                    .foregroundStyle(ink)
                    .underline()
                    .environment(\.openURL, OpenURLAction { url in
                        navigation.openSiteLink(url) ? .handled : .systemAction
                    })
            }
        }
        .padding(.horizontal, Space.s12)
        .padding(.vertical, Space.s8)
        .background {
            let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
            if isDeleted {
                shape.strokeBorder(Color.border, lineWidth: 1)
            } else {
                shape.fill(isMine ? Color.accentFill : Color.raised)
            }
        }
        .frame(maxWidth: Self.bubbleWidth, alignment: isMine ? .trailing : .leading)
    }

    @ViewBuilder private var attachment: some View {
        let url = model.absoluteURL(message.attachmentUrl)
        let name = message.attachmentName.flatMap { $0.isBlank ? nil : $0 }
        if name != nil || url != nil {
            let title = name ?? String(localized: "Attachment")
            let state = model.downloadStates[AppModel.messageAttachmentKey(message.messageId)]
            let canOpen = if let url, let origin = model.site?.baseURL {
                FileAcquirer.canAcquireAttachment(at: url, origin: origin)
            } else { false }
            let failed = if case .failed = state { true } else { state == .websiteOnly }
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(spacing: Space.s6) {
                    if canOpen {
                        Button {
                            Task { await model.openMessageAttachment(message, threadId: threadId) }
                        } label: {
                            attachmentLabel(title)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(state == .downloading)
                        .help("Open in Laer")
                    } else {
                        attachmentLabel(title)
                    }
                    if state == .downloading { Spinner() }
                    if let url, !canOpen || failed {
                        IconButton(Symbol.open, label: "Open on the website") { NSWorkspace.shared.open(url) }
                            .foregroundStyle(inkMuted)
                    }
                }
                if failed {
                    Text("The attachment couldn’t be opened in Laer.")
                        .font(Type.t12)
                        .foregroundStyle(inkMuted)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel((message.text ?? "").isBlank ? spokenLabel : title)
        }
    }

    private func attachmentLabel(_ title: String) -> some View {
        HStack(spacing: Space.s6) {
            Image(systemName: Symbol.file(extension: (title as NSString).pathExtension))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(inkMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(Type.t12)
                .foregroundStyle(ink)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var starMark: some View {
        if isStarred {
            Image(systemName: Symbol.star + ".fill")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .padding(.bottom, Space.s8)
                .accessibilityHidden(true)
        }
    }

    /// Star and the rest of the actions, beside the bubble on its inner side. It stays in the
    /// accessibility tree and keeps its hit area at rest, so VoiceOver and a click that arrives with
    /// the pointer reach it; it only fades in visually on hover.
    @ViewBuilder private var toolbar: some View {
        if ParityGate.writes, !isDeleted {
            HStack(spacing: 0) {
                IconButton(Symbol.star, label: isStarred ? "Unstar" : "Star") { Task { await toggleStar() } }
                Menu("Message actions", systemImage: Symbol.more) {
                    actions
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .regular))
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Color.textMuted)
                .fixedSize()
                .frame(minWidth: Size.controlSmall, minHeight: Size.controlSmall)
                .help("Message actions")
                .accessibilityLabel("Message actions")
            }
            .background(Color.stage, in: RoundedRectangle(cornerRadius: Radius.s))
            .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Color.border, lineWidth: 1))
            .opacity(showsToolbar ? 1 : 0)
            .animation(Motion.fast, value: showsToolbar)
        }
    }

    /// A notice from itslearning itself (someone joined, the thread was renamed): centred, no bubble.
    private var systemLine: some View {
        Text(RichTextCache.preview(message.text ?? ""))
            .font(Type.t12)
            .foregroundStyle(Color.textMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Space.s4)
    }

    /// The same actions in the row's menu and its context menu.
    @ViewBuilder private var actions: some View {
        Button(isStarred ? "Unstar" : "Star") { Task { await toggleStar() } }
        if message.canDelete != false {
            Divider()
            Button("Delete…", role: .destructive) {
                withMotion(Motion.fast, reduceMotion: reduceMotion) { confirmingDelete = true }
            }
        }
    }

    private func toggleStar() async {
        let id = message.messageId
        var result: Bool?
        if await action.run({ result = try await model.write { try await $0.toggleMessageStar(messageId: id) }.isStarred }) {
            starred = result ?? !isStarred
        }
    }

    private func delete() async {
        let id = message.messageId
        if await action.run({ _ = try await model.write { try await $0.deleteMessage(messageId: id) } }) {
            await onChange()
        }
        confirmingDelete = false
    }
}

private enum ThreadHeader {
    /// The 6pt unread dot sits in a fixed gutter; with its gap the gutter is 12, so a row's avatar
    /// (4 + 8 + 12) starts at the page inset.
    static let dot: CGFloat = 6
    static let gutter: CGFloat = 8
    static let dotGap: CGFloat = Space.s4
}

/// The reply field: one line tall, growing to about six; attach and Send share its row.
private struct ReplyComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    let threadId: Int
    let onSent: () async -> Void
    /// Lives in `Navigation`, keyed by thread, because the view is rebuilt for each conversation.
    private var text: String {
        get { navigation.replyDrafts[threadId] ?? "" }
        nonmutating set { navigation.replyDrafts[threadId] = newValue.isEmpty ? nil : newValue }
    }
    private var textBinding: Binding<String> { Binding(get: { text }, set: { text = $0 }) }
    @State private var files: [PickedFile] = []
    @State private var action = WriteAction()
    @State private var pickError: String?

    private var canSend: Bool { !action.isRunning && (!text.isBlank || !files.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            AttachmentList(files: $files).disabled(action.isRunning)
            MessageComposerBar(label: "Reply", text: textBinding, canSend: canSend, isSending: action.isRunning,
                               onAttach: attach, onSend: { Task { await send() } })
            if case .failed(let message) = action.phase { ErrorLine(message) }
            if let pickError { ErrorLine(pickError) }
        }
        .padding(.top, Space.s12)
    }

    private func attach() {
        pickError = nil
        do {
            files += try PickedFile.pick()
        } catch {
            pickError = WriteText.failure(error)
        }
    }

    private func send() async {
        let body = text
        let parts = files.map(\.part)
        let threadId = threadId
        let sent = await action.run {
            _ = try await model.write { writer in
                var ids: [String] = []
                for part in parts {
                    ids += try await writer.uploadMessageAttachment(part).map(\.fileId)
                }
                return try await writer.sendMessage(text: body, threadId: threadId, attachmentIds: ids)
            }
        }
        if sent {
            text = ""
            files = []
            await onSent()
        }
    }
}

import LaerCore
import SwiftUI

/// Message threads beside the open conversation.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @State private var loader = CollectionLoader<MessageThread>(key: "message-threads", coverage: .recentWindow) { client in
        let list = try await client.messageThreads()
        return PagedResult(items: list.threads, isComplete: true)
    }
    @State private var selectedThread: Int?
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
                } else if let thread = loader.records.first(where: { $0.threadId == selectedThread }) {
                    ThreadView(thread: thread, me: myId) { await loader.refresh(using: model) }
                        .id(thread.threadId)
                } else {
                    PageScroll { EmptyLine(loader.records.isEmpty ? "" : "Choose a conversation") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Messages")
        .task { await loader.load(using: model) }
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
            .padding(.trailing, Space.s12)
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
                            ThreadRow(thread: thread, isSelected: thread.threadId == selectedThread, me: myId)
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

    var body: some View {
        let who = ThreadText.avatarPerson(thread, me: me)
        HStack(alignment: .center, spacing: ThreadHeader.dotGap) {
            // Unread is a dot and a semibold title; selection is the row's fill. The dot's gutter is
            // kept on every row so avatars and names align, with the avatar under the page title.
            Circle()
                .fill(thread.hasUnread ? Color.accent : Color.clear)
                .frame(width: ThreadHeader.dot, height: ThreadHeader.dot)
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
                        .font(Type.t11)
                        .foregroundStyle(thread.hasUnread ? Color.text : Color.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let preview = ThreadText.preview(thread) {
                Text(preview)
                    .font(Type.t12)
                    .foregroundStyle(thread.hasUnread ? Color.text : Color.textMuted)
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

    static func preview(_ thread: MessageThread) -> String? {
        guard let message = thread.lastMessage else { return nil }
        let text = RichTextCache.plainText(message.text ?? "")
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
    @State private var older: [InstantMessage] = []
    @State private var olderState = CollectionState()
    /// The next older page, fetched ahead so "Show older" appears only when there is one.
    @State private var pending: [InstantMessage] = []
    @State private var pendingHasMore = false

    private var messages: [InstantMessage] {
        var seen = Set<Int64>()
        let all = (thread.recentMessages?.items ?? []) + older + [thread.lastMessage].compactMap { $0 }
        return all.filter { seen.insert($0.messageId).inserted }.sorted { $0.messageId < $1.messageId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same row height and top padding as the list's "Messages" title, so the two titles
            // share a baseline; smaller than the page title so the conversation does not compete.
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(ThreadText.title(thread, me: me))
                    .font(Type.title.weight(.semibold))
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
            .padding(.bottom, Space.s16)
            .padding(.horizontal, Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if ParityGate.olderMessages, !pending.isEmpty || isFailed {
                            HStack(spacing: Space.s8) {
                                if !pending.isEmpty {
                                    OlderMessagesButton(isLoading: olderState.phase == .loading) { Task { await showOlder() } }
                                }
                                if olderState.phase == .loading { Spinner() }
                                if case .failed(let message) = olderState.phase { ErrorLine(message) }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, Space.s12)
                        }
                        if messages.isEmpty {
                            EmptyLine("No messages in this conversation")
                        }
                        LazyVStack(alignment: .leading, spacing: Space.s8) {
                            ForEach(messages) { message in
                                MessageRow(message: message, imageURL: thread.senderImageURLString(for: message), onChange: onChange)
                                    .id(message.messageId)
                            }
                        }
                    }
                    .frame(maxWidth: Size.readingColumn, alignment: .leading)
                    .padding(.horizontal, Space.page)
                    .padding(.bottom, Space.s16)
                    // A short thread starts at the top, under the header; the composer stays docked below.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
                .onAppear { scrollToNewest(proxy) }
                .onChange(of: messages.last?.messageId) { _, _ in scrollToNewest(proxy) }
            }
            if ParityGate.writes {
                Rectangle().fill(Color.border).frame(height: 1)
                ReplyComposer(threadId: thread.threadId, onSent: onChange)
                    .frame(maxWidth: Size.readingColumn, alignment: .leading)
                    .padding(.horizontal, Space.page)
                    .padding(.bottom, Space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.stage)
        .task { if ParityGate.olderMessages { await prefetch() } }
    }

    private var isFailed: Bool {
        if case .failed = olderState.phase { return true }
        return false
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let last = messages.last?.messageId else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    /// Reveals the fetched page and fetches the one before it.
    private func showOlder() async {
        older += pending
        pending = []
        if pendingHasMore { await prefetch() }
    }

    private func prefetch() async {
        guard let oldest = messages.first?.messageId else { return }
        olderState.phase = .loading
        do {
            let threadId = thread.threadId
            let list = try await model.fetch(key: "messages-\(threadId)-\(oldest)") { try await $0.messages(threadId: threadId, before: oldest) }
            let known = Set(messages.map(\.messageId))
            pending = list.messages.filter { !known.contains($0.messageId) }
            pendingHasMore = list.hasMore && !pending.isEmpty
            olderState = CollectionState(phase: .idle, lastSuccess: Date())
        } catch {
            olderState.phase = .failed(model.message(for: error))
        }
    }
}

/// A borderless button above the transcript that reveals the page of earlier messages.
private struct OlderMessagesButton: View {
    let isLoading: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s6) {
                Image(systemName: Symbol.lecture)
                    .font(.system(size: 12, weight: .regular))
                    .accessibilityHidden(true)
                Text("Load older messages").font(Type.t12)
            }
            .foregroundStyle(isHovering ? Color.text : Color.textMuted)
            .padding(.horizontal, Space.s8)
            .frame(height: Size.controlSmall)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(isHovering ? Color.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .disabled(isLoading)
        .help("Load older messages")
        .accessibilityLabel("Older messages")
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: InstantMessage
    /// The sender's picture, resolved from the thread's participants.
    let imageURL: String?
    let onChange: () async -> Void
    @State private var confirmingDelete = false
    @State private var action = WriteAction()
    @State private var starred: Bool?
    @State private var isHovering = false

    private var isStarred: Bool { starred ?? message.isStarred ?? false }
    private var showsToolbar: Bool { isHovering && ParityGate.writes && message.isDeleted != true }

    /// Star and the rest of the actions, over the message's top corner. It stays in the accessibility
    /// tree and keeps its hit area at rest, so VoiceOver and a click that arrives with the pointer
    /// reach it; it only fades in visually on hover.
    @ViewBuilder private var toolbar: some View {
        if ParityGate.writes, message.isDeleted != true {
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

    /// The sender line, the message and its attachments, beside the sender's picture.
    private var column: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s6) {
                Text(message.createdByName ?? "Unknown sender")
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let date = message.created {
                    Text(StudyDates.relative(date))
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .help(date.formatted(date: .complete, time: .shortened))
                }
                Spacer(minLength: Space.s8)
                // The toolbar takes this spot while the pointer is over the message.
                if isStarred {
                    Text("Starred").font(Type.t11).foregroundStyle(Color.textMuted)
                        .opacity(showsToolbar ? 0 : 1)
                }
            }
            .frame(minHeight: 32)
            .overlay(alignment: .trailing) { toolbar }
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
            if message.isDeleted == true {
                EmptyLine("Deleted")
            } else if let text = message.text, !text.isEmpty {
                RichTextView(html: text)
            }
            if let name = message.attachmentName, !name.isEmpty {
                HStack(spacing: Space.s6) {
                    Image(systemName: Symbol.material)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.textMuted)
                        .accessibilityHidden(true)
                    Text(name)
                        .font(Type.t12)
                        .foregroundStyle(Color.text)
                        .lineLimit(1)
                    if let url = model.absoluteURL(message.attachmentUrl) {
                        IconButton(Symbol.open, label: "Open on the website") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if let link = message.link, let url = model.absoluteURL(link) {
                Link(message.linkTitle.flatMap { $0.isEmpty ? nil : $0 } ?? link, destination: url)
                    .font(Type.t12)
                    .foregroundStyle(Color.text)
                    .underline()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s12) {
            Avatar(name: message.createdByName, imageURL: imageURL, size: 32)
            column
        }
        .padding(Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.raised))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if ParityGate.writes, message.isDeleted != true { actions }
        }
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
    /// With the dot's gap this is 12, so a row's avatar (4 + 8 + 12) starts at the page inset.
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = Space.s4
}

/// The reply field: one line tall, growing to about six; attach and Send share its row.
private struct ReplyComposer: View {
    @Environment(AppModel.self) private var model
    let threadId: Int
    let onSent: () async -> Void
    @State private var text = ""
    @State private var files: [PickedFile] = []
    @State private var action = WriteAction()
    @State private var pickError: String?
    @FocusState private var focused: Bool

    private var canSend: Bool { !action.isRunning && (!text.isBlank || !files.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            AttachmentList(files: $files)
            HStack(alignment: .bottom, spacing: Space.s8) {
                IconButton(Symbol.attach, label: "Attach files") { attach() }
                TextField("Reply", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Type.body)
                    .foregroundStyle(Color.text)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, Space.s8)
                    .padding(.vertical, Space.s4)
                    .frame(maxWidth: .infinity, minHeight: Size.control, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.stage))
                    .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.borderStrong, lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                    .accessibilityLabel("Reply")
                if action.isRunning { Spinner() }
                TextButton("Send", role: .primary) { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
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

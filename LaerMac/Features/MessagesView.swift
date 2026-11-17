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
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
            Rectangle().fill(Color.border).frame(width: 1)
            Group {
                if composingNew {
                    NewMessageView(onClose: { composingNew = false }) { threadId in
                        composingNew = false
                        await loader.refresh(using: model)
                        selectedThread = threadId
                    }
                } else if let thread = loader.records.first(where: { $0.threadId == selectedThread }) {
                    ThreadView(thread: thread) { await loader.refresh(using: model) }
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

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Messages") {
                if ParityGate.writes {
                    IconButton(Symbol.compose, label: "New message") {
                        composingNew = true
                        selectedThread = nil
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
                .padding(.horizontal, Space.s16)
                .padding(.top, Space.s16)
                .padding(.bottom, Space.s8)
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
                            ThreadRow(thread: thread, isSelected: thread.threadId == selectedThread)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                Text(ThreadText.title(thread))
                    .font(thread.hasUnread ? Type.t13.weight(.semibold) : Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                Spacer(minLength: Space.s4)
                if let date = thread.lastMessage?.created {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
            if let preview = ThreadText.preview(thread) {
                Text(preview)
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(thread.hasUnread ? "Unread" : "")
    }
}

@MainActor
enum ThreadText {
    static func title(_ thread: MessageThread) -> String {
        if let name = thread.name, !name.isEmpty { return name }
        let names = (thread.participants ?? []).compactMap(\.fullName).filter { !$0.isEmpty }
        if !names.isEmpty { return names.formatted(.list(type: .and)) }
        return "Conversation"
    }

    static func preview(_ thread: MessageThread) -> String? {
        guard let message = thread.lastMessage else { return nil }
        let text = RichTextCache.plainText(message.text ?? "")
        let body = text.isEmpty ? (message.attachmentName ?? "") : text
        guard !body.isEmpty else { return nil }
        if let author = message.createdByName, !author.isEmpty { return "\(author): \(body)" }
        return body
    }
}

private struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let thread: MessageThread
    let onChange: () async -> Void
    @State private var older: [InstantMessage] = []
    @State private var olderState = CollectionState()
    @State private var hasMore = true

    private var messages: [InstantMessage] {
        var seen = Set<Int64>()
        let all = (thread.recentMessages?.items ?? []) + older + [thread.lastMessage].compactMap { $0 }
        return all.filter { seen.insert($0.messageId).inserted }.sorted { $0.messageId < $1.messageId }
    }

    var body: some View {
        PageScroll {
            PageHeader(title: ThreadText.title(thread))
                .padding(.bottom, Space.s8)
            if ParityGate.olderMessages, hasMore {
                HStack(spacing: Space.s8) {
                    TextButton("Show older") { Task { await loadOlder() } }
                        .disabled(olderState.phase == .loading)
                    if olderState.phase == .loading { Spinner() }
                    if case .failed(let message) = olderState.phase { ErrorLine(message) }
                }
            }
            if messages.isEmpty {
                EmptyLine("No messages in this conversation")
            }
            ForEach(messages) { message in
                MessageRow(message: message, onChange: onChange)
            }
            if ParityGate.writes {
                MessageComposer(threadId: thread.threadId, onSent: onChange)
            }
        }
    }

    private func loadOlder() async {
        guard let oldest = messages.first?.messageId else { return }
        olderState.phase = .loading
        do {
            let threadId = thread.threadId
            let list = try await model.fetch(key: "messages-\(threadId)-\(oldest)") { try await $0.messages(threadId: threadId, before: oldest) }
            older += list.messages
            hasMore = list.hasMore
            olderState = CollectionState(phase: .idle, lastSuccess: Date())
        } catch {
            olderState.phase = .failed(model.message(for: error))
        }
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: InstantMessage
    let onChange: () async -> Void
    @State private var confirmingDelete = false
    @State private var action = WriteAction()
    @State private var starred: Bool?

    private var isStarred: Bool { starred ?? message.isStarred ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                Text(message.createdByName ?? "Unknown sender")
                    .font(Type.t13.weight(.semibold))
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Space.s8)
                if isStarred {
                    Text("Starred").font(Type.t11).foregroundStyle(Color.textMuted)
                }
                if ParityGate.writes, message.isDeleted != true {
                    Menu {
                        actions
                    } label: {
                        Image(systemName: Symbol.more)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.textMuted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(minWidth: Size.controlSmall, minHeight: Size.controlSmall)
                    .help("Message actions")
                    .accessibilityLabel("Message actions")
                }
                if let date = message.created {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .help(date.formatted(date: .complete, time: .shortened))
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
        .padding(.vertical, Space.s12)
        .overlay(alignment: .bottom) { ItemDivider() }
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

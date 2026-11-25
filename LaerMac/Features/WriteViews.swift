import AppKit
import LaerCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The state of one write the user started. A running write cannot be started again,
/// and a failed one is never retried by itself.
@MainActor
@Observable
final class WriteAction {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isRunning: Bool { phase == .running }

    /// Runs `work` once. Returns true on success.
    @discardableResult
    func run(_ work: () async throws -> Void) async -> Bool {
        guard phase != .running else { return false }
        phase = .running
        do {
            try await work()
            phase = .idle
            return true
        } catch {
            phase = .failed(WriteText.failure(error))
            return false
        }
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }
}

enum WriteText {
    /// What happened, in words. A server error says the result is unknown rather than guessing.
    static func failure(_ error: Error) -> String {
        switch error {
        case WriteError.unavailable: "This sign-in can't make changes."
        case WriteError.missingTarget: "Choose who to send to."
        case WriteError.uploadRejected: "The file was refused."
        case WriteError.notStudentCompletable: "This task can't be marked by students. Nothing changed."
        case WriteError.refused: "itslearning refused this. Nothing changed."
        case APIError.signedOut: "Your session has ended. Sign in, then try again."
        case APIError.offline, is URLError: "You appear to be offline. Nothing was sent."
        case APIError.forbidden: "You don't have permission to do this."
        case APIError.notFound: "This is no longer available."
        case APIError.throttled: "The service asked Laer to slow down. Try again later."
        case APIError.server: "The service had a problem. Check whether it went through before trying again."
        default: "That didn't go through. Check before trying again."
        }
    }
}

// MARK: - Files

private enum LocalFileError: Error {
    case unreadable
    case fileTooLarge
    case totalTooLarge

    var message: String {
        switch self {
        case .unreadable: String(localized: "An attachment couldn’t be read or its size couldn’t be verified.")
        case .fileTooLarge: String(localized: "Each attachment must be 50 MiB or smaller.")
        case .totalTooLarge: String(localized: "Attachments must total 100 MiB or less.")
        }
    }
}

/// A file the user picked, read into memory for one upload.
struct PickedFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let contentType: String
    let data: Data

    var part: UploadPart { UploadPart(fileName: name, contentType: contentType, data: data) }
}

@MainActor
@Observable
final class AttachmentDraft {
    private(set) var files: [PickedFile] = []
    private(set) var error: String?
    private(set) var isLoading = false

    func pick() async {
        guard !isLoading else { return }
        error = nil
        isLoading = true
        defer { isLoading = false }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !Task.isCancelled else { return }

        let urls = panel.urls
        let existingBytes = files.reduce(0) { $0 + $1.data.count }
        let read = Task.detached(priority: .userInitiated) { try Self.read(urls, existingBytes: existingBytes) }
        do {
            let picked = try await withTaskCancellationHandler {
                try await read.value
            } onCancel: {
                read.cancel()
            }
            try Task.checkCancellation()
            files += picked
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? LocalFileError ?? .unreadable).message
        }
    }

    func remove(_ id: UUID) {
        files.removeAll { $0.id == id }
    }

    func clear() {
        files = []
        error = nil
    }

    nonisolated private static func read(_ urls: [URL], existingBytes: Int) throws -> [PickedFile] {
        let perFileLimit = 50 * 1024 * 1024
        let totalLimit = 100 * 1024 * 1024
        var remaining = totalLimit - existingBytes
        return try urls.map { url in
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw LocalFileError.unreadable
            }
            guard size <= perFileLimit else { throw LocalFileError.fileTooLarge }
            guard size <= remaining else { throw LocalFileError.totalTooLarge }

            // Bound the actual read as well, in case the file grows after the metadata check.
            let limit = min(perFileLimit, remaining)
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data = Data()
            data.reserveCapacity(size)
            while data.count <= limit {
                try Task.checkCancellation()
                let count = min(1024 * 1024, limit + 1 - data.count)
                guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= perFileLimit else { throw LocalFileError.fileTooLarge }
            guard data.count <= remaining else { throw LocalFileError.totalTooLarge }
            remaining -= data.count
            let type = values.contentType?.preferredMIMEType ?? "application/octet-stream"
            return PickedFile(name: url.lastPathComponent, contentType: type, data: data)
        }
    }
}

/// Picked files, each removable before sending, and feedback for the selection in progress.
struct AttachmentList: View {
    let draft: AttachmentDraft

    var body: some View {
        ForEach(draft.files) { file in
            HStack(spacing: Space.s6) {
                Image(systemName: Symbol.material)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.textMuted)
                    .accessibilityHidden(true)
                Text(file.name)
                    .font(Type.t12)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                Text(Int64(file.data.count).formatted(.byteCount(style: .file)))
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                IconButton(Symbol.close, label: "Remove \(file.name)") { draft.remove(file.id) }
                    .disabled(draft.isLoading)
            }
        }
        if draft.isLoading {
            HStack(spacing: Space.s6) {
                Spinner()
                Text("Reading attachments…").font(Type.t11).foregroundStyle(Color.textMuted)
            }
        }
        if let error = draft.error { ErrorLine(error) }
    }
}

// MARK: - Text input

/// A multi-line field on the design's tokens.
struct TextArea: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat = 56
    @FocusState private var isFocused: Bool

    /// Lines shown before the field grows, from the requested height.
    private var minLines: Int { max(2, Int((minHeight - 2 * Space.s6) / 17)) }

    var body: some View {
        TextField(label, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Type.body)
            .foregroundStyle(Color.text)
            .lineLimit(minLines...12)
            .focused($isFocused)
            .padding(.horizontal, Space.s8)
            .padding(.vertical, Space.s6)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .fieldChrome(focused: isFocused)
            // The padding around the text belongs to the field too.
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .accessibilityLabel(label)
    }
}

// MARK: - Confirm in place

/// Replaces a destructive control with Confirm and Cancel, sliding in from the leading edge.
struct ConfirmInPlace: View {
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Space.s8) {
            TextButton(confirmTitle, role: .danger, action: onConfirm)
            TextButton("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}

// MARK: - Message composer

/// The same composer controls for replies and new conversations.
struct MessageComposerBar: View {
    let label: String
    @Binding var text: String
    let canSend: Bool
    let isSending: Bool
    var isReadingAttachments = false
    let onAttach: () -> Void
    let onSend: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool

    var body: some View {
        let height = Size.control + Space.s4
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        let outlineOpacity = (focused ? 0.20 : 0.08) + (contrast == .increased ? 0.28 : 0)
        HStack(alignment: .bottom, spacing: Space.s8) {
            Button(action: onAttach) {
                Label("Attach files", systemImage: Symbol.add).labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("Attach files")
            .accessibilityLabel("Attach files")
            .disabled(isSending || isReadingAttachments)

            TextField(label, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Type.body)
                .foregroundStyle(Color.text)
                .lineLimit(1...6)
                .focused($focused)
                .focusEffectDisabled()
                .padding(.horizontal, Space.s12)
                .padding(.vertical, Space.s6)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background {
                    if reduceTransparency {
                        shape.fill(Color.raised)
                    } else {
                        shape.fill(Color.text.opacity(0.04))
                            .background(.thinMaterial, in: shape)
                    }
                }
                .overlay {
                    shape.strokeBorder(Color.text.opacity(outlineOpacity), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .onTapGesture { focused = true }
                .accessibilityLabel(label)
                .disabled(isSending)

            Button(action: onSend) {
                if isSending {
                    Spinner().accessibilityHidden(true)
                } else {
                    Label("Send", systemImage: Symbol.send).labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentFill)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send")
            .accessibilityLabel("Send")
            .accessibilityValue(isSending ? "Sending" : "")
            .disabled(!canSend)
        }
        .controlSize(.large)
        .buttonBorderShape(.circle)
    }
}

// MARK: - New conversation

/// Starts a conversation with one or more people. Recipients come from the site's search,
/// which returns at most 100 matches, so it runs as the user types.
struct NewMessageView: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    let onSent: (Int) async -> Void
    @State private var query = ""
    @State private var results: [Recipient] = []
    @State private var searchState = CollectionState()
    @State private var recipients: [Recipient] = []
    @State private var text = ""
    @State private var attachments = AttachmentDraft()
    @State private var action = WriteAction()
    @FocusState private var toFocused: Bool

    private var canSend: Bool {
        !action.isRunning && !attachments.isLoading && !recipients.isEmpty
            && (!text.isBlank || !attachments.files.isEmpty)
    }

    /// One centred column, at most `readingMax` wide, with equal space left and right.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: Size.readingMax, alignment: .leading)
            .padding(.horizontal, Size.contentInset)
            .frame(maxWidth: .infinity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            column {
                PageHeader(title: "New message") {
                    IconButton(Symbol.close, label: "Close", action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, Size.contentInset)
                .padding(.bottom, Space.s12)
            }
            ScrollView {
                column {
                    recipientsField
                        .fieldChrome(focused: toFocused)
                        .disabled(action.isRunning)
                        .padding(.bottom, Space.s12)
                }
            }
            Rectangle().fill(Color.border).frame(height: 1)
            column {
                VStack(alignment: .leading, spacing: Space.s6) {
                    AttachmentList(draft: attachments).disabled(action.isRunning)
                    MessageComposerBar(label: "Message", text: $text, canSend: canSend, isSending: action.isRunning,
                        isReadingAttachments: attachments.isLoading,
                        onAttach: { Task { await attachments.pick() } }, onSend: { Task { await send() } })
                    if case .failed(let message) = action.phase { ErrorLine(message) }
                }
                .padding(.vertical, Space.s12)
            }
        }
        .background(Color.stage)
        .task(id: query) { await search(query) }
        .unsentDraft(!text.isBlank || !attachments.files.isEmpty)
    }

    /// Chosen people, the field that finds more, and the matches under it.
    private var recipientsField: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            ForEach(recipients) { person in
                HStack(spacing: Space.s6) {
                    Text(person.label ?? "Unknown name")
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(1)
                    IconButton(Symbol.close, label: "Remove \(person.label ?? "recipient")") {
                        recipients.removeAll { $0.id == person.id }
                    }
                }
                .padding(.horizontal, Space.s8)
            }
            TextField("To", text: $query)
                .textFieldStyle(.plain)
                .font(Type.body)
                .foregroundStyle(Color.text)
                .focused($toFocused)
                .padding(.horizontal, Space.s8)
                .frame(height: Size.control)
                .accessibilityLabel("To")
            if searchState.phase == .loading { Spinner().padding(.horizontal, Space.s8) }
            if case .failed(let message) = searchState.phase { ErrorLine(message).padding(.horizontal, Space.s8) }
            ForEach(results.filter { r in !recipients.contains { $0.id == r.id } }) { person in
                RowButton(action: {
                    recipients.append(person)
                    query = ""
                    results = []
                }) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(person.label ?? "Unknown name")
                            .font(Type.t13)
                            .foregroundStyle(Color.text)
                            .lineLimit(1)
                        if let detail = [person.role, person.organization].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                            Text(detail)
                                .font(Type.t12)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !query.isEmpty, query.count >= 2, results.isEmpty, searchState.phase == .idle, searchState.lastSuccess != nil {
                EmptyLine("No one matches").padding(.horizontal, Space.s8)
            }
        }
    }

    /// Waits for typing to pause, then searches. Only people can be messaged from here.
    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            searchState = CollectionState()
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searchState.phase = .loading
        do {
            let found = try await model.fetch(key: "recipients-\(trimmed)") { try await $0.searchRecipients(trimmed) }
            guard !Task.isCancelled else { return }
            results = found.filter { $0.isPerson && $0.canReceive != false }
            searchState = CollectionState(phase: .idle, lastSuccess: Date())
        } catch is CancellationError {
            searchState.phase = .idle
        } catch {
            searchState.phase = .failed(model.message(for: error))
        }
    }

    private func send() async {
        guard canSend else { return }
        let body = text
        let parts = attachments.files.map(\.part)
        let ids = recipients.map(\.recipientId)
        var threadId: Int?
        let sent = await action.run {
            threadId = try await model.write { writer in
                var attachmentIds: [String] = []
                for part in parts {
                    attachmentIds += try await writer.uploadMessageAttachment(part).map(\.fileId)
                }
                return try await writer.sendMessage(text: body, toPersonIds: ids, attachmentIds: attachmentIds).threadId
            }
        }
        if sent, let threadId { await onSent(threadId) }
    }
}

// MARK: - Bulletin comments

/// Comments under a bulletin, with the signed-in person's own comments editable.
struct BulletinComments: View {
    @Environment(AppModel.self) private var model
    let bulletin: Bulletin
    @State private var loader: CollectionLoader<BulletinComment>
    @State private var draft = ""
    @State private var post = WriteAction()

    init(bulletin: Bulletin) {
        self.bulletin = bulletin
        let id = bulletin.bulletinId
        _loader = State(initialValue: CollectionLoader(key: "bulletin-comments-\(id)") { client in
            try await client.bulletinComments(bulletinId: id)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            if loader.records.isEmpty {
                EmptyState(state: loader.state, empty: "No comments")
            }
            ForEach(loader.records) { comment in
                CommentRow(comment: comment) { await loader.refresh(using: model) }
            }
            if bulletin.allowComments != false {
                TextArea(label: "Comment", text: $draft, minHeight: 40)
                HStack(spacing: Space.s8) {
                    Spacer(minLength: Space.s8)
                    if post.isRunning { Spinner() }
                    if case .failed(let message) = post.phase { ErrorLine(message) }
                    TextButton("Post", role: .primary) { Task { await submit() } }
                        .disabled(post.isRunning || draft.isBlank)
                }
            }
        }
        .padding(.leading, Space.s16)
        .task { await loader.load(using: model) }
        .unsentDraft(!draft.isBlank)
    }

    private func submit() async {
        let text = draft
        let id = bulletin.bulletinId
        if await post.run({ _ = try await model.write { try await $0.postComment(bulletinId: id, text: text) } }) {
            draft = ""
            await loader.refresh(using: model)
        }
    }
}

private struct CommentRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let comment: BulletinComment
    let onChange: () async -> Void
    @State private var editing: String?
    @State private var confirmingDelete = false
    @State private var action = WriteAction()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s8) {
                Avatar(name: comment.author?.fullName, imageURL: comment.author?.imageURLString, size: 28)
                Text(comment.author?.fullName ?? "Unknown author")
                    .font(Type.t12.weight(.semibold))
                    .foregroundStyle(Color.text)
                if let date = comment.created {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                }
                Spacer(minLength: Space.s8)
                if confirmingDelete {
                    ConfirmInPlace(confirmTitle: "Delete", onConfirm: { Task { await delete() } }, onCancel: {
                        withMotion(Motion.fast, reduceMotion: reduceMotion) { confirmingDelete = false }
                    })
                } else if editing == nil {
                    if comment.allowEdit == true {
                        TextButton("Edit") { editing = comment.text ?? "" }
                    }
                    if comment.allowDelete == true {
                        TextButton("Delete", role: .danger) {
                            withMotion(Motion.fast, reduceMotion: reduceMotion) { confirmingDelete = true }
                        }
                    }
                }
            }
            if let draft = editing {
                TextArea(label: "Comment", text: Binding(get: { draft }, set: { editing = $0 }), minHeight: 40)
                HStack(spacing: Space.s8) {
                    Spacer(minLength: Space.s8)
                    if action.isRunning { Spinner() }
                    TextButton("Cancel") { editing = nil }
                    TextButton("Save", role: .primary) { Task { await save(draft) } }
                        .disabled(action.isRunning || draft.isBlank)
                }
            } else {
                Text(comment.text ?? "")
                    .font(Type.body)
                    .foregroundStyle(Color.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = action.phase { ErrorLine(message) }
        }
        .padding(.vertical, Space.s4)
    }

    private func save(_ text: String) async {
        let id = comment.commentId
        if await action.run({ try await model.write { try await $0.editComment(commentId: id, text: text) } }) {
            editing = nil
            await onChange()
        }
    }

    private func delete() async {
        let id = comment.commentId
        if await action.run({ try await model.write { try await $0.deleteComment(commentId: id) } }) {
            await onChange()
        }
        confirmingDelete = false
    }
}

// MARK: - Assignment

/// An assignment's description, files, the person's answer, and a submit form.
struct AssignmentView: View {
    @Environment(AppModel.self) private var model
    let elementId: Int
    let fallbackTitle: String
    let onClose: () -> Void
    @State private var loader: CollectionLoader<Assignment>
    @State private var text = ""
    @State private var attachments = AttachmentDraft()
    @State private var submit = WriteAction()
    @State private var submittedAnswer: Int?

    /// An answer typed or attached but not submitted.
    private var hasDraft: Bool { !text.isBlank || !attachments.files.isEmpty }

    init(elementId: Int, title: String, onClose: @escaping () -> Void) {
        self.elementId = elementId
        self.fallbackTitle = title
        self.onClose = onClose
        _loader = State(initialValue: CollectionLoader(key: "assignment-\(elementId)") { client in
            PagedResult(items: [try await client.assignment(elementId: elementId)], isComplete: true)
        })
    }

    var body: some View {
        let assignment = loader.records.first
        PageScroll {
            PageHeader(title: assignment?.title ?? fallbackTitle)
            courseLine(deadline: assignment?.deadline)
                .padding(.top, -Space.s12)
                .padding(.bottom, Space.s8)
            FreshnessLine(state: loader.state)
            if let assignment {
                if let html = assignment.text, !html.isEmpty {
                    RichTextView(html: html)
                        .frame(maxWidth: Size.readingMax, alignment: .leading)
                        .padding(.vertical, Space.s8)
                }
                ForEach(assignment.files ?? []) { file in
                    // No route fetches an assignment's file by its id, so it opens where the assignment lives.
                    let address = attachmentURL
                    RowButton(action: { if let address { NSWorkspace.shared.open(address) } }) {
                        HStack(spacing: Space.s8) {
                            Image(systemName: Symbol.file(extension: ((file.name ?? "") as NSString).pathExtension))
                                .font(.system(size: 13, weight: .regular))
                                .frame(width: Size.icon)
                                .foregroundStyle(Color.textMuted)
                                .accessibilityHidden(true)
                            Text(file.name ?? "File")
                                .font(Type.t13)
                                .foregroundStyle(Color.text)
                                .lineLimit(1)
                            Spacer(minLength: Space.s8)
                            if address != nil { WebsiteMark() }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(address == nil)
                    // The row's own inset is cancelled, so the file starts on the title's and body's edge.
                    .padding(.horizontal, -Space.s8)
                }
                submitForm(for: assignment)
            } else if case APIError.forbidden? = loader.lastError {
                EmptyLine("This task has no assignment details")
            } else {
                EmptyState(state: loader.state, empty: "This assignment is unavailable")
            }
        }
        .task { await loader.load(using: model) }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await loader.refresh(using: model) })
        .unsentDraft(hasDraft)
    }

    private var attachmentURL: URL? {
        let task = model.tasks.first { $0.elementId == elementId }
        return model.absoluteURL(task?.url ?? task?.contentUrl)
    }

    /// The course's dot and name, then when it is due, as list rows say it.
    @ViewBuilder private func courseLine(deadline: Date?) -> some View {
        let task = model.tasks.first { $0.elementId == elementId }
        let courseId = task?.courseId
        let name = courseId.flatMap { id in model.courses.first { $0.courseId == id }?.shortTitle } ?? task?.courseTitle
        let due = StudyDates.usable(deadline ?? task?.deadline)
        if name != nil || due != nil {
            HStack(spacing: Space.s6) {
                if let courseId {
                    Circle()
                        .fill(Color.course(courseId))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                if let name {
                    Text(name).lineLimit(1)
                }
                if name != nil, due != nil {
                    Text("·").accessibilityHidden(true)
                }
                if let due {
                    Text("Due \(StudyDates.relative(due))")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(Type.t12)
            .foregroundStyle(Color.textMuted)
        }
    }

    @ViewBuilder private func submitForm(for assignment: Assignment) -> some View {
        let closed = isClosed(assignment)
        VStack(alignment: .leading, spacing: Space.s8) {
            Text("Your answer")
                .font(Type.t15)
                .foregroundStyle(Color.text)
                .padding(.top, Space.s24)
                .accessibilityAddTraits(.isHeader)
            if let answerId = submittedAnswer ?? assignment.answerId {
                Text(submittedAnswer != nil || answerId == 0 ? "Submitted" : "An answer is on file. Submitting again adds a new one.")
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
            }
            if assignment.canSubmitOrEditAnswer == false || assignment.canParticipate == false {
                EmptyLine("You can't submit an answer to this assignment")
            } else if closed {
                EmptyLine("The deadline has passed and late answers are not accepted")
            } else {
                TextArea(label: "Answer text", text: $text, minHeight: 120)
                AttachmentList(draft: attachments)
                    .disabled(submit.isRunning)
                HStack(spacing: Space.s8) {
                    IconButton(Symbol.attach, label: "Attach files") { Task { await attachments.pick() } }
                        .disabled(attachments.isLoading || submit.isRunning)
                    // The paperclip itself, not its hover square, starts on the answer box's edge.
                    .padding(.leading, -Space.s6)
                    // What Submit will send, said before it is pressed.
                    Text(summary)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                    Spacer(minLength: Space.s8)
                    if submit.isRunning { Spinner() }
                    if case .failed(let message) = submit.phase { ErrorLine(message) }
                    TextButton("Submit", role: .primary) { Task { await send() } }
                        .disabled(submit.isRunning || attachments.isLoading || (text.isBlank && attachments.files.isEmpty))
                }
            }
        }
    }

    private func isClosed(_ assignment: Assignment) -> Bool {
        guard let deadline = StudyDates.usable(assignment.deadline), deadline < Date() else { return false }
        return assignment.isSubmissionAfterDeadlineAllowed != true
    }

    /// What Submit will send, said before it is pressed.
    private var summary: String {
        let hasText = !text.isBlank
        switch (hasText, attachments.files.count) {
        case (false, 0): return ""
        case (true, 0): return "Submits your text"
        case (false, let n): return n == 1 ? "Submits 1 file" : "Submits \(n) files"
        case (true, let n): return n == 1 ? "Submits your text and 1 file" : "Submits your text and \(n) files"
        }
    }

    private func send() async {
        guard !submit.isRunning, !attachments.isLoading, hasDraft else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = body.isEmpty ? nil : body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .components(separatedBy: "\n\n")
            .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
        let parts = attachments.files.map(\.part)
        let elementId = elementId
        var answer: Int?
        let ok = await submit.run {
            answer = try await model.write { writer in
                var uploaded: [UploadedTempFile] = []
                for part in parts { uploaded.append(try await writer.uploadTempFile(part)) }
                return try await writer.submitAnswer(elementId: elementId, text: html, files: uploaded)
            }
        }
        if ok {
            submittedAnswer = answer
            text = ""
            attachments.clear()
        }
    }
}

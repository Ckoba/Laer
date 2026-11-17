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
        case is LocalFileError: "The file could not be read."
        default: "That didn't go through. Check before trying again."
        }
    }
}

// MARK: - Files

struct LocalFileError: Error {}

/// A file the user picked, read into memory for one upload.
struct PickedFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let contentType: String
    let data: Data

    var part: UploadPart { UploadPart(fileName: name, contentType: contentType, data: data) }

    /// Shows an open panel. Large files are refused here rather than half-uploaded.
    @MainActor
    static func pick(maxBytes: Int = 100 * 1024 * 1024) throws -> [PickedFile] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return try panel.urls.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            if let size = values?.fileSize, size > maxBytes { throw LocalFileError() }
            guard let data = try? Data(contentsOf: url) else { throw LocalFileError() }
            let type = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
            return PickedFile(name: url.lastPathComponent, contentType: type, data: data)
        }
    }
}

/// Picked files, each removable before sending.
struct AttachmentList: View {
    @Binding var files: [PickedFile]

    var body: some View {
        ForEach(files) { file in
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
                IconButton(Symbol.close, label: "Remove \(file.name)") {
                    files.removeAll { $0.id == file.id }
                }
            }
        }
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.stage))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.borderStrong, lineWidth: 1))
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

/// Replies in a thread. Sending is one action: attachments upload, then the message is sent once.
struct MessageComposer: View {
    @Environment(AppModel.self) private var model
    let threadId: Int
    let onSent: () async -> Void
    @State private var text = ""
    @State private var files: [PickedFile] = []
    @State private var action = WriteAction()
    @State private var pickError: String?

    private var canSend: Bool {
        !action.isRunning && (!text.isBlank || !files.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            TextArea(label: "Reply", text: $text)
            AttachmentList(files: $files)
            HStack(spacing: Space.s8) {
                IconButton(Symbol.attach, label: "Attach files") { attach() }
                Spacer(minLength: Space.s8)
                if action.isRunning { Spinner() }
                if case .failed(let message) = action.phase { ErrorLine(message) }
                if let pickError { ErrorLine(pickError) }
                TextButton("Send", role: .primary) { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
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
    @State private var files: [PickedFile] = []
    @State private var action = WriteAction()
    @State private var pickError: String?

    private var canSend: Bool {
        !action.isRunning && !recipients.isEmpty
            && (!text.isBlank || !files.isEmpty)
    }

    var body: some View {
        PageScroll {
            HStack(spacing: Space.s6) {
                IconButton(Symbol.close, label: "Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Space.s8)
            }
            PageHeader(title: "New message")
                .padding(.vertical, Space.s8)
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
            }
            FieldBox(label: "To", text: $query)
            if searchState.phase == .loading { Spinner() }
            if case .failed(let message) = searchState.phase { ErrorLine(message) }
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
                                .font(Type.t11)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !query.isEmpty, query.count >= 2, results.isEmpty, searchState.phase == .idle, searchState.lastSuccess != nil {
                EmptyLine("No one matches")
            }
            TextArea(label: "Message", text: $text, minHeight: 96)
                .padding(.top, Space.s8)
            AttachmentList(files: $files)
            HStack(spacing: Space.s8) {
                IconButton(Symbol.attach, label: "Attach files") {
                    pickError = nil
                    do { files += try PickedFile.pick() } catch { pickError = WriteText.failure(error) }
                }
                Spacer(minLength: Space.s8)
                if action.isRunning { Spinner() }
                if case .failed(let message) = action.phase { ErrorLine(message) }
                if let pickError { ErrorLine(pickError) }
                TextButton("Send", role: .primary) { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
        }
        .task(id: query) { await search(query) }
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
        let body = text
        let parts = files.map(\.part)
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
    @State private var files: [PickedFile] = []
    @State private var submit = WriteAction()
    @State private var pickError: String?
    @State private var submittedAnswer: Int?

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
            HStack(spacing: Space.s6) {
                IconButton(Symbol.back, label: "Back", action: onClose)
                    .keyboardShortcut("[", modifiers: .command)
                Spacer(minLength: Space.s8)
            }
            PageHeader(title: assignment?.title ?? fallbackTitle)
                .padding(.vertical, Space.s8)
            FreshnessLine(state: loader.state)
            if let assignment {
                Text(StudyDates.deadline(assignment.deadline))
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                if let html = assignment.text, !html.isEmpty {
                    RichTextView(html: html).padding(.vertical, Space.s8)
                }
                ForEach(assignment.files ?? []) { file in
                    HStack(spacing: Space.s6) {
                        Image(systemName: Symbol.material)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.textMuted)
                            .accessibilityHidden(true)
                        Text(file.name ?? "File")
                            .font(Type.t13)
                            .foregroundStyle(Color.text)
                            .lineLimit(1)
                    }
                    .plainRow()
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
            TextArea(label: "Answer text", text: $text, minHeight: 96)
            AttachmentList(files: $files)
            HStack(spacing: Space.s8) {
                IconButton(Symbol.attach, label: "Attach files") {
                    pickError = nil
                    do { files += try PickedFile.pick() } catch { pickError = WriteText.failure(error) }
                }
                Text(summary)
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                Spacer(minLength: Space.s8)
                if submit.isRunning { Spinner() }
                if case .failed(let message) = submit.phase { ErrorLine(message) }
                if let pickError { ErrorLine(pickError) }
                TextButton("Submit", role: .primary) { Task { await send() } }
                    .disabled(submit.isRunning || (text.isBlank && files.isEmpty))
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
        switch (hasText, files.count) {
        case (false, 0): return ""
        case (true, 0): return "Submits your text"
        case (false, let n): return n == 1 ? "Submits 1 file" : "Submits \(n) files"
        case (true, let n): return n == 1 ? "Submits your text and 1 file" : "Submits your text and \(n) files"
        }
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = body.isEmpty ? nil : body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .components(separatedBy: "\n\n")
            .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
        let parts = files.map(\.part)
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
            files = []
        }
    }
}

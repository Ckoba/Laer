import LaerCore
import SwiftUI

/// Menu bar commands. Add to the scene with `.commands { LaerCommands(model: model) }`.
struct LaerCommands: Commands {
    let model: AppModel
    @FocusedBinding(\.courseTab) private var courseTab
    @FocusedValue(\.refreshCurrent) private var refreshCurrent
    @FocusedValue(\.openPalette) private var openPalette
    @AppStorage(LaerApp.showsMenuBarKey) private var showsMenuBarExtra = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.openNewTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!isReady)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                let current = refreshCurrent
                Task {
                    await model.refreshAll()
                    await current?.run()
                }
            }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!isReady)
            Divider()
        }
        CommandMenu("Go") {
            Button("Search…") { openPalette?.run() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!isReady || openPalette == nil)
            Divider()
            Button("Home") { model.selection = .home }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!isReady)
            Button("Assignments") { model.selection = .upcoming }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(!isReady)
            if ParityGate.personalCalendar {
                Button("Calendar") { model.selection = .calendar }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(!isReady)
            }
            if ParityGate.messages {
                Button("Messages") { model.selection = .messages }
                    .keyboardShortcut("0", modifiers: [.command, .control])
                    .disabled(!isReady)
            }
            Button("Next course") { moveCourse(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!isReady || model.courses.isEmpty)
            Button("Previous course") { moveCourse(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!isReady || model.courses.isEmpty)
            Divider()
            ForEach(Array(CourseTab.available().enumerated()), id: \.element) { index, tab in
                Button(tab.title) { courseTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(courseTab == nil)
            }
        }
        CommandGroup(after: .appSettings) {
            Toggle("Show Laer in Menu Bar", isOn: $showsMenuBarExtra)
            // Shown only where Apple's on-device model can run. Off until the person turns it on (decision 0014).
            if model.briefs.isAvailable {
                Toggle("Make Lecture Briefs on This Mac", isOn: Binding(
                    get: { model.briefs.isEnabled },
                    set: { enabled in Task { await model.setOnDeviceBriefs(enabled) } }
                ))
            }
            Divider()
            Button("Sign out") { Task { await model.signOut() } }
                .disabled(!isReady)
            Button("Change institution") { Task { await model.changeInstitution() } }
                .disabled(model.site == nil)
        }
    }

    private var isReady: Bool {
        if case .ready = model.authState { return true }
        return false
    }

    private func moveCourse(by offset: Int) {
        let active = Set(model.activeCourses.map(\.courseId))
        let archived = Set(model.archivedCourses.map(\.courseId))
        let visible = model.activeCourses + model.courses.filter { !active.contains($0.courseId) && !archived.contains($0.courseId) }
        let order = AppModel.Selection.sidebarOrder(courses: visible)
        let current = model.selection.flatMap { order.firstIndex(of: $0) } ?? 0
        model.selection = order[min(max(current + offset, 0), order.count - 1)]
    }
}

/// Refreshes whatever the focused screen shows, beyond the account-wide collections.
struct RefreshAction {
    let run: @MainActor () async -> Void

    init(_ run: @escaping @MainActor () async -> Void) {
        self.run = run
    }
}

/// Opens the command palette in the focused window.
struct PaletteAction {
    let run: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var refreshCurrent: RefreshAction?
    @Entry var openPalette: PaletteAction?
}

extension AppModel.Selection {
    /// Rail then sidebar order, for keyboard movement.
    static func sidebarOrder(courses: [Course]) -> [AppModel.Selection] {
        var order: [AppModel.Selection] = [.home, .upcoming]
        if ParityGate.personalCalendar { order.append(.calendar) }
        if ParityGate.messages { order.append(.messages) }
        return order + courses.map { .course($0.courseId) }
    }
}

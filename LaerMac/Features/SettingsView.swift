import AppKit
import SwiftUI

/// Laer's preferences, in the standard Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SearchSettings()
                .tabItem { Label("Search", systemImage: Symbol.search) }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .appliesAppearance()
    }
}

/// The person's choice of light or dark, for every Laer window.
enum Appearance: String, CaseIterable {
    case system, light, dark

    static let key = "LaerAppearance"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Sets the whole app's appearance, so the main window, file viewer and menu bar window follow it.
    /// UI tests keep the system's, so RootView's test appearance decides there.
    func apply() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("-LaerUITestReset"), !arguments.contains("-LaerUITestAppearance") else { return }
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension View {
    /// Applies the stored appearance now and whenever it changes.
    func appliesAppearance() -> some View { modifier(AppearanceApplier()) }
}

private struct AppearanceApplier: ViewModifier {
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    func body(content: Content) -> some View {
        content.onChange(of: appearance, initial: true) { appearance.apply() }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(LaerApp.showsMenuBarKey) private var showsMenuBarExtra = true
    @AppStorage(AppModel.fetchesAheadKey) private var fetchesAhead = true
    @State private var confirmsBriefsOff = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show Laer in the menu bar", isOn: $showsMenuBarExtra)
            }
            Section {
                Toggle(isOn: $fetchesAhead) {
                    Text("Get files before you open them")
                    Text("Finds download links for files on screen and saves the next lessons’ readings, so they open at once. Off: only files you click are fetched.")
                }
                .onChange(of: fetchesAhead) { if !fetchesAhead { model.stopFetchingAhead() } }
            }
            // Shown only where Apple's on-device model can run (decision 0014).
            if model.briefs.isAvailable {
                Section {
                    Toggle("Make lecture briefs on this Mac", isOn: Binding(
                        get: { model.briefs.isEnabled },
                        set: { enabled in
                            // Turning briefs off deletes them, so that one way asks first.
                            if enabled { Task { await model.setOnDeviceBriefs(true) } } else { confirmsBriefsOff = true }
                        }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Turn off lecture briefs?", isPresented: $confirmsBriefsOff) {
            Button("Turn Off and Delete Briefs", role: .destructive) { Task { await model.setOnDeviceBriefs(false) } }
        } message: {
            Text("The briefs made on this Mac are deleted.")
        }
    }
}

private struct SearchSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("LaerSearchOnline") private var onlineEnabled = false
    @AppStorage("LaerIndexArchivedCourses") private var indexArchived = false
    @AppStorage(AppModel.searchOCRPreference) private var recognizesScans = false
    @State private var confirmsOCRRemoval = false
    @State private var confirmsOnline = false

    var body: some View {
        Form {
            Section {
                Toggle("Search itslearning online", isOn: Binding(
                    get: { onlineEnabled },
                    set: { enabled in
                        // What the person types leaves the Mac, so turning it on asks first.
                        if enabled { confirmsOnline = true } else { onlineEnabled = false }
                    }
                ))
                Toggle("Index archived courses", isOn: $indexArchived)
            }
            Section {
                Toggle(isOn: $recognizesScans) {
                    Text("Recognize text in scans and images")
                    if recognizesScans && model.searchOCRPowerPaused {
                        Text("Paused in Low Power Mode")
                    }
                }
                .disabled(model.searchOCRIsClearing)
                HStack {
                    Text("Recognized text")
                    Spacer()
                    Button("Remove…") { confirmsOCRRemoval = true }
                        .accessibilityLabel("Remove recognized text")
                        .disabled(model.searchOCRIsClearing || model.searchIndex == nil)
                }
            }
            Section {
                HStack {
                    Text("Search index")
                    Spacer()
                    if model.isIndexing {
                        ProgressView().controlSize(.small)
                    } else if model.searchIndexFailed {
                        Text("Can’t be read").foregroundStyle(Color.danger)
                    }
                    Button("Rebuild") { Task { await model.rebuildSearchIndex() } }
                        .disabled(model.isIndexing || model.searchOCRIsClearing || model.snapshots == nil)
                }
            }
        }
        .formStyle(.grouped)
        // The palette may be closed, so the index reacts here, where the options change.
        .onChange(of: indexArchived) { Task { await model.changeSearchCoverage() } }
        .onChange(of: recognizesScans) { model.updateSearchOCR() }
        .confirmationDialog("Search itslearning online?", isPresented: $confirmsOnline) {
            Button("Search Online") { onlineEnabled = true }
        } message: {
            Text("What you type is sent to your school’s itslearning site.")
        }
        .confirmationDialog("Remove recognized text?", isPresented: $confirmsOCRRemoval) {
            Button("Remove Recognized Text", role: .destructive) {
                recognizesScans = false
                Task { await model.removeRecognizedSearchText() }
            }
        } message: {
            Text("Your saved files are kept.")
        }
    }
}

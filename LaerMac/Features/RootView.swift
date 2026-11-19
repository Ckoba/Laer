import LaerCore
import SwiftUI
import WebKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.authState {
            case .choosingSite:
                SitePickerView()
            case .launching:
                Color.rail.ignoresSafeArea()
            case .signingIn:
                SignInView()
            case .ready:
                MainView()
            }
        }
        .tint(Color.accent)
        .appliesAppearance()
        #if DEBUG
        // Screenshot tests pick an appearance without changing the system's.
        .preferredColorScheme(Self.testAppearance)
        #endif
    }

    #if DEBUG
    private static var testAppearance: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "LaerUITestAppearance") {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }
    #endif
}

struct SitePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted = 0
    /// True once the arrow keys pick a row, so Return opens that row rather than looking the text up.
    @State private var didMoveHighlight = false
    @FocusState private var fieldFocused: Bool

    private var matches: [Site] { SiteDirectory.search(lookup, in: model.siteList) }
    private var hasQuery: Bool { !lookup.isEmpty }

    /// The school Return will open, when the current input already resolves to a suggestion.
    private var chosenSite: Site? {
        let candidates = matches
        if didMoveHighlight, candidates.indices.contains(highlighted) { return candidates[highlighted] }
        let typed = lookup
        let exact = candidates.first { $0.shortName.caseInsensitiveCompare(typed) == .orderedSame }
        return exact ?? (typed.contains(where: \.isWhitespace) ? candidates.first : nil)
    }

    /// The text to look up: a pasted address becomes the first label of its host, so
    /// `https://school.example.com/path` is looked up as `school`.
    private var lookup: String { Self.lookupText(query) }

    static func lookupText(_ raw: String) -> String {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.contains(where: \.isWhitespace) else { return typed }
        let candidate = typed.contains("://") ? typed : (typed.contains(".") || typed.contains("/") ? "https://" + typed : "")
        guard !candidate.isEmpty, let host = URL(string: candidate)?.host(), host.contains("."),
              let first = host.split(separator: ".").first, !first.isEmpty
        else { return typed }
        return String(first)
    }

    var body: some View {
        VStack(spacing: Space.s12) {
            VStack(alignment: .leading, spacing: Space.s12) {
                VStack(spacing: Space.s8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    // The heading is the action; the icon and the line below carry the welcome.
                    Text("Find your school")
                        .font(Type.title)
                        .foregroundStyle(Color.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your itslearning courses, tasks, timetable and messages in one Mac app.")
                        .font(Type.body)
                        .foregroundStyle(Color.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, Space.s8)
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("School or university")
                        .font(Type.t13.weight(.medium))
                        .foregroundStyle(Color.text)
                    SchoolField(label: "Name or itslearning address", text: $query, isFocused: $fieldFocused, onSubmit: submit)
                        // UI tests find the field by this name.
                        .accessibilityIdentifier("Institution")
                    Text("Search by name or paste the itslearning address you use to sign in.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                if hasQuery, !matches.isEmpty {
                    suggestions
                } else if hasQuery, !model.siteList.isEmpty, !model.isResolvingSite, model.siteError == nil {
                    Text("No match yet. Try the name of your school, or the address from your itslearning sign-in page.")
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.s8) {
                    Button(action: submit) {
                        Text(chosenSite.map { "Sign in to \($0.title)" } ?? "Find school")
                            .font(Type.t13.weight(.medium))
                            .lineLimit(1)
                    }
                    // Bordered prominent, so it still reads as a button while it is disabled.
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasQuery || model.isResolvingSite)
                    if model.isResolvingSite { Spinner() }
                }
                if let error = model.siteError {
                    ErrorLine(error)
                }
            }
            .welcomeCard()
            Text("Laer is not affiliated with itslearning. Your password is entered on your school’s own sign-in page.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: WelcomeCard.width)
        }
        .padding(Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chrome)
        .task { await model.loadSiteList() }
        .onAppear { fieldFocused = true }
        .onChange(of: query) {
            highlighted = 0
            didMoveHighlight = false
            // A list that failed to load is tried again as the person keeps typing.
            Task { await model.loadSiteList() }
        }
        .onChange(of: model.siteList) { highlighted = 0 }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.customerId) { index, site in
                RowButton(selected: index == highlighted, action: { choose(site) }) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(site.title)
                            .font(Type.t13)
                            .foregroundStyle(Color.text)
                            .lineLimit(1)
                        Text(site.baseURL.host() ?? site.shortName)
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("\(site.title), \(site.baseURL.host() ?? site.shortName)")
            }
        }
        .padding(Space.s4)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.stage))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Institutions")
    }

    private func move(_ offset: Int) {
        guard !matches.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), matches.count - 1)
        didMoveHighlight = true
    }

    private func choose(_ site: Site) {
        guard !model.isResolvingSite else { return }
        Task { await model.chooseSite(site) }
    }

    /// Return opens a row picked with the arrow keys, or a suggestion whose short name is exactly the text.
    /// Otherwise the text is looked up as a short name, so a site missing from the list still opens,
    /// and the top suggestion opens only when no site has that short name.
    private func submit() {
        guard hasQuery, !model.isResolvingSite else { return }
        let typed = lookup
        if let site = chosenSite {
            choose(site)
        } else {
            Task { await model.chooseSite(shortName: typed, fallback: matches.first) }
        }
    }
}

/// The institution's own sign-in page, in the session's web view, under a thin Laer bar.
private struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s8) {
                Text(model.site.map { "Sign in to \($0.title)" } ?? "Sign in")
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                Spacer(minLength: Space.s8)
                TextButton("Change institution") { Task { await model.changeInstitution() } }
            }
            .padding(.horizontal, Space.s12)
            .padding(.vertical, Space.s6)
            .background(Color.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
            if model.signInLoadFailed {
                VStack(spacing: Space.s12) {
                    ErrorLine("The sign-in page couldn’t load. Check your connection.")
                    TextButton("Try again") { model.retrySignInPage() }
                }
                .welcomeCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.chrome)
            } else if let session = model.webSession {
                WebSessionView(webView: session.webView)
            } else {
                Spinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The school field, with its text inset so the caret never sits on the placeholder's first letter.
private struct SchoolField: View {
    let label: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        TextField(label, text: $text)
            .focused(isFocused)
            .textFieldStyle(.plain)
            .font(Type.t13)
            .foregroundStyle(Color.text)
            .padding(.leading, Space.s12)
            .padding(.trailing, Space.s8)
            .frame(height: Size.control)
            .fieldChrome(focused: isFocused.wrappedValue)
            .onSubmit(onSubmit)
            .accessibilityLabel(label)
    }
}

/// The first-run card: a fixed-width raised panel on the stage.
private enum WelcomeCard {
    static let width: CGFloat = 420
}

private extension View {
    func welcomeCard() -> some View {
        frame(width: WelcomeCard.width - Space.s24 * 2)
            .padding(Space.s24)
            .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Color.stage))
            .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
    }
}

/// Shows the session's own web view, so sign-in happens in the store the app reads through.
struct WebSessionView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

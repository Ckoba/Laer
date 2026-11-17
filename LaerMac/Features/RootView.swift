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

    private var matches: [Site] { SiteDirectory.search(query, in: model.siteList) }
    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Choose your institution")
                .font(Type.t18)
                .foregroundStyle(Color.text)
                .accessibilityAddTraits(.isHeader)
            Text("Search by name, or type the first part of the address you sign in at, such as school in school.itslearning.com.")
                .font(Type.t12)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            FieldBox(label: "Institution", text: $query, onSubmit: submit)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            if hasQuery, !matches.isEmpty {
                suggestions
            }
            HStack(spacing: Space.s8) {
                TextButton("Continue", role: .primary, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasQuery || model.isResolvingSite)
                if model.isResolvingSite { Spinner() }
            }
            if let error = model.siteError {
                ErrorLine(error)
            }
        }
        .frame(width: 360)
        .padding(Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stage)
        .task { await model.loadSiteList() }
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
        let typed = query.trimmingCharacters(in: .whitespaces)
        if didMoveHighlight, matches.indices.contains(highlighted) {
            choose(matches[highlighted])
        } else if let exact = matches.first(where: { $0.shortName.caseInsensitiveCompare(typed) == .orderedSame }) {
            choose(exact)
        } else if typed.contains(where: \.isWhitespace), let top = matches.first {
            choose(top)
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
                    ErrorLine("The sign-in page couldn't load. Check your connection.")
                    TextButton("Try again") { model.retrySignInPage() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = model.webSession {
                WebSessionView(webView: session.webView)
            } else {
                Spinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Shows the session's own web view, so sign-in happens in the store the app reads through.
struct WebSessionView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

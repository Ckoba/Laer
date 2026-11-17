// The one icon set: SF Symbols, outline only. Views name icons through `Symbol`, never a string
// literal, so the same action has the same icon everywhere. No `.fill` variants.

enum Symbol {
    // Actions
    static let close = "xmark"
    static let refresh = "arrow.clockwise"
    static let settings = "gearshape"
    static let search = "magnifyingglass"
    static let save = "arrow.down.circle"
    static let open = "arrow.up.forward.square"
    static let showInFinder = "folder"
    static let copy = "doc.on.doc"
    static let back = "chevron.backward"
    static let disclosure = "chevron.forward"
    static let more = "ellipsis.circle"
    static let attach = "paperclip"
    static let compose = "square.and.pencil"
    static let star = "star"
    static let comment = "text.bubble"
    static let comments = "bubble.left"
    static let home = "house"
    static let sidebar = "sidebar.left"
    static let expand = "chevron.down"
    static let archive = "archivebox"
    static let grades = "chart.bar"
    static let pin = "pin"
    static let lecture = "clock"
    static let edit = "pencil"
    static let exam = "graduationcap"

    // Things
    static let course = "book.closed"
    static let update = "bell"
    static let material = "doc"
    static let folder = "folder"
    static let link = "link"
    static let task = "checklist"
    static let message = "bubble.left.and.bubble.right"
    static let plan = "calendar"
    static let account = "person.crop.circle"
    static let saved = "checkmark.circle"
    static let brief = "list.bullet.rectangle"
    static let appUpdate = "arrow.down.to.line.circle"
    static let rotate = "rotate.right"
    static let newTab = "plus"
    static let resources = "folder"
    static let announcements = "megaphone"

    /// Icons a person can give their own links.
    static let linkChoices = [
        "globe", "envelope", "graduationcap", "key", "person.crop.circle", "calendar",
        "doc.text", "book.closed", "building.columns", "video", "link",
    ]

    /// A first guess from a link's name and address; the person can pick another.
    static func linkIcon(title: String, address: String) -> String {
        let text = "\(title) \(address)".lowercased()
        let rules: [([String], String)] = [
            (["mail", "outlook", "gmail"], "envelope"),
            (["exam", "eksam", "prøve"], "graduationcap"),
            (["sso", "login", "sign in", "signin", "auth"], "key"),
            (["calendar", "kalender", "skema", "schedule", "timetable"], "calendar"),
            (["zoom", "teams", "meet"], "video"),
            (["library", "bibliotek"], "book.closed"),
        ]
        return rules.first { $0.0.contains { text.contains($0) } }?.1 ?? "globe"
    }
}

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
    /// Leaving Laer for the website, next to its words (`WebsiteLink`).
    static let website = "arrow.up.forward"
    static let showInFinder = "folder"
    static let copy = "doc.on.doc"
    static let back = "chevron.backward"
    static let forward = "chevron.forward"
    static let disclosure = "chevron.forward"
    static let more = "ellipsis.circle"
    static let attach = "paperclip"
    static let add = "plus"
    static let send = "arrow.up"
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
    static let message = "message"
    static let plan = "calendar"
    static let account = "person.crop.circle"
    static let saved = "checkmark.circle"
    static let brief = "list.bullet.rectangle"
    static let appUpdate = "arrow.down.to.line.circle"
    static let rotate = "rotate.right"
    static let newTab = add
    static let resources = "folder"
    static let announcements = "megaphone"

    /// One symbol per file type, so a PDF looks the same in Home, Plans, Files, Search and the viewer.
    static func file(extension ext: String?) -> String {
        switch (ext ?? "").lowercased() {
        case "pdf": return "doc.richtext"
        case "ppt", "pptx", "key", "odp": return "rectangle.on.rectangle"
        case "xls", "xlsx", "csv", "numbers", "ods": return "tablecells"
        case "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "webp", "svg": return "photo"
        case "doc", "docx", "txt", "rtf", "pages", "odt": return "doc.text"
        default: return material
        }
    }

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

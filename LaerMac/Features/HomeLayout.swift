import Foundation

/// A tile's footprint on Home's grid, in column and row units.
struct HomeTileSize: Codable, Hashable, Sendable {
    var columns: Int
    var rows: Int

    static let s1x1 = HomeTileSize(columns: 1, rows: 1)
    static let s2x1 = HomeTileSize(columns: 2, rows: 1)
    static let s1x2 = HomeTileSize(columns: 1, rows: 2)
    static let s2x2 = HomeTileSize(columns: 2, rows: 2)
    static let s4x1 = HomeTileSize(columns: 4, rows: 1)
    static let s4x2 = HomeTileSize(columns: 4, rows: 2)

    func clamped(to maxColumns: Int) -> HomeTileSize {
        HomeTileSize(columns: max(1, min(columns, max(1, maxColumns))), rows: max(1, rows))
    }

    var accessibilityDescription: String {
        "\(columns) by \(rows)"
    }
}

/// One of Home's sections, as the person arranges them.
enum HomeBlock: String, CaseIterable, Codable, Identifiable, Sendable {
    case due, schedule, updates, messages, plans, exams

    var id: String { rawValue }

    var title: String {
        switch self {
        case .due: String(localized: "Due")
        case .schedule: String(localized: "Schedule")
        case .updates: String(localized: "Updates")
        case .messages: String(localized: "Messages")
        case .plans: String(localized: "Next plan")
        case .exams: String(localized: "Exams")
        }
    }

    var symbol: String {
        switch self {
        case .due: Symbol.task
        case .schedule: Symbol.plan
        case .updates: Symbol.announcements
        case .messages: Symbol.message
        case .plans: Symbol.brief
        case .exams: Symbol.exam
        }
    }

    /// Sizes this section supports, ordered from smallest to largest footprint.
    var supportedSizes: [HomeTileSize] {
        switch self {
        case .due: [.s1x1, .s2x1, .s2x2, .s4x2]
        case .schedule: [.s1x1, .s2x1, .s2x2, .s4x2]
        case .updates: [.s1x1, .s2x1, .s2x2, .s4x2]
        case .messages: [.s1x1, .s2x1, .s2x2, .s4x2]
        case .plans: [.s1x1, .s2x1, .s2x2, .s4x2]
        case .exams: [.s1x1, .s2x1, .s2x2, .s4x1]
        }
    }

    var defaultSize: HomeTileSize {
        switch self {
        case .due: .s2x2
        case .schedule: .s2x2
        case .plans: .s2x2
        case .updates: .s2x1
        case .messages: .s2x1
        case .exams: .s2x1
        }
    }

    /// Size used when migrating a saved layout from the earlier small/large toggle.
    var largeMigrationSize: HomeTileSize {
        switch self {
        case .exams: .s4x1
        default: .s4x2
        }
    }

    /// Supported sizes with distinct effective footprints at `maxColumns`, keeping the narrower
    /// declared size when two collapse to the same span on a narrower pane.
    func distinctSizes(maxColumns: Int) -> [HomeTileSize] {
        var seen: Set<HomeTileSize> = []
        var result: [HomeTileSize] = []
        for size in supportedSizes {
            let effective = size.clamped(to: maxColumns)
            if seen.insert(effective).inserted {
                result.append(size)
            }
        }
        return result
    }

    func nearestSupportedSize(to target: HomeTileSize) -> HomeTileSize {
        if supportedSizes.contains(target) { return target }
        return snapSize(targetColumns: Double(target.columns), targetRows: Double(target.rows), maxColumns: 4)
    }

    /// Snaps a continuous drag footprint (in grid units) to the closest supported size.
    func snapSize(targetColumns: Double, targetRows: Double, maxColumns: Int) -> HomeTileSize {
        let candidates = distinctSizes(maxColumns: maxColumns)
        return candidates.min { lhs, rhs in
            let le = lhs.clamped(to: maxColumns)
            let re = rhs.clamped(to: maxColumns)
            let ld = hypot(Double(le.columns) - targetColumns, Double(le.rows) - targetRows)
            let rd = hypot(Double(re.columns) - targetColumns, Double(re.rows) - targetRows)
            if abs(ld - rd) > 0.001 { return ld < rd }
            return (lhs.columns * lhs.rows) < (rhs.columns * rhs.rows)
        } ?? defaultSize
    }

    func nextSize(after current: HomeTileSize, maxColumns: Int) -> HomeTileSize {
        let sizes = distinctSizes(maxColumns: maxColumns)
        guard !sizes.isEmpty else { return defaultSize }
        let clamped = current.clamped(to: maxColumns)
        if let index = sizes.firstIndex(where: { $0.clamped(to: maxColumns) == clamped }) {
            return sizes[(index + 1) % sizes.count]
        }
        return sizes[0]
    }

    func previousSize(before current: HomeTileSize, maxColumns: Int) -> HomeTileSize {
        let sizes = distinctSizes(maxColumns: maxColumns)
        guard !sizes.isEmpty else { return defaultSize }
        let clamped = current.clamped(to: maxColumns)
        if let index = sizes.firstIndex(where: { $0.clamped(to: maxColumns) == clamped }) {
            return sizes[(index - 1 + sizes.count) % sizes.count]
        }
        return sizes[0]
    }
}

/// A cell on Home's grid, zero-based.
struct HomeGridCell: Codable, Hashable, Sendable {
    var column: Int
    var row: Int
}

/// One placed tile on the grid, in zero-based column and row coordinates.
struct HomeGridPlacement: Equatable, Identifiable, Sendable {
    var item: HomeLayout.Item
    var column: Int
    var row: Int
    var columnSpan: Int
    var rowSpan: Int

    var id: HomeBlock { item.block }
}

/// Which sections Home shows, in what order, and each section's grid size.
struct HomeLayout: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var block: HomeBlock
        var size: HomeTileSize
        /// Where the person put the tile, per column count, since a narrower window has its own grid.
        /// A tile with none for the current count takes the first free space.
        var positions: [String: HomeGridCell] = [:]
        var id: HomeBlock { block }

        func cell(columns: Int) -> HomeGridCell? { positions[String(columns)] }

        init(block: HomeBlock, size: HomeTileSize? = nil) {
            self.block = block
            self.size = block.nearestSupportedSize(to: size ?? block.defaultSize)
        }

        private enum CodingKeys: String, CodingKey {
            case block, size, isLarge, positions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            block = try c.decode(HomeBlock.self, forKey: .block)
            if let decoded = try c.decodeIfPresent(HomeTileSize.self, forKey: .size) {
                size = block.nearestSupportedSize(to: decoded)
            } else if let isLarge = try c.decodeIfPresent(Bool.self, forKey: .isLarge) {
                size = isLarge ? block.largeMigrationSize : block.defaultSize
            } else {
                size = block.defaultSize
            }
            positions = try c.decodeIfPresent([String: HomeGridCell].self, forKey: .positions) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(block, forKey: .block)
            try c.encode(size, forKey: .size)
            if !positions.isEmpty { try c.encode(positions, forKey: .positions) }
        }
    }

    var items: [Item]

    static let standard = HomeLayout(items: [
        Item(block: .due, size: .s2x2),
        Item(block: .schedule, size: .s2x2),
        Item(block: .plans, size: .s2x2),
        Item(block: .updates, size: .s2x1),
        Item(block: .messages, size: .s2x1),
        Item(block: .exams, size: .s2x1),
    ])

    func hidden(among available: [HomeBlock]) -> [HomeBlock] {
        available.filter { block in !items.contains { $0.block == block } }
    }

    mutating func remove(_ block: HomeBlock) {
        items.removeAll { $0.block == block }
    }

    mutating func add(_ block: HomeBlock) {
        guard !items.contains(where: { $0.block == block }) else { return }
        items.append(Item(block: block))
    }

    /// Takes the tiles' new sizes and positions, keeping the order.
    mutating func update(with edited: [Item]) {
        for item in edited {
            if let index = items.firstIndex(where: { $0.block == item.block }) { items[index] = item }
        }
    }

    /// Places each tile where the person put it, gaps and all. A tile whose place is taken goes
    /// to the nearest free space at or below it; tiles never placed fill the first free space.
    static func arrange(_ items: [Item], columns: Int) -> [HomeGridPlacement] {
        let cols = max(1, columns)
        var grid = Occupancy(columns: cols)
        var placed: [HomeBlock: HomeGridPlacement] = [:]

        func place(_ item: Item, at cell: HomeGridCell, width: Int, height: Int) {
            grid.fill(cell, width: width, height: height)
            placed[item.block] = HomeGridPlacement(
                item: item, column: cell.column, row: cell.row, columnSpan: width, rowSpan: height
            )
        }

        func footprint(_ item: Item) -> (width: Int, height: Int) {
            (max(1, min(item.size.columns, cols)), max(1, item.size.rows))
        }

        for item in items {
            guard let wanted = item.cell(columns: cols) else { continue }
            let (width, height) = footprint(item)
            let start = HomeGridCell(column: min(max(wanted.column, 0), cols - width), row: max(wanted.row, 0))
            place(item, at: grid.nearestFree(from: start, width: width, height: height), width: width, height: height)
        }
        for item in items where placed[item.block] == nil {
            let (width, height) = footprint(item)
            let origin = HomeGridCell(column: 0, row: 0)
            place(item, at: grid.nearestFree(from: origin, width: width, height: height, readingOrder: true), width: width, height: height)
        }
        return items.compactMap { placed[$0.block] }
    }

    /// Every tile with the cell it is shown in, so an edit to one leaves the rest where they are.
    static func pinned(_ items: [Item], columns: Int) -> [Item] {
        let cols = max(1, columns)
        return arrange(items, columns: cols).map { placement in
            var item = placement.item
            item.positions[String(cols)] = HomeGridCell(column: placement.column, row: placement.row)
            return item
        }
    }

    /// `block` moved to `cell` or given `size`; tiles it lands on move to the nearest free space below.
    static func placing(
        _ block: HomeBlock, at cell: HomeGridCell?, size: HomeTileSize?, in items: [Item], columns: Int
    ) -> [Item] {
        let cols = max(1, columns)
        var all = pinned(items, columns: cols)
        guard let index = all.firstIndex(where: { $0.block == block }) else { return all }
        var moved = all.remove(at: index)
        if let size { moved.size = block.nearestSupportedSize(to: size) }
        if let cell { moved.positions[String(cols)] = cell }
        let arranged = pinned([moved] + all, columns: cols)
        return items.compactMap { item in arranged.first { $0.block == item.block } }
    }

    private struct Occupancy {
        let columns: Int
        var rows: [[Bool]] = []

        init(columns: Int) { self.columns = columns }

        private mutating func fits(_ cell: HomeGridCell, width: Int, height: Int) -> Bool {
            while rows.count < cell.row + height { rows.append(Array(repeating: false, count: columns)) }
            for r in cell.row..<(cell.row + height) {
                for c in cell.column..<(cell.column + width) where rows[r][c] { return false }
            }
            return true
        }

        mutating func fill(_ cell: HomeGridCell, width: Int, height: Int) {
            _ = fits(cell, width: width, height: height)
            for r in cell.row..<(cell.row + height) {
                for c in cell.column..<(cell.column + width) { rows[r][c] = true }
            }
        }

        /// The free space nearest `start` on its row or below. Moving down is cheaper than moving
        /// sideways, so a tile that is pushed drops straight down its column when it can. In
        /// reading order it is simply the first free space, top to bottom and left to right.
        mutating func nearestFree(
            from start: HomeGridCell, width: Int, height: Int, readingOrder: Bool = false
        ) -> HomeGridCell {
            let columnsToTry = Array(0...(columns - width))
            if readingOrder {
                var row = start.row
                while true {
                    for column in columnsToTry where fits(HomeGridCell(column: column, row: row), width: width, height: height) {
                        return HomeGridCell(column: column, row: row)
                    }
                    row += 1
                }
            }
            var best: (cell: HomeGridCell, cost: Int)?
            var row = start.row
            while best == nil || row - start.row < best!.cost {
                for column in columnsToTry where fits(HomeGridCell(column: column, row: row), width: width, height: height) {
                    let cost = (row - start.row) + 2 * abs(column - start.column)
                    if best == nil || cost < best!.cost { best = (HomeGridCell(column: column, row: row), cost) }
                }
                row += 1
            }
            return best!.cell
        }
    }

    // MARK: Storage

    /// Saved on this Mac. Fixture runs keep their own copy, and test runs keep none, so neither
    /// touches the person's real Home.
    private static var key: String? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "LaerUITestReset") { return nil }
        return defaults.bool(forKey: "LaerFixtureMode") ? "homeLayout.fixture" : "homeLayout"
    }

    static func load() -> HomeLayout {
        guard let key, let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HomeLayout.self, from: data) else { return .standard }
        var seen: Set<HomeBlock> = []
        let unique = decoded.items.filter { seen.insert($0.block).inserted }
        return HomeLayout(items: unique)
    }

    func save() {
        guard let key = Self.key, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

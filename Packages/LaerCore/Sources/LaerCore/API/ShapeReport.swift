import Foundation

/// Describes the structure of a JSON response without keeping any of its values.
///
/// Key names and value types are recorded. Strings are reduced to a category. Only the
/// fields in `enumKeys`, which hold API-defined constants rather than user content, keep values.
public enum ShapeReport {
    static let enumKeys: Set<String> = ["ElementType", "LocationType", "ContentType"]

    public static func describe(json data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return render(shape(of: object), indent: 0)
    }

    indirect enum Shape: Equatable {
        case null
        case bool
        case number
        case string(Set<String>)
        case array(Shape?, Int)
        case object([String: Shape])
        case mixed
    }

    static func shape(of value: Any, key: String? = nil) -> Shape {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool : .number
        case let string as String:
            if let key, enumKeys.contains(key) { return .string(["enum:\(string)"]) }
            return .string([category(of: string)])
        case let array as [Any]:
            let merged = array.map { shape(of: $0) }.reduce(nil as Shape?) { merge($0, $1) }
            return .array(merged, array.count)
        case let object as [String: Any]:
            return .object(object.reduce(into: [:]) { $0[$1.key] = shape(of: $1.value, key: $1.key) })
        default:
            return .mixed
        }
    }

    static func merge(_ lhs: Shape?, _ rhs: Shape) -> Shape {
        guard let lhs else { return rhs }
        switch (lhs, rhs) {
        case (.null, let other), (let other, .null):
            return other
        case let (.string(a), .string(b)):
            return .string(a.union(b))
        case let (.array(a, x), .array(b, y)):
            if let a, let b { return .array(merge(a, b), x + y) }
            return .array(a ?? b, x + y)
        case let (.object(a), .object(b)):
            return .object(a.merging(b) { merge($0, $1) })
        default:
            return lhs == rhs ? lhs : .mixed
        }
    }

    static func category(of string: String) -> String {
        if string.isEmpty { return "empty" }
        if let date = APIDate.parse(string) {
            // Placeholder years stand in for "no deadline" on some routes, so they need spotting.
            return Calendar(identifier: .gregorian).component(.year, from: date) >= 9000 ? "date-placeholder" : "date"
        }
        if string.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return "date-unparsed" }
        if string.hasPrefix("http://") || string.hasPrefix("https://") { return "absolute-url" }
        if string.hasPrefix("/") { return "relative-url" }
        return "text"
    }

    static func render(_ shape: Shape, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch shape {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .mixed: return "mixed"
        case .string(let categories): return categories.sorted().joined(separator: "|")
        case .array(let element, let count):
            guard let element else { return "[] (0)" }
            return "[\(render(element, indent: indent))] (\(count))"
        case .object(let fields):
            let lines = fields.keys.sorted().map { "\(pad)  \($0): \(render(fields[$0]!, indent: indent + 1))" }
            return "{\n\(lines.joined(separator: "\n"))\n\(pad)}"
        }
    }
}

import Foundation

/// Parses the instants the API returns, with or without fractional seconds or a zone.
enum APIDate {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        // Some routes omit the zone. The API documents its instants as UTC.
        if let date = try? Date(string + "Z", strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        return nil
    }

    static let decoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = parse(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date format")
        }
        return date
    }
}

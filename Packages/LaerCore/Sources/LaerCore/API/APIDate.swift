import Foundation

/// Parses the instants the API returns, with or without fractional seconds or a zone.
enum APIDate {
    static func parse(_ string: String, defaultTimeZone: TimeZone = .current) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        // Routes such as `course/{id}/plans/all/v1` omit the timezone and serialize wall-clock
        // time in the user's local zone rather than UTC.
        return parseLocalWallClock(string, timeZone: defaultTimeZone)
    }

    private static func parseLocalWallClock(_ string: String, timeZone: TimeZone) -> Date? {
        let base: String
        let nanoseconds: Int
        if let dot = string.firstIndex(of: ".") {
            base = String(string[..<dot])
            let frac = String(string[string.index(after: dot)...])
            guard !frac.isEmpty, frac.allSatisfy(\.isNumber) else { return nil }
            let padded = String(frac.prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
            guard let ns = Int(padded) else { return nil }
            nanoseconds = ns
        } else {
            base = string
            nanoseconds = 0
        }
        let parts = base.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let timeParts = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard dateParts.count == 3, timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar, timeZone: timeZone,
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second, nanosecond: nanoseconds
        )
        guard components.isValidDate else { return nil }
        return calendar.date(from: components)
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

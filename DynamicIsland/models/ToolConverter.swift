import Foundation

enum ToolConversionError: LocalizedError, Equatable {
    case emptyInput
    case invalidBase64
    case invalidUTF8
    case invalidTimestamp
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Enter a value to convert."
        case .invalidBase64:
            return "Enter a valid Base64 value."
        case .invalidUTF8:
            return "The decoded value is not valid UTF-8 text."
        case .invalidTimestamp:
            return "Enter a 10-digit seconds or 13-digit milliseconds timestamp."
        case .invalidDate:
            return "Enter a valid date in yyyy-MM-dd HH:mm:ss format."
        }
    }
}

struct TimestampConversionResult: Equatable {
    let seconds: Int64
    let milliseconds: Int64
}

enum ToolConverter {
    private static let dateFormat = "yyyy-MM-dd HH:mm:ss"
    private static let shanghaiTimeZone =
        TimeZone(identifier: "Asia/Shanghai")
        ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!

    static func encodeBase64(_ input: String) throws -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolConversionError.emptyInput
        }

        return Data(input.utf8).base64EncodedString()
    }

    static func decodeBase64(_ input: String) throws -> String {
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            throw ToolConversionError.emptyInput
        }
        guard let data = Data(base64Encoded: normalizedInput) else {
            throw ToolConversionError.invalidBase64
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw ToolConversionError.invalidUTF8
        }

        return decoded
    }

    static func dateString(fromTimestamp input: String) throws -> String {
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            throw ToolConversionError.emptyInput
        }
        guard normalizedInput.count == 10 || normalizedInput.count == 13,
            normalizedInput.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let timestamp = Int64(normalizedInput)
        else {
            throw ToolConversionError.invalidTimestamp
        }

        let seconds =
            normalizedInput.count == 13
            ? TimeInterval(timestamp) / 1_000
            : TimeInterval(timestamp)
        return makeDateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    static func timestamps(fromDateString input: String) throws -> TimestampConversionResult {
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            throw ToolConversionError.emptyInput
        }

        let formatter = makeDateFormatter()
        guard let date = formatter.date(from: normalizedInput),
            formatter.string(from: date) == normalizedInput
        else {
            throw ToolConversionError.invalidDate
        }

        let seconds = Int64(date.timeIntervalSince1970.rounded())
        return TimestampConversionResult(
            seconds: seconds,
            milliseconds: seconds * 1_000
        )
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = shanghaiTimeZone
        formatter.dateFormat = dateFormat
        formatter.isLenient = false
        return formatter
    }
}

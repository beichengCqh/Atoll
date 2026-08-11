import Foundation

@main
struct ToolConverterRegression {
    static func main() throws {
        try verifiesBase64Conversion()
        try verifiesTimestampConversion()
        verifiesErrors()
    }

    private static func verifiesBase64Conversion() throws {
        let encoded = try ToolConverter.encodeBase64("Atoll 工具")
        precondition(encoded == "QXRvbGwg5bel5YW3")

        let decoded = try ToolConverter.decodeBase64("QXRvbGwg5bel5YW3")
        precondition(decoded == "Atoll 工具")

        let trimmed = try ToolConverter.decodeBase64("  QXRvbGw=\n")
        precondition(trimmed == "Atoll")
    }

    private static func verifiesTimestampConversion() throws {
        let secondsDate = try ToolConverter.dateString(fromTimestamp: "1704067200")
        precondition(secondsDate == "2024-01-01 08:00:00")

        let millisecondsDate = try ToolConverter.dateString(fromTimestamp: "1704067200000")
        precondition(millisecondsDate == "2024-01-01 08:00:00")

        let timestamps = try ToolConverter.timestamps(fromDateString: "2024-01-01 08:00:00")
        precondition(timestamps.seconds == 1_704_067_200)
        precondition(timestamps.milliseconds == 1_704_067_200_000)
    }

    private static func verifiesErrors() {
        expectError(.emptyInput) {
            _ = try ToolConverter.encodeBase64("  \n")
        }
        expectError(.invalidBase64) {
            _ = try ToolConverter.decodeBase64("%%invalid%%")
        }
        expectError(.invalidUTF8) {
            _ = try ToolConverter.decodeBase64("/w==")
        }
        expectError(.invalidTimestamp) {
            _ = try ToolConverter.dateString(fromTimestamp: "17040672000")
        }
        expectError(.invalidTimestamp) {
            _ = try ToolConverter.dateString(fromTimestamp: "170406720x")
        }
        expectError(.invalidDate) {
            _ = try ToolConverter.timestamps(fromDateString: "2024-02-30 08:00:00")
        }
    }

    private static func expectError(
        _ expected: ToolConversionError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            fatalError("Expected \(expected), but the operation succeeded")
        } catch let error as ToolConversionError {
            precondition(error == expected, "Expected \(expected), got \(error)")
        } catch {
            fatalError("Expected \(expected), got \(error)")
        }
    }
}

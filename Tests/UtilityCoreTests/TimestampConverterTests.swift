import Foundation
import Testing
import UtilityCore

@Suite struct TimestampConverterTests {
    @Test func preservesNegativeMicrosecondsAndKeepsTheCorrectCivilSecond() throws {
        let fromSeconds = try UnixMicrosecondTimestamp.parse("-0.000001", unit: .seconds)
        let fromMilliseconds = try UnixMicrosecondTimestamp.parse("-0,001", unit: .milliseconds)
        let fromMicroseconds = try UnixMicrosecondTimestamp.parse("-1", unit: .microseconds)
        #expect(fromSeconds == fromMilliseconds && fromMilliseconds == fromMicroseconds)
        #expect(fromSeconds.microseconds == -1)
        #expect(fromSeconds.formatted(in: .seconds) == "-0.000001")
        #expect(fromSeconds.formatted(in: .milliseconds) == "-0.001")
        #expect(fromSeconds.formatted(in: .microseconds) == "-1")
        let display = try TimestampConverter.display(fromSeconds, in: .gmt)
        #expect(display.iso8601 == "1969-12-31T23:59:59.999999Z")
        #expect(display.local == "1969-12-31 23:59:59.999999")
        #expect(try TimestampConverter.resolveLocal(display.local, in: .gmt).map(\.timestamp) == [fromSeconds])
    }

    @Test func parsesAndFormatsSigned64BitBoundariesWithoutDoubleRounding() throws {
        let min = try UnixMicrosecondTimestamp.parse("-9223372036854.775808", unit: .seconds)
        let max = try UnixMicrosecondTimestamp.parse("+9223372036854.775807", unit: .seconds)
        #expect(min.microseconds == Int64.min)
        #expect(max.microseconds == Int64.max)
        #expect(min.formatted(in: .seconds) == "-9223372036854.775808")
        #expect(max.formatted(in: .milliseconds) == "9223372036854775.807")
        #expect(throws: ToolError.self) { try UnixMicrosecondTimestamp.parse("9223372036854775808", unit: .microseconds) }
        #expect(throws: ToolError.self) { try UnixMicrosecondTimestamp.parse("-1.0000001", unit: .seconds) }
        #expect(throws: ToolError.self) { try UnixMicrosecondTimestamp.parse("2abc", unit: .seconds) }
        #expect(throws: ToolError.self) { try TimestampConverter.display(min, in: .gmt) }
    }

    @Test func copiedISO8601RoundTripsInAnySelectedZone() throws {
        let zone = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
        for microseconds: Int64 in [-1, 0, 1_707_680_901_123_456] {
            let timestamp = UnixMicrosecondTimestamp(microseconds: microseconds)
            let iso8601 = try TimestampConverter.display(timestamp, in: .gmt).iso8601
            #expect(try TimestampConverter.resolveDate(iso8601, in: zone).map(\.timestamp) == [timestamp])
        }
        let east = try TimestampConverter.resolveDate("1970-01-01T05:29:59.999999+05:30", in: zone)
        let west = try TimestampConverter.resolveDate("1969-12-31t19:00:00.000001-05:00", in: zone)
        #expect(east.first?.timestamp.microseconds == -1)
        #expect(east.first?.offset == "UTC+05:30")
        #expect(west.first?.timestamp.microseconds == 1)
        #expect(try TimestampConverter.resolveDate("1970-01-01t00:00:00z", in: zone).first?.timestamp.microseconds == 0)
    }

    @Test func rejectsInvalidOffsetsAndUnrepresentableUTCYears() {
        for text in ["1970-01-01T00:00:00+24:00", "1970-01-01T00:00:00-02:60",
                     "1970-01-01T00:00:00.0000001Z", "0001-01-01T00:00:00+08:00",
                     "1970-01-01 00:00:00 UTC+00:00:60"] {
            #expect(throws: ToolError.self) { try TimestampConverter.resolveDate(text, in: .gmt) }
        }
    }

    @Test func compactISOOffsetsAcceptExactMicrosecondsWithoutChangingControls() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let east = try #require(try TimestampConverter.resolveDate("1970-01-01T05:29:59.999999+0530", in: zone).first)
        #expect(east.timestamp.microseconds == -1 && east.offset == "UTC+05:30")
        let west = try #require(try TimestampConverter.resolveDate("1969-12-31T19:00:00.000001-0500", in: zone).first)
        #expect(west.timestamp.microseconds == 1 && west.offset == "UTC-05:00")
        let unknown = try #require(try TimestampConverter.resolveDate("1970-01-01T00:00:00-0000", in: zone).first)
        #expect(unknown.timestamp.microseconds == 0 && unknown.offset.contains("Unknown local offset"))
        for malformed in ["+2400", "-0560", "+050", "+0:500"] {
            #expect(throws: ToolError.self) {
                try TimestampConverter.resolveDate("1970-01-01T00:00:00" + malformed, in: zone)
            }
        }
    }

    @Test func copiedLocalTimePreservesHistoricalOffsetSeconds() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let occurrence = try #require(TimestampConverter.resolveLocal("1911-03-10 23:55:00.123456", in: paris).first)
        let display = try TimestampConverter.display(occurrence.timestamp, in: paris)
        #expect(display.offset == "UTC+00:09:21")
        let pasted = try TimestampConverter.resolveDate(display.local + " " + display.offset, in: .gmt)
        #expect(pasted.map(\.timestamp) == [occurrence.timestamp])
        let unknown = try #require(TimestampConverter.resolveDate("1970-01-01T00:00:00-00:00", in: paris).first)
        #expect(unknown.timestamp.microseconds == 0)
        #expect(unknown.offset == "Unknown local offset (UTC−00:00)")
    }

    @Test func rejectsLocalDatesOutsideTheRepresentableUTCYears() throws {
        let east = try #require(TimeZone(secondsFromGMT: 3_600))
        let west = try #require(TimeZone(secondsFromGMT: -3_600))
        #expect(throws: ToolError.self) { try TimestampConverter.resolveDate("0001-01-01 00:00:00", in: east) }
        #expect(throws: ToolError.self) { try TimestampConverter.resolveDate("9999-12-31 23:59:59", in: west) }
    }

    @Test func surfacesASpringGapAndANonHourFallFold() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(try TimestampConverter.resolveLocal("2024-03-10 02:30:00.123456", in: newYork).isEmpty)
        let lordHowe = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
        let folded = try TimestampConverter.resolveDate("2024-04-07 01:45:00.654321", in: lordHowe)
        #expect(folded.map(\.offset) == ["UTC+11:00", "UTC+10:30"])
        let timestamps = try folded.map { try TimestampConverter.display($0.timestamp, in: lordHowe) }
        #expect(timestamps.map(\.iso8601) == ["2024-04-06T14:45:00.654321Z", "2024-04-06T15:15:00.654321Z"])
        #expect(timestamps.allSatisfy { $0.local == "2024-04-07 01:45:00.654321" })
        #expect(try TimestampConverter.resolveLocal("2024-10-06 02:15:00", in: lordHowe).isEmpty)
    }

    @Test func respectsGregorianCalendarAndHistoricalTimeZoneOffsetSeconds() throws {
        let early = try #require(TimestampConverter.resolveLocal("1500-01-01 00:00:00", in: .gmt).first)
        #expect(early.timestamp.formatted(in: .seconds) == "-14831769600")
        #expect(throws: ToolError.self) {
            try TimestampConverter.resolveLocal("2024-02-30 00:00:00", in: .gmt)
        }
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let historical = try TimestampConverter.resolveLocal("1911-03-10 23:55:00", in: paris)
        #expect(historical.map(\.offset) == ["UTC+00:09:21", "UTC+00:00"])
        let apia = try #require(TimeZone(identifier: "Pacific/Apia"))
        #expect(try TimestampConverter.resolveLocal("2011-12-30 12:00:00", in: apia).isEmpty)
    }
}

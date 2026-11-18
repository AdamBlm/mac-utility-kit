import Testing
import UtilityCore

@Suite struct ScreenColorValueTests {
    @Test func matchesKnownCSSColorValues() throws {
        let color = try #require(ScreenColorValue(red: 0.2, green: 0.4, blue: 0.6))
        #expect(color.value(.hex) == "#336699")
        #expect(color.value(.rgb) == "rgb(51, 102, 153)")
        #expect(color.value(.hsl) == "hsl(210, 50%, 40%)")
        #expect(color.value(.hsl, precision: .hundredths) == "hsl(210.00, 50.00%, 40.00%)")
        let cyan = try #require(ScreenColorValue(red: 0, green: 1, blue: 1))
        #expect(cyan.value(.hsl) == "hsl(180, 100%, 50%)")
        let magenta = try #require(ScreenColorValue(red: 1, green: 0, blue: 1))
        #expect(magenta.value(.hsl) == "hsl(300, 100%, 50%)")
        let grey = try #require(ScreenColorValue(red: 0.5, green: 0.5, blue: 0.5))
        #expect(grey.value(.hsl) == "hsl(0, 0%, 50%)")
        #expect(grey.value(.hex) == "#808080")
        #expect(grey.value(.rgb, precision: .tenths) == "rgb(127.5, 127.5, 127.5)")
    }

    @Test func clipsGamutAndKeepsPrecisionIndependentOfHex() throws {
        #expect(ScreenColorValue(red: .nan, green: 0, blue: 1) == nil)
        #expect(ScreenColorValue(red: 0, green: -.infinity, blue: 1) == nil)
        let clipped = try #require(ScreenColorValue(red: 1.03, green: -0.01, blue: 0))
        #expect(clipped.value(.hex, precision: .thousandths) == "#FF0000")
        let nearRed = try #require(ScreenColorValue(red: 1, green: 0, blue: 0.0001))
        #expect(nearRed.value(.hsl) == "hsl(0, 100%, 50%)")
        #expect(nearRed.value(.hsl, precision: .thousandths) == "hsl(359.994, 100.000%, 50.000%)")
        let halfByte = try #require(ScreenColorValue(red: 126.5 / 255, green: 0, blue: 0))
        #expect(halfByte.value(.rgb) == "rgb(127, 0, 0)")
        #expect(halfByte.value(.hex) == "#7F0000")
    }

    @Test func keepsRecentDistinctSwatchesAndRevisitsWithoutReordering() throws {
        var history = ColorSampleHistory()
        for number in 0..<20 {
            history.sample(try #require(ScreenColorValue(red: Double(number) / 20, green: 0, blue: 0)))
        }
        #expect(history.recent.count == 16)
        let first = try #require(history.recent.first)
        let last = try #require(history.recent.last)
        history.select(last)
        #expect(history.current == last)
        #expect(history.recent.first == first)
        history.sample(last)
        #expect(history.recent.first == last)
        #expect(history.recent.count == 16)
        history.clear()
        #expect(history.current == nil && history.recent.isEmpty)
    }
}

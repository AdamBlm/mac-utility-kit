import Testing
import UtilityCore

struct MapCoordinateTests {
    @Test func parsesDecimalAndDMSAndRoundsWithoutOverflowingSeconds() throws {
        let south = try MapCoordinate.parse("−33.856784, 151.215297")
        let roundTrip = try MapCoordinate.parse(south.degreesMinutesSeconds)
        #expect(south.distance(to: roundTrip) < 0.25)
        let nearPole = try MapCoordinate(latitude: 89.9999999, longitude: -179.9999999)
        let rounded = try MapCoordinate.parse(nearPole.degreesMinutesSeconds)
        #expect(rounded.latitude == 90 && rounded.longitude == -180)
        #expect(south.decimal == "-33.856784, 151.215297")
    }

    @Test func rejectsInvalidBoundsAndReportsGeodesicDistances() throws {
        #expect(throws: ToolError.self) { try MapCoordinate.parse("90.1, 12") }
        #expect(throws: ToolError.self) { try MapCoordinate.parse("48° 60′ 0″ N, 2° 4′ 0″ E") }
        let west = try MapCoordinate.parse("0, 179.5")
        let east = try MapCoordinate.parse("0, -179.5")
        #expect((110_000...112_000).contains(west.distance(to: east)))
    }
}

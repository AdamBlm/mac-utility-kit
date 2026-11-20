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

    @Test func acceptsCommonHemisphereCoordinateFormatsWithoutAComma() throws {
        let expected = try MapCoordinate(latitude: 33.5, longitude: -122.25)
        #expect(try MapCoordinate.parse("33.5°n 122.25°w") == expected)
        #expect(try MapCoordinate.parse("33° 30.0′ N; 122° 15.0′ W") == expected)
        #expect(try MapCoordinate.parse("33° 30' 0\" N 122° 15' 0\" W") == expected)
        #expect(throws: ToolError.self) { try MapCoordinate.parse("33.5° 30′ N 122.25° W") }
        #expect(throws: ToolError.self) { try MapCoordinate.parse("33° 30.5′ 20″ N 122.25° W") }
        #expect(throws: ToolError.self) { try MapCoordinate.parse("122° W 33° N") }
        #expect(throws: ToolError.self) { try MapCoordinate.parse("33° N 180° 0.1′ E") }
    }

    @Test func importsRFC5870HorizontalCoordinatesAndCopiesRoundTrippableGeoURI() throws {
        let point = try MapCoordinate(latitude: -33.856784, longitude: 151.215297)
        #expect(try MapCoordinate.parse(" GEO:-33.856784,151.215297,-5;CRS=WGS84;U=12.5;name=a%20b ") == point)
        #expect(point.geoURI == "geo:-33.856784,151.215297")
        #expect(try MapCoordinate.parse(point.geoURI) == point)
    }

    @Test(arguments: ["geo:94,0", "geo:0,181", "geo:0,0;crs=other",
                      "geo:0,0;u=-3", "geo:0,0;u=2;u=3", "geo:0,0;name=abc;crs=wgs84",
                      "geo:0,0;name=%zz", "geo:0%2C0", "geo:0,0#fragment", "geo:+4,7"])
    func rejectsInvalidGeoURIs(_ input: String) {
        #expect(throws: ToolError.self) { try MapCoordinate.parse(input) }
    }
}

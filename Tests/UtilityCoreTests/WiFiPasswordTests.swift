import CoreWLAN
import Foundation
import Security
import Testing
@testable import UtilityCore

struct WiFiPasswordTests {
    @Test func savedLookupScansOnlySelectedSSIDAndStopsOnDeniedAuthorization() throws {
        let ssid = Data([0x45, 0x78, 0x3b, 0x41])
        var domains: [CWKeychainDomain] = []
        #expect(throws: ToolError.self) {
            try WiFiPassword.lookup(ssid: ssid) { domain, selection in
                #expect(selection == ssid)
                domains.append(domain)
                return (errSecUserCanceled, nil)
            }
        }
        #expect(domains == [.user])

        domains.removeAll()
        let retrieved = try WiFiPassword.lookup(ssid: ssid) { domain, selection in
            #expect(selection == ssid)
            domains.append(domain)
            return domain == .user ? (errSecItemNotFound, nil) : (errSecSuccess, "synthetic-secret")
        }
        #expect(retrieved == "synthetic-secret")
        #expect(domains == [.user, .system])
    }

    @Test func labelsUnsupportedSecurityAndMissingPasswords() {
        #expect(WiFiPassword.networkSecurity(.wpa2Personal) == .shareable(.wpa))
        #expect(WiFiPassword.networkSecurity(.none) == .shareable(.open))
        if case .unsupported = WiFiPassword.networkSecurity(.wpa3Enterprise) {
        } else {
            Issue.record("Enterprise profile was incorrectly marked shareable.")
        }
        #expect(throws: ToolError.self) {
            try WiFiPassword.passwordResult(status: errSecItemNotFound, value: nil)
        }
        #expect(throws: ToolError.self) {
            try WiFiPassword.qr(name: String(repeating: "あ", count: 11), security: .open, password: "", hidden: false)
        }
    }

    @Test func roundTripsEachSupportedWiFiQRFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appending(path: "Network.png")
        let name = "Example;Guest"
        for security in QRPayload.Security.allCases {
            let password = security == .open ? "" : "example;secret\\123"
            let image = try WiFiPassword.qr(name: name, security: security, password: password, hidden: true)
            try QRTools.png(image).write(to: png)
            let text = try QRPayload.wiFi(name: name, security: security, password: password, hidden: true).encoded()
            #expect(try QRTools.detect(in: png).first?.payload == text)
        }
    }
}

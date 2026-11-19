import CoreGraphics
import CoreWLAN
import Foundation
import Security

package enum WiFiPassword {
    package enum NetworkSecurity: Equatable, Sendable {
        case shareable(QRPayload.Security)
        case unsupported(String)
    }

    package struct SavedNetwork: Identifiable, Sendable {
        package struct ID: Hashable, Sendable {
            let ssidData: Data
            let securityType: Int
        }

        package let id: ID
        package let name: String
        package let security: NetworkSecurity
    }

    package static func savedNetworks() async -> [SavedNetwork] {
        await Task.detached(priority: .userInitiated) {
            let client = CWWiFiClient.shared()
            var saved: [SavedNetwork.ID: SavedNetwork] = [:]
            for interface in client.interfaces() ?? [] {
                for case let profile as CWNetworkProfile in interface.configuration()?.networkProfiles ?? NSOrderedSet() {
                    guard let bytes = profile.ssidData, (1...32).contains(bytes.count) else { continue }
                    let id = SavedNetwork.ID(ssidData: bytes, securityType: profile.security.rawValue)
                    let name = String(data: bytes, encoding: .utf8)
                    saved[id] = SavedNetwork(
                        id: id, name: name ?? profile.ssid ?? "Network with a non-UTF-8 name",
                        security: name == nil ? .unsupported("The saved network name cannot be encoded as a Wi-Fi QR.")
                            : networkSecurity(profile.security)
                    )
                }
            }
            return saved.values.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                if order != .orderedSame { return order == .orderedAscending }
                if $0.id.ssidData != $1.id.ssidData { return $0.id.ssidData.lexicographicallyPrecedes($1.id.ssidData) }
                return $0.id.securityType < $1.id.securityType
            }
        }.value
    }

    package static func savedPassword(for network: SavedNetwork) async throws -> String {
        let profiles = await savedNetworks()
        try Task.checkCancellation()
        let ssid = try credentialSSID(for: network, in: profiles)
        let password = try await Keychain.shared.password(for: ssid)
        try Task.checkCancellation()
        return password
    }

    package static func credentialSSID(for network: SavedNetwork, in profiles: [SavedNetwork]) throws -> Data {
        guard let current = profiles.first(where: { $0.id == network.id }) else {
            throw ToolError.invalid("The saved network changed or is no longer available. Refresh or enter the password manually.")
        }
        guard case .shareable(let security) = current.security, security != .open else {
            throw ToolError.invalid("The selected network has no supported saved password.")
        }
        let ssid = current.id.ssidData
        // CoreWLAN identifies the keychain item by SSID, which does not distinguish security profiles.
        guard !profiles.contains(where: { $0.id.ssidData == ssid && $0.id != current.id }) else {
            throw ToolError.invalid("Several saved profiles use this network name. Enter the password manually for the selected security type.")
        }
        return ssid
    }

    private actor Keychain {
        static let shared = Keychain()

        func password(for ssid: Data) throws -> String {
            try WiFiPassword.lookup(ssid: ssid) { domain, selectedSSID in
                var value: NSString?
                let status = CWKeychainFindWiFiPassword(domain, selectedSSID, &value)
                return (status, value as String?)
            }
        }
    }

    static func lookup(
        ssid: Data, query: (CWKeychainDomain, Data) -> (OSStatus, String?)
    ) throws -> String {
        try Task.checkCancellation()
        let (status, value) = query(.user, ssid)
        if status == errSecItemNotFound {
            try Task.checkCancellation()
            let (fallbackStatus, fallbackValue) = query(.system, ssid)
            return try passwordResult(status: fallbackStatus, value: fallbackValue)
        }
        return try passwordResult(status: status, value: value)
    }

    package static func qr(
        name: String, security: QRPayload.Security, password: String, hidden: Bool
    ) throws -> CGImage {
        guard (1...32).contains(name.utf8.count) else {
            throw ToolError.invalid("Enter a Wi-Fi network name of 1 to 32 UTF-8 bytes.")
        }
        return try QRTools.generate(.wiFi(name: name, security: security, password: password, hidden: hidden))
    }

    static func networkSecurity(_ native: CWSecurity) -> NetworkSecurity {
        switch native {
        case .none: .shareable(.open)
        case .WEP: .shareable(.wep)
        case .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal, .wpa3Transition: .shareable(.wpa)
        case .wpa3Personal: .unsupported("WPA3-only networks are outside the supported Wi-Fi QR formats.")
        case .dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise:
            .unsupported("Enterprise networks require a separate sign-in or certificate.")
        case .OWE, .oweTransition: .unsupported("Enhanced Open networks are outside the supported Wi-Fi QR formats.")
        default: .unsupported("macOS did not identify a supported security type for this network.")
        }
    }

    static func passwordResult(status: OSStatus, value: String?) throws -> String {
        switch status {
        case errSecSuccess:
            if let value, !value.isEmpty { return value }
            fallthrough
        case errSecItemNotFound:
            throw ToolError.invalid("A password for this network is unavailable. You can enter it manually.")
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ToolError.invalid("macOS did not authorize access to the saved password. You can enter it manually.")
        default:
            throw ToolError.invalid("macOS could not retrieve this saved password. You can enter it manually.")
        }
    }
}

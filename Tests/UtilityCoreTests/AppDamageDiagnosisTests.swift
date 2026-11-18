import Foundation
import Security
import Testing
@testable import UtilityCore

struct AppDamageDiagnosisTests {
    @Test func classifiesOnlyEvidenceOfBrokenSealsAsDamage() {
        #expect(AppDamageDiagnosis.signatureForStatus(errSecSuccess) == .verified)
        #expect(AppDamageDiagnosis.signatureForStatus(errSecCSUnsigned) == .unsigned)
        #expect(AppDamageDiagnosis.signatureForStatus(errSecCSBadResource) == .invalid)
        #expect(AppDamageDiagnosis.signatureForStatus(errSecCSSignatureFailed) == .invalid)
        #expect(AppDamageDiagnosis.signatureForStatus(errSecCSSignatureNotVerifiable) == .indeterminate)
    }

    @Test func requiresABooleanPolicyVerdict() throws {
        func parse(_ fields: [String: Any]) throws -> AppDamageDiagnosis.Assessment {
            let data = try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
            return AppDamageDiagnosis.parseAssessment(data, detail: nil)
        }
        #expect(try parse(["assessment:verdict": false]).allowsExecution == false)
        #expect(try parse([
            "assessment:verdict": true,
            "assessment:authority": ["assessment:authority:source": "Apple System"],
        ]).authority == "Apple System")
        #expect(try parse(["assessment:verdict": 1]).allowsExecution == nil)
        #expect(try parse(["assessment:verdict": "true"]).allowsExecution == nil)
        #expect(AppDamageDiagnosis.parseAssessment(Data(), detail: "unavailable").detail == "unavailable")
    }

    @Test func verifiesKnownMacOSBundleReadOnly() async throws {
        let url = URL(filePath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let report = try await AppDamageDiagnosis.inspect(url)
        #expect(report.bundleIdentifier == "com.apple.calculator")
        #expect(report.signature == .verified)
        #expect(report.quarantined == false)
    }
}

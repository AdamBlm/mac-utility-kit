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

    @Test(arguments: [false, true])
    func rejectsChangedBundleBeforeReturningMixedInspectionEvidence(replaceBundle: Bool) async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let app = folder.appending(path: "Sample.app")
        let moved = folder.appending(path: "Previous.app")
        let info = app.appending(path: "Contents/Info.plist")
        try manager.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "example.temporary", "CFBundlePackageType": "APPL"],
            format: .xml, options: 0
        )
        try plist.write(to: info)
        do {
            _ = try await AppDamageDiagnosis.inspect(app) { _ in
                let manager = FileManager.default
                if replaceBundle {
                    try manager.moveItem(at: app, to: moved)
                    try manager.copyItem(at: moved, to: app)
                } else {
                    try (plist + Data([0x0a])).write(to: info)
                }
                return .init(allowsExecution: true, authority: "Fixture", detail: nil)
            }
            Issue.record("A changed bundle must never produce a combined assessment.")
        } catch {
            #expect(error.localizedDescription.contains("application changed during inspection"))
        }
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

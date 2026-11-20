import Darwin
import Foundation
import Security

package enum AppDamageDiagnosis {
    package enum Signature: Equatable, Sendable {
        case verified, unsigned, invalid, indeterminate
    }

    package enum Verdict: Equatable, Sendable {
        case checksPassed, damagedOrModified, unverified, policyDenied, indeterminate
    }

    package struct Assessment: Equatable, Sendable {
        package let allowsExecution: Bool?
        package let authority: String?
        package let detail: String?
    }

    package struct Report: Sendable {
        package let name: String
        package let bundleIdentifier: String?
        package let signingIdentifier: String?
        package let teamIdentifier: String?
        package let certificateName: String?
        package let signature: Signature
        package let signatureDetail: String?
        package let quarantined: Bool?
        package let assessment: Assessment

        package var verdict: Verdict {
            switch signature {
            case .invalid: .damagedOrModified
            case .unsigned: .unverified
            case .indeterminate: .indeterminate
            case .verified:
                switch assessment.allowsExecution {
                case true?: .checksPassed
                case false?: .policyDenied
                case nil: .indeterminate
                }
            }
        }
    }

    package static func inspect(_ url: URL) async throws -> Report {
        try await inspect(url, assess: assess)
    }

    static func inspect(_ url: URL, assess: @Sendable (URL) async throws -> Assessment) async throws -> Report {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { throw ToolError.invalid("Choose a macOS application bundle.") }

        let path = url.resolvingSymlinksInPath().standardizedFileURL
        let changed = ToolError.invalid("The application changed during inspection. Choose it again.")
        guard let rootStamp = stamp(path) else { throw changed }
        let evidencePaths = ["Contents", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"]
        var evidenceURLs = [path] + evidencePaths.map { path.appending(path: $0) }
        var evidence = [Optional(rootStamp)] + evidenceURLs.dropFirst().map(stamp)
        let bundle = Bundle(url: path)
        let bundleIdentifier = bundle?.bundleIdentifier
        if let executable = bundle?.executableURL {
            evidenceURLs.append(executable)
            evidence.append(stamp(executable))
        }
        func verifyEvidence() throws {
            guard url.resolvingSymlinksInPath().standardizedFileURL == path,
                  evidenceURLs.map(stamp) == evidence else { throw changed }
        }
        try verifyEvidence()
        let signing = await Task.detached(priority: .userInitiated) { inspectSignature(path) }.value
        try Task.checkCancellation()
        try verifyEvidence()
        let assessment = try await assess(path)
        try Task.checkCancellation()
        let quarantined = quarantineStatus(path)
        try verifyEvidence()
        return Report(
            name: url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundleIdentifier,
            signingIdentifier: signing.identifier,
            teamIdentifier: signing.team,
            certificateName: signing.certificate,
            signature: signing.signature,
            signatureDetail: signing.detail,
            quarantined: quarantined,
            assessment: assessment
        )
    }

    private static func stamp(_ url: URL) -> DuplicateFileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return DuplicateFileStamp(info)
    }

    private struct Signing: Sendable {
        let signature: Signature
        let detail: String?
        var identifier: String?
        var team: String?
        var certificate: String?
    }

    private static func inspectSignature(_ url: URL) -> Signing {
        var staticCode: SecStaticCode?
        let create = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard create == errSecSuccess, let staticCode else { return signingForStatus(create) }

        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        let status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        var result = signingForStatus(status)
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
           let fields = info as? [String: Any] {
            result.identifier = fields[kSecCodeInfoIdentifier as String] as? String
            result.team = fields[kSecCodeInfoTeamIdentifier as String] as? String
            if let certificate = (fields[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first {
                result.certificate = SecCertificateCopySubjectSummary(certificate) as String?
            }
        }
        return result
    }

    static func signatureForStatus(_ status: OSStatus) -> Signature {
        switch status {
        case errSecSuccess: .verified
        case errSecCSUnsigned: .unsigned
        case errSecCSSignatureFailed, errSecCSResourcesNotFound, errSecCSResourcesInvalid,
             errSecCSBadResource, errSecCSInfoPlistFailed, errSecCSResourceDirectoryFailed,
             errSecCSUnsignedNestedCode: .invalid
        default: .indeterminate
        }
    }

    private static func signingForStatus(_ status: OSStatus) -> Signing {
        let detail = status == errSecSuccess ? nil
            : (SecCopyErrorMessageString(status, nil) as String? ?? "Security error \(status).")
        return Signing(signature: signatureForStatus(status), detail: detail)
    }

    private static func quarantineStatus(_ url: URL) -> Bool? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            if getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 { return true }
            return errno == ENOATTR ? false : nil
        }
    }

    private static func assess(_ url: URL) async throws -> Assessment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("assessment.plist")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var detail: String?
        do {
            try await ExternalTool.run(
                URL(filePath: "/usr/sbin/spctl"), name: "spctl",
                arguments: ["--assess", "--type", "execute", "--ignore-cache", "--no-cache", "--raw", url.path],
                directory: directory, standardOutput: handle
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            detail = error.localizedDescription
        }
        try Task.checkCancellation()
        return parseAssessment((try? Data(contentsOf: output)) ?? Data(), detail: detail)
    }

    static func parseAssessment(_ data: Data, detail: String?) -> Assessment {
        let fields = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        let raw = fields?["assessment:verdict"] as? NSNumber
        let verdict = raw.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        let authority = (fields?["assessment:authority"] as? [String: Any])?["assessment:authority:source"] as? String
        return Assessment(allowsExecution: verdict, authority: authority, detail: detail)
    }
}

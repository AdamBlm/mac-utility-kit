import ArgumentParser
import Foundation
import UtilityCore

struct Hash: AsyncParsableCommand, CatalogCommandBinding {
    static let configuration = CommandConfiguration(commandName: "hash", abstract: "Hash files with a selected digest algorithm.")
    static let catalogTool = Tool.hashGenerator

    @Option(help: "Digest algorithm. MD5 and SHA-1 are legacy.")
    var algorithm = Algorithm.sha256

    @Argument(help: "File paths.")
    var files: [String]

    enum Algorithm: String, CaseIterable, ExpressibleByArgument {
        case md5, sha1, sha256, sha384, sha512

        var hash: HashAlgorithm {
            switch self {
            case .md5: .md5
            case .sha1: .sha1
            case .sha256: .sha256
            case .sha384: .sha384
            case .sha512: .sha512
            }
        }
    }

    func run() async throws {
        var failed = false
        for file in files {
            do {
                let value = try await HashGenerator.file(URL(filePath: file), algorithm: algorithm.hash)
                print("\(value)  \(file)")
            } catch {
                failed = true
                writeError("\(file): \(error.localizedDescription)")
            }
        }
        if failed { throw ExitCode.failure }
    }
}

struct FormatJSON: CatalogCommandBinding {
    static let configuration = CommandConfiguration(commandName: "format-json", abstract: "Format lossless JSON from a file or standard input.")
    static let catalogTool = Tool.jsonFormatter

    @Argument(help: "UTF-8 JSON file, or - for standard input.") var file = "-"
    @Option(help: "Indentation: two, four, tab or minified.") var indentation = Indentation.two
    @Flag(help: "Sort object keys.") var sortKeys = false

    enum Indentation: String, CaseIterable, ExpressibleByArgument {
        case two, four, tab, minified

        var style: JSONIndentation {
            switch self {
            case .two: .twoSpaces
            case .four: .fourSpaces
            case .tab: .tab
            case .minified: .minified
            }
        }
    }

    func run() throws {
        let source = try readUTF8Text(file: file, limit: 16 * 1024 * 1024,
                                      invalidInput: "Provide UTF-8 JSON up to 16 MB.")
        let result = try JSONFormatter.format(source, indentation: indentation.style, sortKeys: sortKeys)
        print(result.text)
        for key in result.duplicateKeys { writeError("Duplicate key kept: \(key)") }
    }
}

func readUTF8Text(file: String, limit: Int, invalidInput: String) throws -> String {
    let handle = file == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(filePath: file))
    defer { if file != "-" { try? handle.close() } }
    var data = Data()
    while data.count <= limit, let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
        data.append(chunk)
    }
    guard data.count <= limit, let source = String(data: data, encoding: .utf8) else {
        throw ValidationError(invalidInput)
    }
    return source
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

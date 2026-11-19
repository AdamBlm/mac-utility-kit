import Foundation
import Testing
import UtilityCore

@Suite struct BatchRenameTests {
    @Test func assignsNumbersInQueueOrNaturalNameOrderAndAppliesThePreview() throws {
        try fixture { directory in
            let ten = try file("File 10.txt", in: directory)
            let two = try file("File 2.txt", in: directory)
            let one = try file("File 1.txt", in: directory)
            let files = [ten, one, two]
            var number = BatchRenameRule(kind: .number)
            number.start = 3
            number.increment = 2
            number.padding = 2
            var options = BatchRenameOptions()
            options.rules = [number]

            let queue = try BatchRename.plan(files: files, options: options)
            #expect(queue.changes.map { $0.destination.lastPathComponent } == ["File 10-03.txt", "File 1-05.txt", "File 2-07.txt"])
            options.numberingOrder = .nameAscending
            let ascending = try BatchRename.plan(files: files, options: options)
            #expect(ascending.changes.map { $0.destination.lastPathComponent } == ["File 1-03.txt", "File 2-05.txt", "File 10-07.txt"])
            options.numberingOrder = .nameDescending
            let descending = try BatchRename.plan(files: files, options: options)
            #expect(descending.changes.map { $0.destination.lastPathComponent } == ["File 10-03.txt", "File 2-05.txt", "File 1-07.txt"])

            let receipt = try ascending.apply()
            for change in ascending.changes {
                #expect(try String(contentsOf: change.destination, encoding: .utf8) == change.source.lastPathComponent)
            }
            try receipt.undo()
            for input in files { #expect(FileManager.default.fileExists(atPath: input.path)) }
        }
    }

    @Test func stackedRulesKeepExtensionsAndUndoRestoresContents() throws {
        try fixture { directory in
            let source = try file("draft-file.JPG", in: directory)
            var replace = BatchRenameRule()
            replace.search = "draft-"
            replace.replacement = "Final "
            var changeCase = BatchRenameRule(kind: .capitalization)
            changeCase.capitalization = .uppercase
            var numbering = BatchRenameRule(kind: .number)
            numbering.start = 7
            numbering.padding = 3
            var options = BatchRenameOptions()
            options.rules = [replace, changeCase, numbering]
            let plan = try BatchRename.plan(files: [source], options: options)
            let target = try #require(plan.changes.first?.destination)
            #expect(target.lastPathComponent == "FINAL FILE-007.JPG")
            let receipt = try plan.apply()
            #expect(try String(contentsOf: target, encoding: .utf8) == "draft-file.JPG")
            try receipt.undo()
            #expect(try String(contentsOf: source, encoding: .utf8) == "draft-file.JPG")
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func swapAndCaseOnlyChanges() throws {
        try fixture { directory in
            let a = try file("ab.txt", in: directory)
            let b = try file("ba.txt", in: directory)
            var rule = BatchRenameRule()
            rule.search = "^(.)(.)$"
            rule.replacement = "$2$1"
            rule.regularExpression = true
            var options = BatchRenameOptions()
            options.rules = [rule]
            let receipt = try BatchRename.plan(files: [a, b], options: options).apply()
            #expect(try String(contentsOf: a, encoding: .utf8) == "ba.txt")
            try receipt.undo()
            var uppercase = BatchRenameRule(kind: .capitalization)
            uppercase.capitalization = .uppercase
            options.rules = [uppercase]
            let caseReceipt = try BatchRename.plan(files: [a], options: options).apply()
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains("AB.txt"))
            try caseReceipt.undo()
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains("ab.txt"))
        }
    }

    @Test func newCollisionAfterPreviewDoesNotOverwriteAndUndoChecksOriginalPath() throws {
        try fixture { directory in
            let a = try file("one.txt", in: directory)
            var rule = BatchRenameRule()
            rule.search = "one"
            rule.replacement = "two"
            var options = BatchRenameOptions()
            options.rules = [rule]
            let plan = try BatchRename.plan(files: [a], options: options)
            let occupant = try file("two.txt", in: directory)
            #expect(throws: BatchRenameError.self) { try plan.apply() }
            #expect(try String(contentsOf: occupant, encoding: .utf8) == "two.txt")
            #expect(try String(contentsOf: a, encoding: .utf8) == "one.txt")
            try FileManager.default.removeItem(at: occupant)
            let receipt = try plan.apply()
            _ = try file("one.txt", in: directory)
            #expect(throws: BatchRenameError.self) { try receipt.undo() }
            #expect(try String(contentsOf: occupant, encoding: .utf8) == "one.txt")
        }
    }

    private func fixture(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    private func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
}

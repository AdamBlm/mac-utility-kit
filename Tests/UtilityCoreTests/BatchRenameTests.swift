import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Suite struct BatchRenameTests {
    @Test func usesOriginalCameraDateAndRecordedOffsetInsteadOfFileDates() throws {
        try fixture { directory in
            let photo = directory.appending(path: "photo.jpg")
            try writePhoto(photo, captureDate: "2013:12:31 23:30:00", offset: "-07:00")
            let newer = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: photo.path)
            var date = BatchRenameRule(kind: .date)
            date.dateSource = .captured
            date.dateFormat = "yyyyMMdd-HHmm-Z"
            var options = BatchRenameOptions()
            options.rules = [date]
            let capture = try BatchRename.plan(files: [photo], options: options)
            #expect(capture.changes.map { $0.destination.lastPathComponent } == ["photo-20131231-2330--0700.jpg"])

            date.dateSource = .modified
            options.rules = [date]
            let modified = try BatchRename.plan(files: [photo], options: options)
            #expect(capture.changes[0].destination != modified.changes[0].destination)

            let noOffset = directory.appending(path: "clock.jpg")
            try writePhoto(noOffset, captureDate: "2021:03:14 02:30:00")
            date.dateSource = .captured
            date.dateFormat = "yyyyMMdd-HHmm"
            options.rules = [date]
            let localTime = try BatchRename.plan(files: [noOffset], options: options)
            #expect(localTime.changes.map { $0.destination.lastPathComponent } == ["clock-20210314-0230.jpg"])
            date.dateFormat = "yyyyMMdd-'Z'"
            options.rules = [date]
            let literal = try BatchRename.plan(files: [noOffset], options: options)
            #expect(literal.changes[0].destination.lastPathComponent == "clock-20210314-Z.jpg")
            date.dateFormat = "yyyyMMdd-Z"
            options.rules = [date]
            do {
                _ = try BatchRename.plan(files: [noOffset], options: options)
                Issue.record("Expected a missing offset error for a time-zone pattern.")
            } catch BatchRenameError.missingCaptureOffset(let name) {
                #expect(name == "clock.jpg")
            }

            let missing = try file("notes.txt", in: directory)
            do {
                _ = try BatchRename.plan(files: [photo, missing], options: options)
                Issue.record("Expected an EXIF-specific error for the unsupported file.")
            } catch BatchRenameError.missingCaptureDate(let name) {
                #expect(name == "notes.txt")
            }
            #expect(FileManager.default.fileExists(atPath: photo.path))
        }
    }

    @Test func refusesToApplyAStalePhotoDatePreviewAfterAnInPlaceEdit() throws {
        try fixture { directory in
            let source = directory.appending(path: "old.jpg")
            let replacement = directory.appending(path: "replacement.jpg")
            try writePhoto(source, captureDate: "2014:12:31 23:30:00")
            try writePhoto(replacement, captureDate: "2015:12:31 23:30:00")
            var date = BatchRenameRule(kind: .date)
            date.dateSource = .captured
            var options = BatchRenameOptions()
            options.rules = [date]
            let preview = try BatchRename.plan(files: [source], options: options)

            let file = try FileHandle(forWritingTo: source)
            try file.truncate(atOffset: 0)
            try file.write(contentsOf: Data(contentsOf: replacement))
            try file.close()
            do {
                _ = try preview.apply()
                Issue.record("The old preview must not be applied after an in-place EXIF edit.")
            } catch BatchRenameError.changedCaptureSource(let name) {
                #expect(name == "old.jpg")
            }
            #expect(!FileManager.default.fileExists(atPath: preview.changes[0].destination.path))

            let updated = try BatchRename.plan(files: [source], options: options)
            #expect(updated.changes[0].destination.lastPathComponent == "old-2015-12-31.jpg")
            let receipt = try updated.apply()
            try receipt.undo()
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func refusesStaleModificationDateButAcceptsRefreshedPreview() throws {
        try fixture { directory in
            let source = try file("report.txt", in: directory)
            let manager = FileManager.default
            let original = Date(timeIntervalSince1970: 1_700_000_000)
            try manager.setAttributes([.modificationDate: original], ofItemAtPath: source.path)
            var date = BatchRenameRule(kind: .date)
            date.dateSource = .modified
            var options = BatchRenameOptions()
            options.rules = [date]
            let preview = try BatchRename.plan(files: [source], options: options)
            try manager.setAttributes([.modificationDate: original.addingTimeInterval(86_400)], ofItemAtPath: source.path)

            do {
                _ = try preview.apply()
                Issue.record("The old preview must not be applied after a modification date change.")
            } catch BatchRenameError.changedFileDate(let name) {
                #expect(name == source.lastPathComponent)
            }
            #expect(manager.fileExists(atPath: source.path))
            #expect(!manager.fileExists(atPath: preview.changes[0].destination.path))

            let refreshed = try BatchRename.plan(files: [source], options: options)
            #expect(refreshed.changes[0].destination != preview.changes[0].destination)
            let receipt = try refreshed.apply()
            try receipt.undo()
            #expect(manager.fileExists(atPath: source.path))
        }
    }

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

            let manuallyOrderedIncludedFiles = [two, ten]
            let manual = try BatchRename.plan(files: manuallyOrderedIncludedFiles, options: options)
            #expect(manual.changes.map { $0.source.lastPathComponent } == ["File 2.txt", "File 10.txt"])
            #expect(manual.changes.map { $0.destination.lastPathComponent } == ["File 2-03.txt", "File 10-05.txt"])

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

    @Test func rejectsRepeatedSourceEvenWhenItsFirstPreviewRowDoesNotMove() throws {
        try fixture { directory in
            let source = try file("note-1.txt", in: directory)
            var replace = BatchRenameRule(kind: .replace)
            replace.search = "-1"
            var number = BatchRenameRule(kind: .number)
            number.padding = 1
            var options = BatchRenameOptions()
            options.rules = [replace, number]

            let single = try BatchRename.plan(files: [source], options: options)
            #expect(single.changes.first?.destination.lastPathComponent == "note-1.txt")
            #expect(throws: BatchRenameError.self) {
                try BatchRename.plan(files: [source, source], options: options)
            }
            let alias = directory.appendingPathComponent("NOTE-1.txt")
            if FileManager.default.fileExists(atPath: alias.path) {
                #expect(throws: BatchRenameError.self) {
                    try BatchRename.plan(files: [source, alias], options: options)
                }
            }
            #expect(try String(contentsOf: source, encoding: .utf8) == "note-1.txt")
        }
    }

    @Test func sameNamesInSeparateFoldersCanBeRenamedAndUndone() throws {
        try fixture { directory in
            let first = try file("Notes.txt", in: directory)
            let other = directory.appending(path: "Other", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            let second = other.appending(path: first.lastPathComponent)
            try Data("Second file".utf8).write(to: second)
            var rule = BatchRenameRule(kind: .replace)
            rule.search = "Notes"
            rule.replacement = "Renamed"
            var options = BatchRenameOptions()
            options.rules = [rule]

            let plan = try BatchRename.plan(files: [first, second], options: options)
            #expect(plan.changes.map(\.destination.lastPathComponent) == ["Renamed.txt", "Renamed.txt"])
            let receipt = try plan.apply()
            #expect(try plan.changes.map { try String(contentsOf: $0.destination, encoding: .utf8) }
                    == ["Notes.txt", "Second file"])
            try receipt.undo()
            #expect(try String(contentsOf: first, encoding: .utf8) == "Notes.txt")
            #expect(try String(contentsOf: second, encoding: .utf8) == "Second file")
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

    @Test(arguments: [["Σ", "ς"], ["straße", "STRASSE"]])
    func previewsUnicodeCaseFoldingCollisionsLikeTheVolume(_ equivalents: [String]) throws {
        try fixture { directory in
            let first = try file("First.txt", in: directory)
            let second = try file("Second.txt", in: directory)
            let occupied = try file(equivalents[0] + ".txt", in: directory)
            let alternate = directory.appending(path: equivalents[1] + ".txt")
            let aliases = FileManager.default.fileExists(atPath: alternate.path)
            let isCaseSensitive = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames == true
            // Different case-insensitive filesystems can use different Unicode tables.
            guard aliases || isCaseSensitive else { return }

            var rule = BatchRenameRule()
            rule.search = "First"
            rule.replacement = equivalents[1]
            var options = BatchRenameOptions()
            options.rules = [rule]
            if aliases {
                #expect(throws: BatchRenameError.self) { try BatchRename.plan(files: [first], options: options) }
            } else {
                #expect(try BatchRename.plan(files: [first], options: options).changes.first?.destination == alternate)
            }

            try FileManager.default.removeItem(at: occupied)
            rule.search = "Second"
            rule.replacement = equivalents[0]
            options.rules.append(rule)
            if aliases {
                #expect(throws: BatchRenameError.self) { try BatchRename.plan(files: [first, second], options: options) }
            } else {
                #expect(try BatchRename.plan(files: [first, second], options: options).changes.count == 2)
            }
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

    private func writePhoto(_ url: URL, captureDate: String, offset: String? = nil) throws {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var exif = [kCGImagePropertyExifDateTimeOriginal as String: captureDate]
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset }
        CGImageDestinationAddImage(output, image, [kCGImagePropertyExifDictionary as String: exif] as CFDictionary)
        try #require(CGImageDestinationFinalize(output))
    }
}

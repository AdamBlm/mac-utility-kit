import Foundation

package enum PDFCropQPDF {
    package static func write(_ source: URL, to output: URL, boxes: [(index: Int, box: CGRect)],
                              directory: URL, executable: URL? = nil) async throws {
        let paths = ["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf"]
        let candidates = [executable].compactMap { $0 } + paths.map { URL(fileURLWithPath: $0) }
        guard let executable = candidates.first(where: ExternalTool.isExecutable) else {
            throw ToolError.invalid("This version of macOS needs qpdf 11 or later to crop this PDF without changing its physical scale. Install qpdf and try again.")
        }

        let listing = directory.appendingPathComponent("Objects.json")
        try await ExternalTool.run(executable, name: "qpdf",
                                   arguments: [source.path, "--json=2", "--json-key=pages", "--json-key=qpdf",
                                               "--json-stream-data=none", listing.path],
                                   directory: directory)
        let limit = 64 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: listing)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit,
              let listingObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = listingObject["pages"] as? [[String: Any]],
              let qpdf = listingObject["qpdf"] as? [[String: Any]], qpdf.count == 2 else {
            throw ToolError.invalid("Could not read the PDF page objects for cropping.")
        }

        var updates: [String: [String: Any]] = [:]
        for item in boxes {
            try Task.checkCancellation()
            guard pages.indices.contains(item.index), let reference = pages[item.index]["object"] as? String,
                  var object = qpdf[1]["obj:" + reference] as? [String: Any],
                  var page = object["value"] as? [String: Any], page["/Type"] as? String == "/Page" else {
                throw ToolError.invalid("Could not locate the original PDF page for cropping.")
            }
            let box = item.box
            page["/CropBox"] = [box.minX, box.minY, box.maxX, box.maxY]
            object["value"] = page
            updates["obj:" + reference] = object
        }
        let patch = directory.appendingPathComponent("Crop.json")
        try JSONSerialization.data(withJSONObject: ["qpdf": [qpdf[0], updates]]).write(to: patch)
        try await ExternalTool.run(executable, name: "qpdf",
                                   arguments: [source.path, "--update-from-json=" + patch.path, output.path],
                                   directory: directory)
    }
}

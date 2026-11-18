import MapKit
import SwiftUI
import UtilityCore

struct CoordinatePickerDraft {
    var markers: [CoordinateMarker] = []
    var input = ""
    var search = ""
    var batch = ""
}

struct CoordinateMarker: Identifiable {
    let id = UUID()
    let coordinate: MapCoordinate
}

struct CoordinatePickerView: View {
    @Binding var draft: CoordinatePickerDraft
    @State private var camera = MapCameraPosition.automatic
    @State private var selectedMarker: UUID?
    @State private var issue: String?
    @State private var pendingSearch: String?
    @State private var found: [SearchResult] = []
    @State private var batchRequest: [String]?
    @State private var batchResult: [BatchResult] = []

    private struct SearchResult: Identifiable {
        let id = UUID()
        let label: String
        let point: MapCoordinate
    }

    private struct BatchResult: Identifiable {
        let id: Int
        let input: String
        let point: MapCoordinate?
        let issue: String?
    }

    var body: some View {
        InteractiveToolLayout(tool: .coordinatePicker) { palette in
            WorkspaceSection("Map", palette: palette) {
                MapReader { proxy in
                    Map(position: $camera) {
                        ForEach(Array(draft.markers.enumerated()), id: \.element.id) { index, marker in
                            Marker("Point \(index + 1)", coordinate: location(marker.coordinate))
                                .tint(marker.id == selectedMarker ? .orange : .accentColor)
                        }
                        if draft.markers.count == 2 {
                            MapPolyline(coordinates: draft.markers.map { location($0.coordinate) })
                                .stroke(.tint, lineWidth: 2)
                        }
                    }
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        guard let point = proxy.convert(tap.location, from: .local),
                              let coordinate = try? MapCoordinate(latitude: point.latitude, longitude: point.longitude) else { return }
                        place(coordinate, center: false)
                    })
                    .frame(minHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Map for placing or moving points")
                }
                HStack {
                    TextField("Search for a place", text: $draft.search)
                        .onSubmit { search() }
                    Button("Search", systemImage: "magnifyingglass", action: search)
                        .disabled(pendingSearch != nil)
                }
                ForEach(found) { result in
                    Button(result.label, systemImage: "mappin") { place(result.point) }
                        .buttonStyle(.plain)
                }
                HStack {
                    TextField("Latitude, longitude or DMS", text: $draft.input)
                        .onSubmit { enterCoordinates() }
                    Button("Set Point", action: enterCoordinates)
                }
                if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
            if !draft.markers.isEmpty {
                WorkspaceSection("Points", palette: palette) {
                    ForEach(Array(draft.markers.enumerated()), id: \.element.id) { index, marker in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Point \(index + 1)").font(.headline)
                                Text(marker.coordinate.decimal).textSelection(.enabled)
                                Text(marker.coordinate.degreesMinutesSeconds).textSelection(.enabled)
                            }
                            Spacer()
                            Menu("Point Actions", systemImage: "ellipsis.circle") {
                                Button("Move point") { selectedMarker = marker.id }
                                Button("Copy decimal") { DeveloperToolFiles.copy(marker.coordinate.decimal) }
                                Button("Copy degrees, minutes, seconds") {
                                    DeveloperToolFiles.copy(marker.coordinate.degreesMinutesSeconds)
                                }
                                Button("Remove") {
                                    draft.markers.removeAll { $0.id == marker.id }
                                    if selectedMarker == marker.id { selectedMarker = nil }
                                }
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    if selectedMarker != nil {
                        Text("Click the map or enter coordinates to move the selected point.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Cancel Move") { selectedMarker = nil }
                    }
                    if draft.markers.count == 2 {
                        let distance = draft.markers[0].coordinate.distance(to: draft.markers[1].coordinate)
                        LabeledContent("Distance", value: Measurement(value: distance, unit: UnitLength.meters).formatted())
                    }
                    Button("Clear Points", systemImage: "xmark") {
                        draft.markers.removeAll()
                        selectedMarker = nil
                    }
                }
            }
            WorkspaceSection("List Lookup", palette: palette) {
                TextEditor(text: $draft.batch)
                    .frame(minHeight: 72)
                    .accessibilityLabel("Coordinates or place names, one per line")
                Button("Look Up List", systemImage: "list.bullet") { startBatch() }
                    .disabled(batchRequest != nil)
                if batchRequest != nil {
                    Button("Cancel Lookup") { batchRequest = nil }
                }
                ForEach(batchResult) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.input)
                            Text(row.point?.decimal ?? row.issue ?? "No matching place")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let point = row.point {
                            Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(point.decimal) }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
        .task(id: pendingSearch) {
            guard let term = pendingSearch else { return }
            await runSearch(term)
        }
        .task(id: batchRequest) {
            guard let batchRequest else { return }
            await runBatch(batchRequest)
        }
        .onChange(of: draft.search) {
            pendingSearch = nil
            found.removeAll()
        }
        .onDisappear {
            pendingSearch = nil
            batchRequest = nil
        }
    }

    private func location(_ point: MapCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func enterCoordinates() {
        do {
            place(try MapCoordinate.parse(draft.input))
        } catch {
            issue = error.localizedDescription
        }
    }

    private func place(_ point: MapCoordinate, center: Bool = true) {
        let marker = CoordinateMarker(coordinate: point)
        if let index = draft.markers.firstIndex(where: { $0.id == selectedMarker }) {
            draft.markers[index] = marker
        } else if draft.markers.count < 2 {
            draft.markers.append(marker)
        } else {
            issue = "Choose a point to move or clear a point before placing another."
            return
        }
        if center {
            camera = .region(region(around: point))
        }
        selectedMarker = nil
        issue = nil
    }

    private func region(around point: MapCoordinate) -> MKCoordinateRegion {
        guard draft.markers.count == 2 else {
            return MKCoordinateRegion(center: location(point), latitudinalMeters: 1000, longitudinalMeters: 1000)
        }
        let first = draft.markers[0].coordinate
        let second = draft.markers[1].coordinate
        var delta = second.longitude - first.longitude
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var longitude = first.longitude + delta / 2
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let center = CLLocationCoordinate2D(latitude: (first.latitude + second.latitude) / 2, longitude: longitude)
        let span = MKCoordinateSpan(
            latitudeDelta: min(170, max(0.015, abs(second.latitude - first.latitude) * 1.4)),
            longitudeDelta: min(360, max(0.015, abs(delta) * 1.4))
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private func search() {
        let term = draft.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf8.count <= 512 else {
            issue = "Enter a place name or address up to 512 bytes."
            return
        }
        pendingSearch = term
        found = []
        issue = nil
    }

    private func runSearch(_ term: String) async {
        do {
            let matches = try await lookup(term)
            guard !Task.isCancelled, pendingSearch == term else { return }
            found = matches
            if matches.isEmpty { issue = "No matching places." }
        } catch {
            guard !Task.isCancelled, pendingSearch == term else { return }
            issue = "Map search is unavailable. You can still enter coordinates."
        }
        if pendingSearch == term { pendingSearch = nil }
    }

    private func startBatch() {
        let lines = draft.batch.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 20, lines.allSatisfy({ $0.utf8.count <= 512 }) else {
            issue = "Enter up to 20 coordinates or place names, one per line."
            return
        }
        issue = nil
        batchResult = []
        batchRequest = lines
    }

    private func runBatch(_ request: [String]) async {
        for (index, line) in request.enumerated() {
            guard !Task.isCancelled, batchRequest == request else { return }
            let row: BatchResult
            if let coordinate = try? MapCoordinate.parse(line) {
                row = BatchResult(id: index, input: line, point: coordinate, issue: nil)
            } else if line.contains("°") || line.wholeMatch(of: /[+−\-]?[0-9.]+\s*[,; ]\s*[+−\-]?[0-9.]+/) != nil {
                row = BatchResult(id: index, input: line, point: nil, issue: "Invalid latitude or longitude")
            } else {
                do {
                    let matches = try await lookup(line)
                    row = BatchResult(id: index, input: line, point: matches.first?.point, issue: nil)
                } catch {
                    row = BatchResult(id: index, input: line, point: nil, issue: "Map search unavailable")
                }
            }
            guard !Task.isCancelled, batchRequest == request else { return }
            batchResult.append(row)
        }
        if batchRequest == request { batchRequest = nil }
    }

    private func lookup(_ term: String) async throws -> [SearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        let lookup = MKLocalSearch(request: request)
        let response = try await lookup.start()
        try Task.checkCancellation()
        return response.mapItems.prefix(8).compactMap { item in
            let coordinate: CLLocationCoordinate2D
            if #available(macOS 26.0, *) { coordinate = item.location.coordinate }
            else { coordinate = item.placemark.coordinate }
            guard let point = try? MapCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else { return nil }
            return SearchResult(label: item.name ?? point.decimal, point: point)
        }
    }
}

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

private struct CoordinatePlaceResult: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let point: MapCoordinate
}


struct CoordinatePickerView: View {
    @Binding var draft: CoordinatePickerDraft
    @State private var camera = MapCameraPosition.automatic
    @State private var selectedMarker: UUID?
    @State private var issue: String?
    @State private var pendingSearch: String?
    @State private var found: [CoordinatePlaceResult] = []
    @State private var batchRequest: BatchRequest?
    @State private var batchTask: Task<Void, Never>?
    @State private var batchResult: [CoordinateBatchLookup.Row] = []
    @State private var batchIssue: String?

    private struct BatchRequest {
        let id = UUID()
        let entries: [CoordinateBatchLookup.Entry]
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
                    TextField("Latitude and longitude", text: $draft.input)
                        .help("Decimal degrees, degrees and decimal minutes, or degrees, minutes, and seconds")
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
                    .disabled(batchRequest != nil)
                Button("Look Up List", systemImage: "list.bullet") { startBatch() }
                    .disabled(batchRequest != nil)
                if batchRequest != nil {
                    Button("Cancel Lookup") { batchTask?.cancel() }
                        .disabled(batchTask?.isCancelled == true)
                }
                if let batchIssue { Text(batchIssue).font(.callout).foregroundStyle(.secondary) }
                ForEach(batchResult) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Line \(row.line) · \(row.input)").lineLimit(2)
                            switch row.outcome {
                            case .accepted(let point):
                                Text(point.decimal).font(.callout).foregroundStyle(.secondary)
                            case .rejected(let reason):
                                Text(reason.rawValue).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if case .accepted(let point) = row.outcome {
                            Button("Copy coordinates on line \(row.line)", systemImage: "doc.on.doc") {
                                DeveloperToolFiles.copy(point.decimal)
                            }
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
        .onChange(of: draft.batch) {
            batchResult.removeAll()
            batchIssue = nil
        }
        .onChange(of: draft.search) {
            pendingSearch = nil
            found.removeAll()
        }
        .onDisappear {
            pendingSearch = nil
            batchTask?.cancel()
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
        guard batchTask == nil else { return }
        batchResult = []
        batchIssue = nil
        do {
            let request = BatchRequest(entries: try CoordinateBatchLookup.prepare(draft.batch))
            batchRequest = request
            batchTask = Task { await runBatch(request) }
        } catch {
            batchIssue = error.localizedDescription
        }
    }

    private func runBatch(_ request: BatchRequest) async {
        defer {
            if batchRequest?.id == request.id {
                batchRequest = nil
                batchTask = nil
            }
        }
        for entry in request.entries {
            guard batchRequest?.id == request.id, !Task.isCancelled else { return }
            do {
                let row = try await CoordinateBatchLookup.resolve(entry) { term in
                    do {
                        return try await lookup(term).first?.point
                    } catch let error as MKError where error.code == .placemarkNotFound {
                        return nil
                    }
                }
                guard batchRequest?.id == request.id, !Task.isCancelled else { return }
                batchResult.append(row)
            } catch {
                return
            }
        }
    }

    private func lookup(_ term: String) async throws -> [CoordinatePlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        let lookup = NativeMapSearch(request: request)
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await lookup.start()
        } onCancel: {
            Task { @MainActor in lookup.cancel() }
        }
        try Task.checkCancellation()
        return response
    }
}

@MainActor
private final class NativeMapSearch {
    private let search: MKLocalSearch
    private var pending: CheckedContinuation<[CoordinatePlaceResult], any Error>?

    init(request: MKLocalSearch.Request) {
        search = MKLocalSearch(request: request)
    }

    func start() async throws -> [CoordinatePlaceResult] {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            search.start { [weak self] response, error in
                guard let self, let pending else { return }
                self.pending = nil
                if let response {
                    let results: [CoordinatePlaceResult] = response.mapItems.prefix(8).compactMap { item in
                        let coordinate: CLLocationCoordinate2D
                        if #available(macOS 26.0, *) { coordinate = item.location.coordinate }
                        else { coordinate = item.placemark.coordinate }
                        guard let point = try? MapCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else { return nil }
                        return CoordinatePlaceResult(label: item.name ?? point.decimal, point: point)
                    }
                    pending.resume(returning: results)
                } else {
                    pending.resume(throwing: error ?? ToolError.invalid("No search response was returned."))
                }
            }
        }
    }

    func cancel() {
        let continuation = pending
        pending = nil
        search.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

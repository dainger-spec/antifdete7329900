import MapKit
import SwiftUI

/// The profile's fixed geolocation, picked as a person would pick a place: an address typed with
/// suggestions as it is written, a point on a map that a click moves, the proxy's city in one
/// press, and the accuracy a page is told, drawn as a circle around the point. It edits the draft's
/// text fields, so the numbers below the map and the map always say the same.
///
/// The search and the map's tiles are Apple Maps, asked from this Mac — the app's own process, not
/// the profile's, and not through the profile's proxy (said under the map).
struct LocationPicker: View {
    @Binding var latitude: String
    @Binding var longitude: String
    @Binding var accuracy: String
    /// "City, Country" of where the profile's proxy exits, when a check said; nil otherwise.
    var proxyPlace: String?

    @StateObject private var search = PlaceSearch()
    @State private var query = ""
    @State private var camera: MapCameraPosition = .automatic
    @State private var placeName: String?
    @State private var notFound = false
    @State private var resolving = false

    static let accuracyRange: ClosedRange<Double> = 5...500

    private var coordinate: CLLocationCoordinate2D? {
        func number(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        guard let lat = number(latitude), let lon = number(longitude),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private var accuracyMeters: Double {
        let value = Double(accuracy.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 50
        return min(max(value, Self.accuracyRange.lowerBound), Self.accuracyRange.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LumenSearchField(text: $query, prompt: L("editor.geo.search"))
                    .onChange(of: query) { search.update(query); notFound = false }
                    .onSubmit { Task { await resolveTyped() } }
                Button {
                    Task { await resolveProxyCity() }
                } label: {
                    Label(L("editor.geo.proxyCity"), systemImage: "location.viewfinder")
                }
                .buttonStyle(.lumenSecondary)
                .fixedSize()
                .disabled(proxyPlace == nil || resolving)
                .help(proxyPlace.map { String(format: L("editor.geo.proxyCity.help"), $0) } ?? L("editor.geo.proxyCity.unknown"))
            }
            if !search.suggestions.isEmpty && !query.isEmpty {
                suggestions
            }
            if notFound {
                Text(L("editor.geo.notFound")).font(.lumenSecondary).foregroundStyle(Theme.warning)
            }
            map
            HStack(spacing: 10) {
                Text(L("editor.geo.accuracy")).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                Slider(value: accuracyBinding, in: Self.accuracyRange).controlSize(.small)
                Text(verbatim: String(format: L("editor.geo.accuracy.value"), Int(accuracyMeters.rounded())))
                    .font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .onAppear {
            if let coordinate { show(coordinate) }
            // A new point with nothing set yet: where the proxy exits, when that is known.
            else if proxyPlace != nil { Task { await resolveProxyCity() } }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(search.suggestions.enumerated()), id: \.offset) { _, suggestion in
                Button {
                    Task { await choose(suggestion) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title).font(.lumenBody).foregroundStyle(Theme.textPrimary)
                        if !suggestion.subtitle.isEmpty {
                            Text(suggestion.subtitle).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.raisedInset))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).stroke(Theme.fieldBorder, lineWidth: 1))
    }

    /// The map in the app's own dark look: Apple Maps' dark, muted standard style with no points of
    /// interest, our own point — a light dot in a soft halo — and the accuracy as a faint ring,
    /// captions on the app's dark chips.
    private var map: some View {
        MapReader { reader in
            Map(position: $camera) {
                if let coordinate {
                    MapCircle(center: coordinate, radius: accuracyMeters)
                        .foregroundStyle(Theme.accent.opacity(0.08))
                        .stroke(Theme.accent.opacity(0.45), lineWidth: 1)
                    Annotation(placeName ?? L("editor.geo.point"), coordinate: coordinate, anchor: .center) {
                        LocationDot()
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls { MapZoomStepper(); MapCompass() }
            .environment(\.colorScheme, .dark)
            .onTapGesture { point in
                guard let picked = reader.convert(point, from: .local) else { return }
                set(picked, name: nil, recenter: false)
            }
        }
        .frame(height: 280)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if let caption = placeCaption {
                MapChip(systemImage: "mappin.and.ellipse", text: caption, strong: true)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            MapChip(systemImage: "cursorarrow.click", text: L("editor.geo.map.hint"), strong: false)
                .padding(10)
                .allowsHitTesting(false)
        }
        .overlay {
            if resolving {
                ProgressView().controlSize(.small)
                    .padding(10)
                    .background(Circle().fill(Theme.raised.opacity(0.9)))
            }
        }
    }

    /// What the chip on the map says: the place's name, else the coordinates.
    private var placeCaption: String? {
        guard let coordinate else { return nil }
        if let placeName, !placeName.isEmpty { return placeName }
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    private var accuracyBinding: Binding<Double> {
        Binding(get: { accuracyMeters }, set: { accuracy = String(Int($0.rounded())) })
    }

    // MARK: Actions

    private func set(_ picked: CLLocationCoordinate2D, name: String?, recenter: Bool) {
        latitude = String(format: "%.6f", picked.latitude)
        longitude = String(format: "%.6f", picked.longitude)
        placeName = name
        notFound = false
        if recenter { show(picked) }
    }

    private func show(_ point: CLLocationCoordinate2D) {
        let span = max(accuracyMeters * 12, 1500)
        camera = .region(MKCoordinateRegion(center: point, latitudinalMeters: span, longitudinalMeters: span))
    }

    private func choose(_ suggestion: MKLocalSearchCompletion) async {
        resolving = true
        defer { resolving = false }
        guard let found = await search.resolve(suggestion) else { notFound = true; return }
        query = ""
        search.update("")
        set(found.coordinate, name: found.name, recenter: true)
    }

    private func resolveTyped() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        resolving = true
        defer { resolving = false }
        guard let found = await search.resolve(text: text) else { notFound = true; return }
        query = ""
        search.update("")
        set(found.coordinate, name: found.name, recenter: true)
    }

    private func resolveProxyCity() async {
        guard let proxyPlace else { return }
        resolving = true
        defer { resolving = false }
        guard let found = await search.resolve(text: proxyPlace) else { notFound = true; return }
        set(found.coordinate, name: found.name, recenter: true)
    }
}

/// Apple Maps' suggestions as an address is typed, and a place for a suggestion or a text.
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    struct Place {
        var coordinate: CLLocationCoordinate2D
        var name: String?
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            completer.cancel()
            suggestions = []
        } else {
            completer.queryFragment = text
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = Array(completer.results.prefix(6))
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }

    func resolve(_ suggestion: MKLocalSearchCompletion) async -> Place? {
        await run(MKLocalSearch.Request(completion: suggestion), fallbackName: suggestion.title)
    }

    func resolve(text: String) async -> Place? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        return await run(request, fallbackName: text)
    }

    private func run(_ request: MKLocalSearch.Request, fallbackName: String) async -> Place? {
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return Place(coordinate: item.placemark.coordinate, name: item.name ?? fallbackName)
    }
}

/// The profile's point on the map: a light dot, ringed in the map's dark, in a soft halo.
private struct LocationDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.16)).frame(width: 36, height: 36)
            Circle().fill(Theme.accent).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Theme.backdrop, lineWidth: 3))
                .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A caption on the map, on the app's dark chip.
private struct MapChip: View {
    let systemImage: String
    let text: String
    var strong: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: strong ? .medium : .regular))
        .foregroundStyle(strong ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.raised.opacity(0.92)))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

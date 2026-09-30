import CoreLocation
import MapKit
import SwiftUI

struct StationDetailView: View {
    @Environment(AppModel.self) private var model
    let station: APRSStation
    let from: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: station.coordinate, latitudinalMeters: 3_000, longitudinalMeters: 3_000))) {
                        Annotation(station.callsign, coordinate: station.coordinate, anchor: .bottom) {
                            APRSSymbolMapMarker(
                                symbol: station.symbolSelection,
                                overlay: station.symbolOverlay,
                                callsign: station.callsign,
                                isActive: false
                            )
                        }
                    }
                    .frame(height: 170)
                    .listRowInsets(EdgeInsets())
                }
                Section("Station") {
                    LabeledContent("Last heard", value: station.lastHeard.relativeLabel)
                    if !station.comment.isEmpty { LabeledContent("Comment", value: station.comment) }
                    if let equipment = station.equipment { LabeledContent("Equipment", value: equipment) }
                    if let from { LabeledContent("Distance", value: distance(from: from)) }
                    if let speed = station.speedMetersPerSecond {
                        LabeledContent("Speed", value: model.settings.display.speedUnit == .mph
                            ? String(format: "%.0f mph", speed * 2.23694)
                            : String(format: "%.0f km/h", speed * 3.6))
                    }
                    if let course = station.course { LabeledContent("Course", value: String(format: "%.0f°", course)) }
                    if let altitude = station.altitudeMeters {
                        LabeledContent("Altitude", value: model.settings.display.distanceUnit == .miles
                            ? String(format: "%.0f ft", altitude * 3.28084)
                            : String(format: "%.0f m", altitude))
                    }
                }
                if station.equipment != nil {
                    Section {
                        Text("Equipment identification uses the APRS Device ID registry maintained by aprsorg.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(station.callsign)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func distance(from origin: CLLocationCoordinate2D) -> String {
        let first = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let second = CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude)
        let meters = first.distance(from: second)
        return model.settings.display.distanceUnit == .miles
            ? String(format: "%.1f mi", meters / 1_609.344)
            : String(format: "%.1f km", meters / 1_000)
    }
}

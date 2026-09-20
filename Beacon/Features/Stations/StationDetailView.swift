import CoreLocation
import MapKit
import SwiftUI

struct StationDetailView: View {
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
                    if let speed = station.speedMetersPerSecond { LabeledContent("Speed", value: String(format: "%.0f mph", speed * 2.23694)) }
                    if let course = station.course { LabeledContent("Course", value: String(format: "%.0f°", course)) }
                    if let altitude = station.altitudeMeters { LabeledContent("Altitude", value: String(format: "%.0f ft", altitude * 3.28084)) }
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
        return String(format: "%.1f mi", first.distance(from: second) / 1_609.344)
    }
}

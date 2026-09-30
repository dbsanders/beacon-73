import SwiftUI

struct StationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(receiveRadiusDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                if model.nearbyStations.isEmpty {
                    ContentUnavailableView(
                        "No Nearby Stations",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text(emptyStateDescription)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.nearbyStations) { station in
                        NavigationLink {
                            StationDetailView(station: station, from: model.displayCoordinate)
                        } label: {
                            HStack(spacing: 12) {
                                APRSSymbolIcon(
                                    symbol: station.symbolSelection,
                                    size: 34,
                                    overlay: station.symbolOverlay
                                )
                                    .frame(width: 38, height: 38)
                                    .background(.blue.opacity(0.14), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(station.callsign).font(.headline.monospaced())
                                    Text(station.comment.isEmpty ? (station.equipment ?? "APRS station") : station.comment)
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(station.lastHeard.relativeLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Nearby Stations")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var receiveRadiusDescription: String {
        "Stations within \(formattedReceiveRadius) of your location"
    }

    private var formattedReceiveRadius: String {
        let unit = model.settings.display.distanceUnit == .miles ? "miles" : "km"
        return "\(model.settings.receiveRadius) \(unit)"
    }

    private var emptyStateDescription: String {
        if !model.settings.identity.isReady {
            return "Add your call sign and APRS-IS passcode in Settings to receive nearby stations."
        }
        if !model.connectionState.isConnected {
            return "Waiting for APRS-IS. Nearby stations will appear after GPS and the server connect."
        }
        if model.receivedPacketCount == 0 {
            return "Ready, but no APRS-IS packets have arrived yet. The app will reconnect automatically if the stream drops."
        }
        return "Received \(model.receivedPacketCount) APRS packets; \(model.unsupportedPacketCount) did not contain a supported position. No decoded stations are currently within \(formattedReceiveRadius)."
    }
}

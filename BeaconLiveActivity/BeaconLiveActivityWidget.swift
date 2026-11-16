import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BeaconLiveActivityWidgets: WidgetBundle {
    var body: some Widget {
        BeaconLiveActivityWidget()
    }
}

struct BeaconLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BeaconActivityAttributes.self) { context in
            lockScreenView(for: context.state)
                .activityBackgroundTint(.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "beacon73://beaconing"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Beaconing", systemImage: "paperplane.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    nextBeaconView(for: context.state, compact: false)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(context.state.callsign)
                                .font(.headline.monospaced())
                            connectionView(for: context.state)
                        }
                        Spacer()
                        lastBeaconView(for: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                nextBeaconView(for: context.state, compact: true)
            } minimal: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.orange)
            }
            .keylineTint(.orange)
            .widgetURL(URL(string: "beacon73://beaconing"))
        }
    }

    private func lockScreenView(for state: BeaconActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Auto-beaconing is ON", systemImage: "paperplane.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                connectionView(for: state)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(state.callsign)
                    .font(.title2.bold().monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                nextBeaconView(for: state, compact: false)
            }

            HStack {
                lastBeaconView(for: state)
                Spacer()
                Text("Open Beacon 73 to stop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func connectionView(for state: BeaconActivityAttributes.ContentState) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.isConnected ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(connectionLabel(for: state.connectionStatus))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }

    private func connectionLabel(for status: BeaconActivityAttributes.ConnectionStatus) -> LocalizedStringKey {
        switch status {
        case .online: "Online"
        case .verifying: "Verifying"
        case .passcodeIssue: "Passcode issue"
        case .connectionIssue: "Connection issue"
        case .connecting: "Connecting"
        case .offline: "Offline"
        case .stopped: "Stopped"
        }
    }

    @ViewBuilder
    private func nextBeaconView(
        for state: BeaconActivityAttributes.ContentState,
        compact: Bool
    ) -> some View {
        if let nextBeaconAt = state.nextBeaconAt, nextBeaconAt > .now {
            VStack(alignment: .trailing, spacing: 1) {
                if !compact {
                    Text("Next beacon")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(timerInterval: Date.now...nextBeaconAt, countsDown: true)
                    .font(compact ? .caption.monospacedDigit() : .headline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        } else {
            Text(compact ? "…" : "Waiting for GPS")
                .font(compact ? .caption : .caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lastBeaconView(for state: BeaconActivityAttributes.ContentState) -> some View {
        if let lastBeaconAt = state.lastBeaconAt {
            HStack(spacing: 4) {
                Text("Last")
                    .foregroundStyle(.secondary)
                Text(lastBeaconAt, style: .relative)
            }
            .font(.caption)
        } else {
            Text("No beacon sent yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

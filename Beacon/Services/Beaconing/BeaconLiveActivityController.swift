@preconcurrency import ActivityKit
import Foundation

@MainActor
final class BeaconLiveActivityController {
    private var activity: Activity<BeaconActivityAttributes>?
    private var lastState: BeaconActivityAttributes.ContentState?

    func start(with state: BeaconActivityAttributes.ContentState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let current = activity ?? Activity<BeaconActivityAttributes>.activities.first {
            activity = current
            await update(with: state)
            return
        }

        do {
            activity = try Activity.request(
                attributes: BeaconActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
        } catch {
            // A Live Activity is a convenience; beaconing must continue if iOS declines it.
        }
    }

    func update(with state: BeaconActivityAttributes.ContentState) async {
        guard state != lastState,
              let current = activity ?? Activity<BeaconActivityAttributes>.activities.first else { return }
        activity = current
        await current.update(ActivityContent(state: state, staleDate: nil))
        lastState = state
    }

    func end(with state: BeaconActivityAttributes.ContentState) async {
        var currentActivities = Activity<BeaconActivityAttributes>.activities
        if let activity, !currentActivities.contains(where: { $0.id == activity.id }) {
            currentActivities.append(activity)
        }

        guard !currentActivities.isEmpty else {
            lastState = nil
            return
        }

        for current in currentActivities {
            await current.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        activity = nil
        lastState = nil
    }
}

import Foundation

/// DAT 1.0.x can silently finish a run after about one minute. Renew only the
/// existing Speech instance; each stop/start is bounded by its adapter deadlines.
/// https://github.com/meta/meta-wearables-dat-ios/issues/360#issuecomment-6352117482
struct SpeechRunLifecycle {
    var renewalInterval: Duration = .seconds(50)
    var utteranceGrace: Duration = .seconds(5)
    var pollingInterval: Duration = .milliseconds(100)
    private var unexpectedStops: [Date] = []

    init(renewalInterval: Duration = .seconds(50), utteranceGrace: Duration = .seconds(5), pollingInterval: Duration = .milliseconds(100)) {
        self.renewalInterval = renewalInterval; self.utteranceGrace = utteranceGrace; self.pollingInterval = pollingInterval
    }

    mutating func allowUnexpectedRestart(now: Date = Date()) -> Bool {
        unexpectedStops.removeAll { now.timeIntervalSince($0) >= 60 }
        guard unexpectedStops.count < 2 else { return false }
        unexpectedStops.append(now)
        return true
    }
    mutating func reset() { unexpectedStops = [] }
}

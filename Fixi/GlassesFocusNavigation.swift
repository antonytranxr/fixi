import Foundation

/// DAT's native focus engine owns gestures in the shipping experience. The
/// experimental Inputs path requires a whole display transfer for every move
/// and has no public API to restore native focus after that transfer.
enum GlassesNavigationPolicy {
    static let usesRawInputs = false

    static func preferredFooterID(itemIDs: [String], footerIDs: [String], preferredID: String?) -> String? {
        // A footer default steals initial selection from the first list row.
        guard itemIDs.isEmpty else { return nil }
        return preferredID.flatMap { footerIDs.contains($0) ? $0 : nil } ?? footerIDs.first
    }
}

/// Only visible content and active handlers determine whether the native view
/// needs replacement. Hidden camera/voice updates must not reset native focus.
/// Images use reference identity, avoiding image encoding on status callbacks.
struct GlassesDisplayContent: Equatable {
    struct Control: Equatable {
        let id: String
        let label: String
    }

    let title: String
    let text: String
    let imageIdentity: ObjectIdentifier?
    let items: [Control]
    let footer: [Control]
    let staticRows: [String]
    let usesCustomActions: Bool
    let usesRawInputs: Bool
    let preferredActionID: String?
}

/// App-owned focus for DAT Inputs. A horizontal gesture past the final control
/// navigates screens; vertical gestures stay within the visible control list.
struct GlassesFocusNavigation {
    enum Direction { case left, right, up, down }
    enum Result: Equatable {
        case focused(String)
        case boundary(forward: Bool)
        case unchanged
    }

    private(set) var actionIDs: [String] = []
    private(set) var focusedID: String?

    mutating func reset(itemIDs: [String], footerIDs: [String], preferredID: String?) {
        var seen = Set<String>()
        actionIDs = (itemIDs + footerIDs).filter { seen.insert($0).inserted }
        focusedID = preferredID.flatMap { actionIDs.contains($0) ? $0 : nil }
            ?? itemIDs.first ?? footerIDs.first
    }

    mutating func move(_ direction: Direction) -> Result {
        guard let focusedID, let index = actionIDs.firstIndex(of: focusedID) else { return .unchanged }
        let forward = direction == .right || direction == .down
        let next = index + (forward ? 1 : -1)
        guard actionIDs.indices.contains(next) else {
            return direction == .left || direction == .right ? .boundary(forward: forward) : .unchanged
        }
        self.focusedID = actionIDs[next]
        return .focused(actionIDs[next])
    }
}

/// Device timestamps are monotonic within a boot, not comparable with Date.
/// Advance the watermark even when a card is in flight so dropped input cannot
/// be replayed after the replacement card is acknowledged.
struct GlassesInputSequence {
    private(set) var latestTimestampMs: Int64?

    mutating func observe(_ timestampMs: Int64) -> Bool {
        guard latestTimestampMs.map({ timestampMs > $0 }) ?? true else { return false }
        latestTimestampMs = timestampMs
        return true
    }
}

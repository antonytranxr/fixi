import Foundation

/// Layout choice only. Repair state, credentials, and voice ownership are shared.
enum MendExperience: String, CaseIterable, Identifiable {
    case focus, flow, guide
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var principle: String {
        switch self {
        case .focus: return "One thing at a time"
        case .flow: return "Talk it through"
        case .guide: return "See the whole plan"
        }
    }
    var symbol: String {
        switch self {
        case .focus: return "viewfinder"
        case .flow: return "bubble.left.and.bubble.right"
        case .guide: return "checklist"
        }
    }
}

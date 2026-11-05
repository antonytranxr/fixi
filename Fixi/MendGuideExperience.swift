import SwiftUI

/// A quiet workbench with the route and the whole checklist always readable.
struct MendGuideExperience: View {
    @Bindable var model: FixiModel
    private let accent = MendTheme.blue
    private let secondaryInk = MendTheme.muted
    private var parts: MendExperienceParts { MendExperienceParts(model: model, accent: accent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            if model.stage != .welcome { route }
            switch model.stage {
            case .welcome:
                VStack(alignment: .leading, spacing: 24) {
                    FixiWelcomeBrand().padding(.top, 30).padding(.bottom, 10)
                    Text("What should we work on today?").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("Show me the project. We’ll make a plan.").font(.body).foregroundStyle(secondaryInk)
                    parts.composer
                }
            case .capture:
                heading("Let’s take a look.", note: "Show me the project and tell me what’s happening.")
                parts.photo(maxHeight: 200)
                parts.composer
                if let prompt = model.setupPrompt, !prompt.isEmpty { Text(prompt).font(.subheadline).foregroundStyle(accent) }
                ruledSection("PROJECT DETAILS") { parts.projectFields }
            case .confirmation:
                heading("Check the details.", note: "Correct anything before we begin.")
                parts.photo(maxHeight: 170)
                ruledSection("YOUR PROJECT") { parts.projectSummary }
            case .parts:
                heading("Get set up.", note: "Tools and parts for this repair.")
                ruledSection("WHAT YOU’LL NEED") { parts.partsKit }
            case .diagnosis:
                if let diagnosis = model.diagnosis {
                    heading(diagnosis.status == .ready ? "Your checklist" : diagnosis.status == .stop ? "Pause here." : "One more detail.", note: diagnosis.status == .ready ? "Open any step." : diagnosis.title)
                    if diagnosis.status == .ready {
                        parts.progress
                        ruledSection("REPAIR STEPS") { parts.checklist }
                    } else {
                        Text(diagnosis.summary).font(.body).lineSpacing(3)
                        ForEach(diagnosis.questions, id: \.self) { Text($0).font(.subheadline).foregroundStyle(accent) }
                    }
                    parts.cautions
                }
            case .guide:
                if let step = model.currentStep, let diagnosis = model.diagnosis {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack(alignment: .top, spacing: 14) {
                            Text(String(format: "%02d", model.stepIndex + 1)).font(.system(size: 38, weight: .light, design: .monospaced)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("STEP \(model.stepIndex + 1) OF \(diagnosis.steps.count)").font(.caption2.monospaced()).foregroundStyle(secondaryInk)
                                Text(step.title).font(.title2.weight(.semibold))
                            }
                        }
                        parts.photo(maxHeight: 240)
                        ruledSection("DO THIS") { parts.stepText }
                    }
                }
            case .complete:
                Image(systemName: "checklist").font(.system(size: 44, weight: .light)).foregroundStyle(accent).padding(.top, 20)
                heading("Checklist complete.", note: "Give the repair a final check.")
                parts.progress
                ruledSection("YOUR STEPS") { parts.checklist }
            }
        }.tint(accent)
    }
    private var location: Int {
        switch model.stage {
        case .welcome, .capture, .confirmation: 0
        case .parts: 1
        case .diagnosis, .guide: 2
        case .complete: 3
        }
    }
    private var route: some View {
        HStack(spacing: 9) {
            ForEach(Array(["SETUP", "PARTS", "STEPS"].enumerated()), id: \.offset) { index, label in
                HStack(spacing: 5) {
                    if index < location { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    else { Text(String(index + 1)).font(.system(size: 10, weight: .semibold, design: .monospaced)) }
                    Text(label).font(.system(size: 10, weight: index == location ? .bold : .medium, design: .monospaced))
                }.foregroundStyle(index == location ? accent : secondaryInk)
                    .accessibilityLabel(label + (index == location ? ", current" : index < location ? ", complete" : ""))
                if index < 2 { Rectangle().fill(secondaryInk.opacity(0.3)).frame(maxWidth: 18).frame(height: 1) }
            }
            Spacer(minLength: 0)
        }
    }
    private func heading(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 29, weight: .semibold, design: .rounded))
            Text(note).font(.subheadline).foregroundStyle(secondaryInk)
        }
    }
    private func ruledSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(secondaryInk)
            content()
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).fixiGlass()
    }
}

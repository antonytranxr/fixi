import SwiftUI

/// Conversational headings and tonal groups over the same repair state.
struct MendFlowExperience: View {
    @Bindable var model: FixiModel
    private let accent = MendTheme.violet
    private let secondaryText = MendTheme.muted
    private var parts: MendExperienceParts { MendExperienceParts(model: model, accent: accent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.stage != .welcome { stageRail }
            switch model.stage {
            case .welcome:
                VStack(alignment: .leading, spacing: 24) {
                    FixiWelcomeBrand().padding(.top, 30).padding(.bottom, 10)
                    Text("What should we work on today?").font(.system(size: 32, weight: .medium, design: .rounded))
                    Text("Show me or tell me. We’ll figure it out together.").font(.body).foregroundStyle(secondaryText)
                    parts.composer
                }
            case .capture:
                prompt("Tell me a little more.", subtitle: "A photo, a few words, or both.")
                parts.photo(maxHeight: 200)
                parts.composer
                if let question = model.setupPrompt, !question.isEmpty {
                    Text(question).font(.subheadline).foregroundStyle(accent)
                }
                surface { parts.projectFields }
            case .confirmation:
                prompt("Here’s what I heard.", subtitle: "Does this look right?")
                parts.photo(maxHeight: 170)
                surface { parts.projectSummary }
            case .parts:
                prompt("Let’s get ready.", subtitle: "Gather your tools and parts.")
                surface { parts.partsKit }
            case .diagnosis:
                if let plan = model.diagnosis {
                    prompt(plan.status == .ready ? "Here’s the plan." : plan.status == .stop ? "Let’s pause here." : "One more thing…", subtitle: plan.status == .ready ? "Open any step." : plan.title)
                    if plan.status == .ready {
                        parts.progress
                        surface { parts.checklist }
                    } else {
                        surface {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(plan.summary).font(.body)
                                ForEach(plan.questions, id: \.self) { Text($0).font(.subheadline).foregroundStyle(accent) }
                            }
                        }
                    }
                    parts.cautions
                }
            case .guide:
                if let step = model.currentStep, let plan = model.diagnosis {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("STEP \(model.stepIndex + 1) OF \(plan.steps.count)").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(accent)
                        Text(step.title).font(.system(size: 29, weight: .medium, design: .rounded))
                        parts.photo(maxHeight: 230)
                        surface { VStack(alignment: .leading, spacing: 13) { parts.stepText } }
                    }
                }
            case .complete:
                Image(systemName: "checkmark.seal").font(.system(size: 48, weight: .light)).foregroundStyle(accent).padding(.top, 20)
                prompt("How does it look?", subtitle: "Give the repair a final check.")
                parts.progress
                surface { parts.checklist }
            }
        }.tint(accent)
    }
    private var phase: Int {
        switch model.stage {
        case .welcome, .capture, .confirmation: 0
        case .parts: 1
        case .diagnosis, .guide: 2
        case .complete: 3
        }
    }
    private var stageRail: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                if index > 0 { Capsule().fill(accent.opacity(index <= phase ? 0.65 : 0.14)).frame(height: 2) }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(accent.opacity(index == phase ? 1 : 0.13))
                        if index < phase { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(accent) }
                        else { Text("\(index + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(index == phase ? Color.black : secondaryText) }
                    }.frame(width: 23, height: 23)
                    Text(["Describe", "Prepare", "Fix"][index]).font(.caption.weight(index == phase ? .semibold : .regular)).foregroundStyle(index == phase ? accent : secondaryText)
                }.fixedSize()
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(phase == 3 ? "Repair steps complete" : "Phase \(phase + 1) of 3: \(["Describe", "Prepare", "Fix"][min(phase, 2)])")
    }
    private func prompt(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 29, weight: .medium, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(secondaryText)
        }
    }
    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .fixiGlass(radius: 24)
    }
}

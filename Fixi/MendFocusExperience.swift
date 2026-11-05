import SwiftUI

/// A single conversational prompt, then one clear task at a time.
struct MendFocusExperience: View {
    @Bindable var model: FixiModel
    private var parts: MendExperienceParts { MendExperienceParts(model: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: model.stage == .guide ? 16 : 24) {
            switch model.stage {
            case .welcome:
                VStack(spacing: 22) {
                    FixiWelcomeBrand().padding(.top, 30).padding(.bottom, 10)
                    Text("What should we work on today?").font(.system(size: 32, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                    Text("Show me your project. We’ll take it step by step.").font(.body).foregroundStyle(MendTheme.muted).multilineTextAlignment(.center)
                    parts.composer.padding(.top, 8)
                }.frame(maxWidth: .infinity)
            case .capture:
                heading("Tell me a little more.", subtitle: "A photo, a few words, or both.")
                parts.photo(maxHeight: 220)
                parts.composer
                if let prompt = model.setupPrompt, !prompt.isEmpty { Text(prompt).font(.subheadline).foregroundStyle(MendTheme.muted) }
                parts.projectFields.padding(.horizontal, 17).fixiGlass()
            case .confirmation:
                heading("Have I got it?", subtitle: "Check the details before we begin.")
                parts.photo(maxHeight: 190)
                parts.projectSummary.padding(18).fixiGlass()
            case .parts:
                heading("Gather these first.", subtitle: "Tools and parts for this repair.")
                parts.partsKit
            case .diagnosis:
                if let diagnosis = model.diagnosis {
                    heading(diagnosis.status == .ready ? "Your checklist" : diagnosis.status == .stop ? "Pause here." : "Let’s take a closer look.", subtitle: diagnosis.status == .ready ? "Open any step." : diagnosis.title)
                    if diagnosis.status == .ready {
                        parts.progress
                        parts.checklist.padding(.horizontal, 15).fixiGlass()
                        parts.cautions
                    } else {
                        Text(diagnosis.summary).font(.body)
                        parts.cautions
                        ForEach(diagnosis.questions, id: \.self) { Text($0).font(.subheadline).foregroundStyle(MendTheme.mint) }
                    }
                }
            case .guide:
                if let step = model.currentStep {
                    Text("\(model.isDemo ? "Example · " : "")STEP \(model.stepIndex + 1) OF \(model.diagnosis?.steps.count ?? 0)")
                        .font(.caption.monospacedDigit()).foregroundStyle(MendTheme.muted)
                    parts.photo(maxHeight: 250)
                    Text(step.title).font(.system(size: 28, weight: .medium))
                    parts.stepText
                }
            case .complete:
                Image(systemName: "checkmark.circle").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(MendTheme.mint).padding(.top, 45)
                heading("Give it a final check.", subtitle: "Is the problem resolved?")
                parts.progress
                parts.checklist
            }
        }
    }
    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .medium))
            Text(subtitle).font(.subheadline).foregroundStyle(MendTheme.muted)
        }
    }
}

import SwiftUI

/// Content shared by the three layouts. Actions live in the common bottom bar.
@MainActor struct MendExperienceParts {
    @Bindable var model: FixiModel
    var accent: Color = MendTheme.mint

    @ViewBuilder var liveAnswerPhoto: some View {
        if let image = model.liveAnswerImage {
            VStack(alignment: .leading, spacing: 8) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Camera view used to answer this question")
                Text("View used for this answer").font(.caption).foregroundStyle(MendTheme.muted)
            }
        }
    }
    @ViewBuilder func photo(maxHeight: CGFloat = 260) -> some View {
        if model.stage == .guide, let example = model.stepExample {
            VStack(alignment: .leading, spacing: 8) {
                Image(uiImage: example.image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Online example: " + example.caption)
                Button { model.perform(.exampleSource) } label: {
                    Label(example.label + " · " + (example.source.url.host ?? "Source"), systemImage: "arrow.up.right")
                        .font(.caption).foregroundStyle(accent).frame(minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).disabled(!model.isEnabled(.exampleSource))
                    .accessibilityLabel("Example source")
            }
        } else if model.showsStepCameraPhoto, let image = model.annotatedImage {
            VStack(alignment: .leading, spacing: 8) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel(model.currentMarker?.label ?? "Project photo")
                Text(model.stepPhotoReference != nil ? "Your photo · " + (model.currentMarker?.label ?? "") : model.currentMarker?.label ?? (model.isDemo ? "Example photo" : "Your photo"))
                    .font(.caption).foregroundStyle(MendTheme.muted)
            }
        }
    }
    var composer: some View {
        TextField(model.stage == .parts ? "Tell me what you have…" : model.stage == .welcome ? "Tell me about your project…" : "Add a detail…", text: $model.setupText)
            .font(.body).submitLabel(.send)
            .onSubmit {
                let action: MendActionID = model.stage == .parts ? .reviewParts : .submitDetails
                if model.isEnabled(action) { model.perform(action) }
            }
            .padding(18).fixiGlass(radius: 24)
            .disabled(model.busy)
    }
    private func binding(_ field: String, _ path: WritableKeyPath<MendProjectDetails, String>) -> Binding<String> {
        Binding(get: { model.project[keyPath: path] }, set: {
            model.project[keyPath: path] = $0; model.project.suggestedFields.remove(field)
        })
    }
    var projectFields: some View {
        VStack(spacing: 0) {
            field("Make", text: binding("make", \.make), guessed: "make")
            Divider()
            field("Model", text: binding("model", \.model), guessed: "model")
            Divider()
            field("Problem", text: binding("problem", \.problem), guessed: "problem")
        }
    }
    private func field(_ label: String, text: Binding<String>, guessed: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(MendTheme.muted).frame(width: 58, alignment: .leading)
            TextField(label, text: text, axis: .vertical).font(.subheadline).lineLimit(1...3)
            if model.project.suggestedFields.contains(guessed) { Text("Guess").font(.caption2).foregroundStyle(.orange) }
        }.padding(.vertical, 14).disabled(model.busy)
    }
    var projectSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            summary("Make", model.project.make, "make")
            summary("Model", model.project.model, "model")
            summary("Problem", model.project.problem, "problem")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func summary(_ label: String, _ value: String, _ field: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.caption).foregroundStyle(MendTheme.muted)
                if model.project.suggestedFields.contains(field) { Text("Best guess").font(.caption2).foregroundStyle(.orange) }
            }
            Text(value.isEmpty ? "Still needed" : value).font(.body.weight(.medium))
        }
    }
    var progress: some View {
        HStack(spacing: 12) {
            Text("\(model.checkedSteps.count) / \(model.diagnosis?.steps.count ?? 0)")
                .font(.caption.monospacedDigit()).foregroundStyle(accent)
            ProgressView(value: Double(model.checkedSteps.count), total: Double(max(1, model.diagnosis?.steps.count ?? 1))).tint(accent)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.checkedSteps.count) of \(model.diagnosis?.steps.count ?? 0) steps complete")
    }
    @ViewBuilder var checklist: some View {
        if let diagnosis = model.diagnosis {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diagnosis.steps.enumerated()), id: \.element.id) { index, step in
                    let checked = model.checkedSteps.contains(step.id)
                    let open = MendActionID.stepIDs[index]
                    Button { model.perform(open) } label: {
                        HStack(spacing: 13) {
                            ZStack {
                                Circle().fill(checked ? accent.opacity(0.2) : MendTheme.surface)
                                    .overlay(Circle().strokeBorder(accent.opacity(checked ? 0.45 : 0.2), lineWidth: 1))
                                if checked {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(accent)
                                } else {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(MendTheme.muted)
                                }
                            }.frame(width: 31, height: 31)
                            Text(step.title).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                                .foregroundStyle(checked ? MendTheme.muted : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(MendTheme.muted)
                        }.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!model.isEnabled(open))
                        .accessibilityLabel("Open step \(index + 1): \(step.title)")
                        .accessibilityValue(checked ? "Complete" : "Not complete")
                    if index + 1 < diagnosis.steps.count { Divider().padding(.leading, 44) }
                }
            }
        }
    }
    @ViewBuilder var partsKit: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let photo = model.partsPhoto {
                Image(uiImage: photo.image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 210)
                    .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("Your tools and parts")
            }
            if model.partsItems.isEmpty {
                Text("No extra tools or parts listed.").font(.subheadline).foregroundStyle(MendTheme.muted)
            } else {
                Text(model.partsShoppingLinks.isEmpty ? "Here’s what you’ll need." : "Items found. Shopping links are below.")
                    .font(.subheadline).foregroundStyle(MendTheme.muted)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.partsItems.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 13) {
                            ZStack {
                                Circle().fill(MendTheme.surface)
                                    .overlay(Circle().strokeBorder(accent.opacity(0.2), lineWidth: 1))
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(MendTheme.muted)
                            }.frame(width: 31, height: 31).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                                    .frame(minHeight: 31, alignment: .leading)
                                    .accessibilityLabel("Item \(index + 1): \(item)")
                                if let link = model.partsShoppingLinks.first(where: { $0.itemIndex == index }) {
                                    Button { model.openPartsShoppingLink(index) } label: {
                                        Label("Find on Amazon", systemImage: "arrow.up.right")
                                            .font(.caption.weight(.medium)).foregroundStyle(accent)
                                            .frame(minHeight: 44, alignment: .leading)
                                    }.buttonStyle(.plain)
                                        .disabled(!model.isEnabled(MendActionID.shoppingIDs[index]))
                                        .accessibilityLabel("Find \(link.title) on Amazon")
                                }
                            }
                            Spacer(minLength: 4)
                        }.frame(minHeight: 58).padding(.vertical, 4)
                        if index + 1 < model.partsItems.count { Divider().padding(.leading, 44) }
                    }
                }
                if model.partsShoppingLinks.contains(where: { $0.kind == .part }) {
                    Text("Check fit before buying.").font(.caption).foregroundStyle(MendTheme.muted)
                }
            }
            composer
            if !model.partsReviewPending, let message = model.partsMessage, !message.isEmpty {
                Text(message).font(.subheadline).foregroundStyle(MendTheme.muted)
            } else if !model.partsReviewPending, model.partsPhoto == nil {
                Text("Show your tools and parts for a quick check.").font(.subheadline).foregroundStyle(MendTheme.muted)
            }
            ForEach(Array(model.partsIssues.enumerated()), id: \.offset) { _, issue in
                Label(issue, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
            }
            cautions
        }
    }
    @ViewBuilder var cautions: some View {
        if let diagnosis = model.diagnosis {
            ForEach(Array(diagnosis.precautions.enumerated()), id: \.offset) { _, caution in
                Label(caution, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
    @ViewBuilder var stepText: some View {
        if let step = model.currentStep {
            Text(step.instruction).font(.body).lineSpacing(3)
            if let caution = step.caution {
                Label(caution, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            Label(step.expectedResult, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(MendTheme.muted)
            if let message = model.groundingMessage { Text(message).font(.caption).foregroundStyle(MendTheme.muted) }
        }
    }
}

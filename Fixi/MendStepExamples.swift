import Foundation

/// Per-plan work continues while the wearer browses Parts, the checklist, or a
/// different step. Only accepted visuals for the selected step are published.
@MainActor final class MendStepVisualPreparation {
    struct Lookup {
        let id: UUID
        let request: Task<Void, Never>
        let timeout: Task<Void, Never>
    }
    var generation = UUID()
    var planKey: String?
    var photoSignature: String?
    var photoReviewComplete = false
    var photoReviewID: UUID?
    var photoReviewTask: Task<Void, Never>?
    var photoReviewTimeout: Task<Void, Never>?
    var references: [String: MendStepPhotoReference] = [:]
    var examples: [String: MendExampleImage] = [:]
    var attemptedExamples: Set<String> = []
    var forcedExamples: Set<String> = []
    var pendingSteps: [MendStep] = []
    var lookups: [String: Lookup] = [:]
    var isIdle: Bool { photoReviewTask == nil && lookups.isEmpty && pendingSteps.isEmpty }

    func cancelPending() {
        generation = UUID()
        if photoReviewTask != nil { photoReviewComplete = false }
        photoReviewID = nil
        photoReviewTask?.cancel(); photoReviewTask = nil
        photoReviewTimeout?.cancel(); photoReviewTimeout = nil
        for lookup in lookups.values { lookup.request.cancel(); lookup.timeout.cancel() }
        lookups = [:]; pendingSteps = []
    }
}

@MainActor extension FixiModel {
    var stepVisualPlanKey: String? {
        guard !isDemo, let diagnosis, diagnosis.status == .ready, confirmedProject == project,
              [.parts, .diagnosis, .guide, .complete].contains(stage) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(diagnosis) else { return nil }
        return [projectGeneration.uuidString, project.make, project.model, project.problem,
                project.suggestedFields.sorted().joined(separator: ","), data.base64EncodedString()].joined(separator: "|")
    }

    /// Clearing a screen must not cancel preparation for the other steps.
    func cancelExampleImage() {
        stepExample = nil; stepPhotoReference = nil
        exampleImageLoading = false; exampleImageNotice = nil
    }

    /// Backgrounding retires pending work but retains accepted results. A new
    /// plan/project also clears caches; late callbacks cannot enter either one.
    func cancelStepVisualPreparation(clearCache: Bool = false) {
        stepVisualPreparation.cancelPending()
        if clearCache { stepVisualPreparation = MendStepVisualPreparation() }
        cancelExampleImage()
    }

    var stepPhotoManuallySuppressed: Bool {
        currentStep.map { stepVisualPreparation.forcedExamples.contains($0.id) } ?? false
    }

    /// Called only by the accepted foreground photo-grounding path. An archive
    /// update or background photo match must never undo the wearer's rejection.
    func acceptForegroundStepPhotoTarget(stepID: String, photo: MendPhoto, marker: PhotoMarker) {
        guard appActive, stage == .guide, currentStep?.id == stepID,
              let planKey = stepVisualPlanKey, stepVisualPreparation.planKey == planKey,
              PhotoFocus.isValid(marker),
              let original = projectPhotos.first(where: { $0.id == photo.id && $0.jpeg == photo.jpeg }) else { return }
        let state = stepVisualPreparation
        state.forcedExamples.remove(stepID)
        state.references[stepID] = MendStepPhotoReference(stepID: stepID, photo: original, marker: marker)
        state.pendingSteps.removeAll { $0.id == stepID }
        if let lookup = state.lookups.removeValue(forKey: stepID) {
            lookup.request.cancel(); lookup.timeout.cancel()
        }
        // The caller is still finishing foreground grounding; publish only
        // after it clears busy and invokes prepareStepVisuals().
    }

    /// Quiet camera guidance may fill a missing visual, but cannot undo an
    /// explicit Find example choice or replace a visual that arrived meanwhile.
    func acceptAutomaticStepPhotoTarget(stepID: String, photo: MendPhoto, marker: PhotoMarker, planKey: String) {
        let state = stepVisualPreparation
        guard appActive, !busy, !voiceReplyPending, presentation == nil, stage == .guide,
              currentStep?.id == stepID, stepVisualPlanKey == planKey, state.planKey == planKey,
              !state.forcedExamples.contains(stepID), state.references[stepID] == nil,
              state.examples[stepID] == nil, stepExample == nil, !hasStepPhotoTarget,
              PhotoFocus.isValid(marker),
              let original = projectPhotos.first(where: { $0.id == photo.id && $0.jpeg == photo.jpeg }) else { return }
        state.references[stepID] = MendStepPhotoReference(stepID: stepID, photo: original, marker: marker)
        state.pendingSteps.removeAll { $0.id == stepID }
        if let lookup = state.lookups.removeValue(forKey: stepID) {
            lookup.request.cancel(); lookup.timeout.cancel()
        }
        publishPreparedStepVisual()
    }

    func prepareStepVisuals() {
        guard appActive else { return }
        guard let key = stepVisualPlanKey, let plan = diagnosis else {
            if stepVisualPreparation.planKey != nil { cancelStepVisualPreparation(clearCache: true) }
            return
        }
        if stepVisualPreparation.planKey != key {
            cancelStepVisualPreparation(clearCache: true)
            stepVisualPreparation.planKey = key
        }
        let state = stepVisualPreparation
        var seen = Set<String>()
        let photos = projectPhotos.filter { seen.insert($0.id).inserted }
        let photoIDs = Set(photos.map(\.id))
        let photoKey = modelKey().trimmingCharacters(in: .whitespacesAndNewlines)
        let signature = photos.map(\.id).joined(separator: "|") + (photoKey.isEmpty ? "|no-key" : "|key")
        if state.photoSignature != signature {
            state.cancelPending()
            state.photoSignature = signature
            state.photoReviewComplete = false
            // A newly archived still may be unrelated to a rejected highlight.
            // Only accepted foreground grounding (or a new plan) releases it.
            state.references = state.references.filter { photoIDs.contains($0.value.photo.id) }
        }
        // These references come from actual plan/refresh grounding, never the
        // selected cached display image. Preserve their original pixel binding.
        let stepIDs = Set(plan.steps.map(\.id))
        for reference in knownStepPhotoReferences() {
            guard stepIDs.contains(reference.stepID), !state.forcedExamples.contains(reference.stepID),
                  photoIDs.contains(reference.photo.id), PhotoFocus.isValid(reference.marker) else { continue }
            state.references[reference.stepID] = reference
        }
        publishPreparedStepVisual()
        guard state.photoReviewTask == nil else { return }
        if !state.photoReviewComplete {
            let remaining = plan.steps.filter { state.references[$0.id] == nil && !state.forcedExamples.contains($0.id) }
            if remaining.isEmpty || photos.isEmpty || photoKey.isEmpty {
                state.photoReviewComplete = true
            } else {
                beginPhotoReview(steps: remaining, photos: photos, key: photoKey, planKey: key)
                return
            }
        }
        enqueuePreparedExamples()
        startPreparedExamples()
    }

    /// The existing entry point now selects ready visuals. Explicit retries are
    /// silent too, and may replace a highlight the wearer has rejected.
    func loadStepExampleIfNeeded(retry: Bool = false, force: Bool = false) {
        guard appActive, stage == .guide, !isDemo, let step = currentStep else { return }
        prepareStepVisuals()
        guard !busy, let planKey = stepVisualPlanKey, stepVisualPreparation.planKey == planKey else { return }
        let state = stepVisualPreparation
        if retry {
            if force {
                state.forcedExamples.insert(step.id)
                state.references.removeValue(forKey: step.id)
            }
            state.examples.removeValue(forKey: step.id)
            state.attemptedExamples.remove(step.id)
            if let lookup = state.lookups.removeValue(forKey: step.id) {
                lookup.request.cancel(); lookup.timeout.cancel()
            }
            state.pendingSteps.removeAll { $0.id == step.id }
            if state.references[step.id] == nil, !openAIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.pendingSteps.insert(step, at: 0)
            }
        }
        publishPreparedStepVisual()
        startPreparedExamples()
    }

    private func visualPreparationIsCurrent(_ generation: UUID, planKey: String) -> Bool {
        guard stepVisualPreparation.generation == generation, stepVisualPreparation.planKey == planKey else { return false }
        guard appActive, stepVisualPlanKey == planKey else {
            cancelStepVisualPreparation(clearCache: stepVisualPlanKey != planKey)
            return false
        }
        return true
    }

    private func beginPhotoReview(steps: [MendStep], photos: [MendPhoto], key: String, planKey: String) {
        let state = stepVisualPreparation, generation = state.generation, id = UUID(), details = project
        state.photoReviewID = id
        state.photoReviewTimeout = Task { [weak self] in
            guard let self, !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey),
                  self.stepVisualPreparation.photoReviewID == id else { return }
            do { try await self.waitForExampleImageTimeout() } catch { return }
            guard !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey),
                  self.stepVisualPreparation.photoReviewID == id else { return }
            self.finishPhotoReview(id: id, references: [], steps: steps, photos: photos)
        }
        state.photoReviewTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey),
                  self.stepVisualPreparation.photoReviewID == id else { return }
            let result: [MendStepPhotoReference]
            do { result = try await self.findPhotoGuides(details, steps, photos, key) }
            catch { result = [] }
            guard !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey),
                  self.stepVisualPreparation.photoReviewID == id else { return }
            self.finishPhotoReview(id: id, references: result, steps: steps, photos: photos)
        }
    }

    private func finishPhotoReview(id: UUID, references: [MendStepPhotoReference], steps: [MendStep], photos: [MendPhoto]) {
        let state = stepVisualPreparation
        guard state.photoReviewID == id else { return }
        state.photoReviewID = nil
        state.photoReviewTask?.cancel(); state.photoReviewTask = nil
        state.photoReviewTimeout?.cancel(); state.photoReviewTimeout = nil
        state.photoReviewComplete = true
        let stepIDs = Set(steps.map(\.id))
        for reference in references {
            guard stepIDs.contains(reference.stepID), !state.forcedExamples.contains(reference.stepID),
                  state.references[reference.stepID] == nil,
                  PhotoFocus.isValid(reference.marker),
                  let original = photos.first(where: { $0.id == reference.photo.id }) else { continue }
            // Use the exact retained original, never pixels returned by a model.
            state.references[reference.stepID] = MendStepPhotoReference(stepID: reference.stepID, photo: original, marker: reference.marker)
        }
        publishPreparedStepVisual()
        enqueuePreparedExamples()
        startPreparedExamples()
    }

    private func enqueuePreparedExamples() {
        let state = stepVisualPreparation
        guard state.photoReviewComplete, let steps = diagnosis?.steps,
              !openAIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for step in steps where state.references[step.id] == nil && state.examples[step.id] == nil
            && !state.attemptedExamples.contains(step.id) && state.lookups[step.id] == nil
            && !state.pendingSteps.contains(where: { $0.id == step.id }) {
            state.pendingSteps.append(step)
        }
    }

    private func startPreparedExamples() {
        let state = stepVisualPreparation
        guard appActive, state.photoReviewComplete, let planKey = stepVisualPlanKey, state.planKey == planKey else { return }
        let key = openAIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { state.pendingSteps = []; return }
        while state.lookups.count < 2, !state.pendingSteps.isEmpty {
            let step = state.pendingSteps.removeFirst()
            guard state.references[step.id] == nil, state.examples[step.id] == nil,
                  !state.attemptedExamples.contains(step.id), state.lookups[step.id] == nil else { continue }
            let generation = state.generation, id = UUID(), details = project
            let timeout = Task { [weak self] in
                guard let self, !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey),
                      self.stepVisualPreparation.lookups[step.id]?.id == id else { return }
                do { try await self.waitForExampleImageTimeout() } catch { return }
                guard !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey) else { return }
                self.finishPreparedExample(stepID: step.id, id: id, result: nil)
            }
            let request = Task { [weak self] in
                guard let self, !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey),
                      self.stepVisualPreparation.lookups[step.id]?.id == id else { return }
                let result: MendExampleImage?
                do { result = try await self.findExampleImage(details, step, key) }
                catch { result = nil }
                guard !Task.isCancelled, self.visualPreparationIsCurrent(generation, planKey: planKey) else { return }
                self.finishPreparedExample(stepID: step.id, id: id, result: result)
            }
            state.lookups[step.id] = .init(id: id, request: request, timeout: timeout)
        }
    }

    private func finishPreparedExample(stepID: String, id: UUID, result: MendExampleImage?) {
        let state = stepVisualPreparation
        guard let lookup = state.lookups[stepID], lookup.id == id else { return }
        state.lookups.removeValue(forKey: stepID)
        lookup.request.cancel(); lookup.timeout.cancel()
        state.attemptedExamples.insert(stepID)
        if let result, state.references[stepID] == nil { state.examples[stepID] = result }
        publishPreparedStepVisual()
        startPreparedExamples()
    }

    private func publishPreparedStepVisual() {
        exampleImageLoading = false; exampleImageNotice = nil
        guard appActive, !busy, stage == .guide, let step = currentStep,
              stepVisualPreparation.planKey == stepVisualPlanKey else {
            stepExample = nil; stepPhotoReference = nil
            return
        }
        let reference = stepVisualPreparation.references[step.id]
        stepPhotoReference = reference
        stepExample = reference == nil ? stepVisualPreparation.examples[step.id] : nil
        syncDisplay()
    }

    func openCurrentExampleSource() {
        guard appActive, !busy, !voiceReplyPending, !isDemo, presentation == nil, stage == .guide,
              let example = stepExample else { return }
        openExampleURL(example.source.url)
    }
}

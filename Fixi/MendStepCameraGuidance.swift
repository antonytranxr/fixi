import Foundation

/// Independent of plan-wide visual preparation: archiving this task's still
/// may restart photo review, but must not retire the camera task itself.
@MainActor final class MendStepCameraGuidance {
    enum Phase: Equatable { case waiting, acquiring, locating, finished }
    var visitKey: String?
    var enteredAt: Date?
    var attempted = false
    var id = UUID()
    var phase: Phase = .finished
    var task: Task<Void, Never>?
    var timeout: Task<Void, Never>?

    func retire(resetVisit: Bool = false) {
        id = UUID()
        task?.cancel(); task = nil
        timeout?.cancel(); timeout = nil
        phase = .finished
        if resetVisit { visitKey = nil; enteredAt = nil; attempted = false }
    }
}

@MainActor extension FixiModel {
    /// Called by ordinary state synchronization. This never starts Live view,
    /// changes foreground progress, speaks, opens Help, or requests permission.
    func updateStepCameraGuidance() {
        let state = stepCameraGuidance
        guard !isDemo, stage == .guide, let step = currentStep,
              let planKey = stepVisualPlanKey else {
            if state.visitKey != nil { state.retire(resetVisit: true) }
            return
        }
        let visitKey = planKey + "|camera-step|" + step.id
        if state.visitKey != visitKey {
            state.retire(resetVisit: true)
            state.visitKey = visitKey; state.enteredAt = Date()
        }
        if stepCameraVisualAlreadyAvailable(stepID: step.id) || stepPhotoManuallySuppressed {
            cancelStepCameraGuidance()
            return
        }
        guard stepCameraEnvironmentAvailable else {
            if state.task != nil { cancelStepCameraGuidance() }
            return
        }
        if liveOutputHeld || voice.isSpeaking {
            // Narration may finish before an attempt, but must never resume a
            // capture or result that has been interrupted by newer speech.
            if state.task != nil, state.phase != .waiting { cancelStepCameraGuidance() }
        }
        guard !state.attempted, state.task == nil,
              stepVisualPreparation.planKey == planKey else { return }
        let key = modelKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        state.attempted = true; state.phase = .waiting
        let id = UUID(); state.id = id
        let details = project, liveGeneration = liveViewGeneration
        state.timeout = Task { [weak self] in
            guard let self else { return }
            do { try await self.waitForStepCameraGuidanceTimeout() } catch { return }
            guard !Task.isCancelled, self.stepCameraGuidance.id == id else { return }
            self.cancelStepCameraGuidance()
        }
        state.task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishStepCameraGuidance(id: id) }
            do {
                // Step entry synchronizes before queued narration starts. Let
                // its speech task claim the output route before checking it.
                try await Task.sleep(for: .milliseconds(150))
                // Let the step's own narration release the camera/audio route.
                while self.liveOutputHeld || self.voice.isSpeaking {
                    guard self.stepCameraAttemptIsCurrent(id, visitKey: visitKey, planKey: planKey,
                                                         details: details, liveGeneration: liveGeneration) else { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard self.stepCameraAttemptIsCurrent(id, visitKey: visitKey, planKey: planKey,
                                                     details: details, liveGeneration: liveGeneration) else { return }
                // A frame after narration ended is stronger than merely one
                // after entry; neither can reuse the preceding step's scene.
                let notBefore = max(self.stepCameraGuidance.enteredAt ?? Date(), Date())
                self.stepCameraGuidance.phase = .acquiring
                let photo = try await self.freshLivePhoto(notBefore: notBefore, quiet: true)
                try Task.checkCancellation()
                guard self.stepCameraAttemptIsCurrent(id, visitKey: visitKey, planKey: planKey,
                                                     details: details, liveGeneration: liveGeneration),
                      !self.liveOutputHeld, !self.voice.isSpeaking,
                      photo.capturedAt >= notBefore,
                      ["Glasses camera", "Glasses live view", "iPhone camera", "Photo library"].contains(photo.source) else { return }
                try MendClient.validatePhoto(jpeg: photo.jpeg, photoID: photo.id)
                self.stepCameraGuidance.phase = .locating
                // Retain the exact still used, even if this step has no target.
                // Normal plan-wide photo review can also use it for other steps.
                self.rememberProjectPhoto(photo, prepare: false)
                self.prepareStepVisuals()
                guard self.stepCameraAttemptIsCurrent(id, visitKey: visitKey, planKey: planKey,
                                                     details: details, liveGeneration: liveGeneration) else { return }
                let result = try await self.locateStepCameraTarget(photo, step, key)
                try Task.checkCancellation()
                guard self.stepCameraAttemptIsCurrent(id, visitKey: visitKey, planKey: planKey,
                                                     details: details, liveGeneration: liveGeneration),
                      !self.liveOutputHeld, !self.voice.isSpeaking else { return }
                let grounded = try result.validated(expectedPhotoID: photo.id)
                guard let marker = grounded.marker else { return }
                // Finish before publishing: syncDisplay may synchronously see
                // the new reference and retire this now-completed visit.
                self.finishStepCameraGuidance(id: id)
                self.acceptAutomaticStepPhotoTarget(stepID: step.id, photo: photo, marker: marker, planKey: planKey)
            } catch {
                // Quiet best effort. Foreground questions, controls and errors
                // remain owned by their existing flows.
            }
        }
    }

    /// Cancellation consumes this visit's attempt without starting a new one
    /// when an unrelated display/status refresh arrives.
    func cancelStepCameraGuidance() {
        let state = stepCameraGuidance
        if state.visitKey != nil { state.attempted = true }
        if state.task != nil || state.timeout != nil { state.retire() }
    }

    private var stepCameraEnvironmentAvailable: Bool {
        appActive && liveViewEnabled && presentation == nil && !busy && !voiceReplyPending &&
        !liveFrameAcquiring && !heardSpeech && !voice.isReceivingSpeech &&
        !voiceStarting && !voiceStopping && !voice.captureSuspended &&
        voiceAudioRestore == nil && !livePermissionHandoff && !liveViewSystemHold &&
        workKind != "capture" && workKind != "grounding"
    }

    private func stepCameraVisualAlreadyAvailable(stepID: String) -> Bool {
        hasStepPhotoTarget || stepExample != nil || stepVisualPreparation.references[stepID] != nil ||
        stepVisualPreparation.examples[stepID] != nil
    }

    private func stepCameraAttemptIsCurrent(_ id: UUID, visitKey: String, planKey: String,
                                           details: MendProjectDetails, liveGeneration: UUID) -> Bool {
        !Task.isCancelled && stepCameraGuidance.id == id && stepCameraGuidance.visitKey == visitKey &&
        stepVisualPlanKey == planKey && stepVisualPreparation.planKey == planKey && project == details &&
        liveViewGeneration == liveGeneration && stage == .guide && stepCameraEnvironmentAvailable &&
        currentStep.map { visitKey == planKey + "|camera-step|" + $0.id &&
            !stepCameraVisualAlreadyAvailable(stepID: $0.id) } == true &&
        !stepPhotoManuallySuppressed
    }

    private func finishStepCameraGuidance(id: UUID) {
        let state = stepCameraGuidance
        guard state.id == id else { return }
        state.task = nil; state.phase = .finished
        state.timeout?.cancel(); state.timeout = nil
    }
}

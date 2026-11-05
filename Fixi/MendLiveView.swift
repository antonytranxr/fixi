import Foundation
import UIKit

extension FixiModel {
    var liveViewStatus: String {
        _ = liveStatusVersion
        if let livePreviewStatus { return livePreviewStatus }
        guard liveViewEnabled else { return "Camera off" }
        if liveOutputHeld || voice.isSpeaking { return "Camera paused · Fixi speaking" }
        if liveFrameAcquiring { return "Looking…" }
        if voiceStarting || voiceStopping { return "Camera waiting for voice" }
        if liveViewSystemHold || livePermissionHandoff { return "Camera paused" }
        if (busy || voiceReplyPending), !glasses.streaming { return "Camera paused · Thinking" }
        if glasses.streaming, let date = glasses.liveFrameReceivedAt, Date().timeIntervalSince(date) <= 2 {
            return "Camera live"
        }
        return "Starting camera…"
    }
    var liveViewActions: [MendAction] {
        [MendAction(id: liveViewEnabled ? .pauseLiveView : .startLiveView,
                    title: liveViewEnabled ? "Pause camera" : "Live view",
                    enabled: liveViewEnabled || (!isDemo && !busy && !voiceStarting && !voiceStopping))]
    }
    var liveAnswerFocusActions: [MendAction] {
        guard liveAnswerCanFocus else { return [] }
        return [MendAction(id: liveAnswerIsFocused ? .showLiveFullPhoto : .focusLivePhoto,
                           title: liveAnswerIsFocused ? "Full image" : "Close-up image")]
    }
    private var liveAnswerPresentation: PhotoCanvas.Presentation? {
        guard let photo = liveAnswerPhoto, let answer = liveAnswer else { return nil }
        let key = photo.id + String(liveAnswerFocused)
        if liveAnswerCache?.key == key { return liveAnswerCache?.value }
        let value = PhotoCanvas.presentation(photo, marker: answer.marker, markerPhotoID: answer.photoID, focused: liveAnswerFocused)
        liveAnswerCache = (key, value)
        return value
    }
    var liveAnswerImage: UIImage? { liveAnswerPresentation?.image }
    var liveAnswerIsFocused: Bool { liveAnswerPresentation?.isFocused == true }
    var liveAnswerCanFocus: Bool { liveAnswerPresentation?.canFocus == true }
    func clearLiveAnswer() { liveAnswer = nil; liveAnswerPhoto = nil; liveAnswerCache = nil; liveAnswerFocused = true }

    var liveViewSystemHold: Bool {
        [.settings, .library, .camera, .audioOutput].contains(presentation) || audioTestTask != nil || audioOutput.testPlaying
    }
    func startLiveView() {
        guard appActive, !isDemo, !busy, !liveViewEnabled else { return }
        guard glasses.registered else {
            liveViewNotice = "Connect your glasses through Meta AI first."
            openSettings(); return
        }
        if stage == .welcome { startProject() }
        liveViewGeneration = UUID(); liveViewEnabled = true; liveViewNotice = nil
        livePreviewStatus = nil; glasses.errorMessage = nil
        let id = liveViewGeneration
        liveCameraLoop?.cancel()
        liveCameraLoop = Task { [weak self] in
            var openingSince: Date?
            var previousStatus = ""
            while !Task.isCancelled {
                guard let self, self.liveViewEnabled, self.liveViewGeneration == id, self.appActive else { return }
                if self.livePermissionHandoff {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    openingSince = nil
                    continue
                }
                let manualCapture = self.workKind == "capture" || self.voice.captureSuspended || self.voiceAudioRestore != nil
                let held = self.liveOutputHeld || self.voice.isSpeaking || self.voiceStarting || self.voiceStopping || self.liveViewSystemHold
                if held {
                    openingSince = nil
                    if !manualCapture && (self.glasses.streaming || self.glasses.startingCamera) {
                        self.glasses.stopCamera()
                    }
                } else if !manualCapture && (!self.busy && !self.voiceReplyPending || self.liveFrameAcquiring) {
                    if let error = self.glasses.errorMessage, !self.glasses.requestingCameraPermission {
                        self.pauseLiveView(notice: "Camera paused. " + error); return
                    }
                    if !self.glasses.streaming && !self.glasses.startingCamera && !self.glasses.requestingCameraPermission {
                        if openingSince == nil { openingSince = Date() }
                        self.glasses.connect()
                    }
                    if let frameAt = self.glasses.liveFrameReceivedAt, Date().timeIntervalSince(frameAt) <= 2 { openingSince = nil }
                    else if openingSince == nil { openingSince = Date() }
                    if let openingSince, Date().timeIntervalSince(openingSince) > 20, !self.glasses.requestingCameraPermission {
                        self.pauseLiveView(notice: "No fresh camera view. Check the glasses, then turn Live view on again."); return
                    }
                }
                let status = self.liveViewStatus
                if status != previousStatus { previousStatus = status; self.liveStatusVersion += 1; self.syncDisplay() }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        syncDisplay()
    }
    func pauseLiveView(notice: String? = nil) {
        cancelStepCameraGuidance()
        let wasEnabled = liveViewEnabled
        liveViewEnabled = false; liveViewGeneration = UUID(); livePreviewStatus = nil
        liveCameraLoop?.cancel(); liveCameraLoop = nil
        liveViewNotice = notice
        if liveQuestionUsesCamera && !liveQuestionSubmitted { cancelVoiceReply() }
        if wasEnabled && workKind != "capture" { glasses.stopCamera() }
        syncDisplay()
    }
    /// Speech keeps listening. Only the camera capability releases its audio route.
    func prepareLiveSpokenOutput() async throws {
        liveOutputHeld = true
        syncDisplay()
        try await glasses.stopCameraAndWait()
        try Task.checkCancellation()
    }
    func finishLiveSpokenOutput() {
        liveOutputHeld = false
        syncDisplay()
    }
    func freshLivePhoto(notBefore: Date? = nil, quiet: Bool = false) async throws -> MendPhoto {
        let generation = liveViewGeneration, acquisition = UUID()
        if !quiet {
            liveAcquisitionID = acquisition; liveFrameAcquiring = true; syncDisplay()
        }
        defer {
            if !quiet, liveAcquisitionID == acquisition { liveFrameAcquiring = false; syncDisplay() }
        }
        func check() throws {
            try Task.checkCancellation()
            guard liveViewEnabled, liveViewGeneration == generation, appActive else { throw CancellationError() }
        }
        try check()
        if let acquireLivePhoto {
            let image = try await acquireLivePhoto()
            try check()
            guard Self.livePhotoIsFresh(image), notBefore.map({ image.capturedAt >= $0 }) ?? true else {
                throw MendError.message("The camera view is too old. Look at the part and ask again.")
            }
            return image
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            try check()
            if !liveOutputHeld, !voice.isSpeaking, let image = glasses.livePhoto(maxAge: 2),
               Self.livePhotoIsFresh(image), notBefore.map({ image.capturedAt >= $0 }) ?? true { return image }
            if let message = glasses.errorMessage, !glasses.requestingCameraPermission { throw MendError.message(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MendError.message("I couldn’t get a fresh view. Hold still, check the glasses connection, and ask again.")
    }
    static func livePhotoIsFresh(_ photo: MendPhoto, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(photo.capturedAt)
        return age >= -0.5 && age <= 2 && !photo.jpeg.isEmpty
    }
#if DEBUG
    func previewLiveView(answer: Bool) {
        loadDemo(); openChecklistStep(1)
        liveViewEnabled = true; livePreviewStatus = "Camera live"
        if answer, let photo = currentPhoto {
            liveAnswerPhoto = photo
            liveAnswer = MendLiveAnswer(photoID: photo.id, answer: "That’s the mounting screw. Keep the door supported and turn gently clockwise until snug.", marker: currentMarker)
            lastAnswer = liveAnswer?.answer; presentation = .details
        }
        syncDisplay()
    }
#endif
}

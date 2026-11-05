import Foundation

extension FixiModel {
    var progressTitle: String? { busy ? busyLabel : voiceReplyPending ? replyLabel : nil }
    var statusText: String {
        if let progressTitle { return progressDetail.isEmpty ? progressTitle : progressDetail }
        if voiceStarting || voiceStopping { return voiceStatus }
        if voice.isActive {
            if voice.isMuted { return voice.listeningMode == .oneTurn ? "Mic off · tap Talk" : "Microphone muted" }
            if heardSpeech { return "Listening…" }
            if voice.isSpeaking { return "Replying…" }
            let listening = voice.listeningMode == .oneTurn ? (voice.isListeningForTurn ? "Listening…" : "Tap Talk to speak") : "Listening"
            return voiceRepliesPaused ? listening + " · replies paused" : listening
        }
        return "Ready"
    }

    /// Immediate visual feedback, then one short spoken acknowledgement if slow.
    /// Fenced with the operation so a late cue cannot speak over the real answer.
    func startFeedback(_ spoken: String) {
        finishFeedback()
        let id = UUID(); feedbackID = id; progressDetail = ""
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1200))
                guard let self, self.feedbackID == id, self.appActive, self.busy || self.voiceReplyPending else { return }
                if self.voice.isActive, !self.voiceRepliesPaused, !self.voice.captureSuspended, !self.heardSpeech, !self.liveFrameAcquiring,
                   self.voice.listeningMode != .oneTurn || !self.voice.isListeningForTurn {
                    // A progress cue is not the delegated answer. Preserve the
                    // pending-turn guard after the acknowledgement finishes.
                    self.feedbackSpoken = true
                    _ = await self.voice.speakAndWait(spoken)
                }
                try await Task.sleep(for: .seconds(7))
                guard self.feedbackID == id, self.busy || self.voiceReplyPending else { return }
                self.progressDetail = "Still working…"; self.syncDisplay()
                try await Task.sleep(for: .seconds(12))
                guard self.feedbackID == id, self.busy || self.voiceReplyPending else { return }
                self.progressDetail = "Taking longer · Cancel anytime"; self.syncDisplay()
            } catch { }
        }
    }
    func finishFeedback() {
        feedbackID = UUID(); feedbackTask?.cancel(); feedbackTask = nil; progressDetail = ""
        if feedbackSpoken { voice.interruptPlayback(); feedbackSpoken = false }
    }
}

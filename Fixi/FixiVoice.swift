import Foundation
import UIKit

extension FixiModel {
    var voiceOpen: Bool { voiceStarting || voiceStopping || voice.isActive || voice.isConnecting }
    var voiceStatus: String {
        if voiceStopping { return "Ending conversation…" }
        if voiceStarting { return voice.status }
        if voice.listeningMode == .oneTurn, voice.isActive {
            if voice.isMuted { return "Mic off · tap Talk when ready" }
            if voice.isListeningForTurn { return voice.status }
            if voiceReplyPending { return "Thinking · mic off" }
            if voiceRepliesPaused { return "Replies paused · tap Talk to speak" }
            return voice.status
        }
        if voice.isActive && voice.isMuted { return "Microphone muted · use touch or gesture to unmute" }
        if voiceRepliesPaused && voice.isActive { return "Replies paused · voice controls still listening" }
        if voiceReplyPending { return "Thinking…" }
        return voice.status
    }
    var voiceInputLabel: String {
        if voice.listeningMode == .oneTurn {
            return voice.isListeningForTurn && !voice.isMuted ? "Listening" : "Mic off"
        }
        return voice.isMuted ? "Mic muted" : "Listening"
    }
    var voiceInputIsOpen: Bool {
        voice.isActive && !voice.isMuted && (voice.listeningMode == .continuous || voice.isListeningForTurn)
    }

    func configureVoice() {
        voice.onWillSpeak = { [weak self] in try await self?.prepareLiveSpokenOutput() }
        voice.onDidFinishSpeaking = { [weak self] in self?.finishLiveSpokenOutput() }
        voice.onDelegation = { [weak self] id, text in self?.receiveVoice(text, delegationID: id) }
        voice.onUserSpeechStarted = { [weak self] in
            guard let self else { return }
            self.heardSpeech = true; self.syncDisplay()
            self.voiceUtteranceContext = self.voiceSelectionContext
            self.voiceUtteranceCompletionPromptContext = self.stepCompletionPromptContext
            self.voiceUtteranceWasSetup = [.welcome, .capture, .confirmation].contains(self.stage)
            self.voiceUtteranceProject = self.projectGeneration
        }
        voice.onStateChange = { [weak self] in
            guard let self else { return }
            if !self.voice.isReceivingSpeech { self.heardSpeech = false }
            // Preserve the screen snapshot until the closed turn delegates; it
            // still protects commands spoken before a touch/gesture navigation.
            self.syncDisplay()
        }
        voice.onNotice = { [weak self] message in
            self?.voiceNotice = message; self?.syncDisplay()
        }
        voice.onFailure = { [weak self] message in
            guard let self else { return }
            self.voiceNotice = message; self.endVoice(); self.syncDisplay()
        }
        glasses.onConnectionLost = { [weak self] in
            guard let self, !self.glasses.requestingVoicePermission, !self.glasses.requestingCameraPermission else { return }
            self.pauseLiveView(notice: "Live view paused. Reconnect your glasses.")
            guard self.voiceOpen else { return }
            self.endVoice()
            self.voiceNotice = "The glasses microphone session ended. After reconnecting or finishing Meta AI permission, choose Glasses again."
        }
    }

    func startVoice() {
        guard appActive, !voiceOpen, !busy, !audioOutput.testPlaying else { return }
        guard glasses.registered else {
            voiceNotice = "Connect through Meta AI first, then choose Glasses."
            openSettings(); return
        }
        if stage == .welcome { startProject() }
        let id = UUID(); voiceGeneration = id; voiceStarting = true; voiceNotice = nil
        voiceRepliesPaused = false
        // Establish camera intent before the microphone can deliver an early
        // question. The live loop holds the stream until voice startup finishes.
        voiceStartedLiveView = !liveViewEnabled
        startLiveView()
        voiceLifecycle = Task { [weak self] in
            guard let self else { return }
            do {
                do { try await self.glasses.prepareConversationCamera() }
                catch {
                    if error is CancellationError { throw error }
                    guard self.voiceGeneration == id, self.appActive, !Task.isCancelled else { return }
                    self.pauseLiveView(notice: "Camera unavailable. " + error.localizedDescription)
                }
                try Task.checkCancellation()
                guard self.voiceGeneration == id, self.appActive else { return }
                self.voice.setOutputEnabled(true)
                try await self.voice.start(apiKey: self.openAIKey(), context: self.voiceContext)
                guard self.voiceGeneration == id, self.appActive, !Task.isCancelled else { return }
                self.voiceStarting = false; self.voiceLifecycle = nil
                self.audioOutput.refresh()
                if self.audioOutput.needsGlassesOutput { self.showAudioOutput() }
                else { self.speakCurrentState() }
                self.syncDisplay()
            } catch {
                guard self.voiceGeneration == id else { return }
                if !(error is CancellationError) { self.voiceNotice = error.localizedDescription }
                self.pauseLiveView(notice: "Camera paused. Start Glasses again when ready.")
                self.endVoice()
            }
        }
        syncDisplay()
    }

    func endVoice() {
        stopSoundTest()
        guard voiceOpen || voiceReplyPending else { return }
        if voiceStartedLiveView { pauseLiveView(); voiceStartedLiveView = false }
        voiceGeneration = UUID(); let id = voiceGeneration
        voiceUtteranceContext = nil; heardSpeech = false
        stepCompletionPromptContext = nil; voiceUtteranceCompletionPromptContext = nil
        voiceLifecycle?.cancel(); voiceLifecycle = nil
        cancelVoiceReply(); voiceAudioRestore?.cancel(); voiceAudioRestore = nil
        cameraAudioID = UUID()
        voiceStarting = false; voiceStopping = true
        voiceLifecycle = Task { [weak self] in
            guard let self else { return }
            await self.voice.stop()
            guard self.voiceGeneration == id else { return }
            self.audioOutput.finishRouteSelection(keepSessionActive: false)
            self.voiceStopping = false; self.voiceLifecycle = nil; self.syncDisplay()
        }
        syncDisplay()
    }

    func cancelVoiceReply() {
        if voiceReplyPending { finishFeedback() }
        voiceReplyID = UUID(); voiceReplyTask?.cancel(); voiceReplyTask = nil; voiceReplyPending = false
        liveQuestionUsesCamera = false; liveQuestionSubmitted = false
    }

    func receiveVoice(_ text: String, delegationID: String) {
        guard appActive, voice.isActive, !voice.isMuted else { return }
        // A transcript can never open another microphone turn. The session
        // closes before delegation, so Talk is now visible but remains physical-only.
        if MendVoiceActions.resolve(text, available: [MendAction(id: .talk, title: "Talk")]) == .action(.talk) { return }
        // Stop listening was visible during the accepted turn even though the
        // native microphone has already closed before this callback arrives.
        if voice.listeningMode == .oneTurn,
           MendVoiceActions.resolve(text, available: [MendAction(id: .muteMic, title: "Stop listening")]) == .action(.muteMic) {
            heardSpeech = false; voiceUtteranceContext = nil
            voice.mute(); syncDisplay(); return
        }
        heardSpeech = false
        let startedOn = voiceUtteranceContext
        let beganInSetup = voiceUtteranceWasSetup
        let completionPrompt = startedOn == nil ? stepCompletionPromptContext : voiceUtteranceCompletionPromptContext
        voiceUtteranceContext = nil
        stepCompletionPromptContext = nil; voiceUtteranceCompletionPromptContext = nil
        cancelVoiceReply()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let setupContinuation = beganInSetup && voiceUtteranceProject == projectGeneration && [.capture, .confirmation].contains(stage) && (presentation == nil || presentation == .actions)
        if let startedOn, startedOn != voiceSelectionContext, !setupContinuation {
            voice.sayResult("The screen changed while you were speaking. Please say the button or question again.", delegationID: delegationID)
            return
        }
        if let completionPrompt, completionPrompt.context == currentStepCompletionPromptContext,
           (completionPrompt.allowsBareAffirmation ? MendVoiceActions.isStepCompletionAffirmation(text) : MendVoiceActions.isStepCompletionSelfReport(text)) {
            if isEnabled(.nextStep) { perform(.nextStep) }
            else { explainUnavailableStepCompletion(delegationID: delegationID) }
            return
        }
        switch MendVoiceActions.resolve(text, available: availableActions) {
        case .action(let id): perform(id); return
        case .help:
            if isEnabled(.showActions) { perform(.showActions) }
            else { voice.sayResult("Available controls: " + availableActions.filter(\.enabled).map(\.title).joined(separator: ", "), delegationID: delegationID) }
            return
        case .unmatched: break
        }
        if MendVoiceActions.isExplicitStepCompletion(text) {
            explainUnavailableStepCompletion(delegationID: delegationID); return
        }
        if text.lowercased().contains("sk-") || text.lowercased().contains("api key is") {
            voice.sayResult("Enter API keys privately in Settings on your iPhone. Please do not speak them aloud.", delegationID: delegationID); return
        }
        if presentation == .library || presentation == .camera || presentation == .audioOutput {
            voice.sayResult("Finish the system control on your iPhone, or say Close to return to Fixi.", delegationID: delegationID); return
        }
        if stage == .welcome || stage == .capture || stage == .confirmation {
            if MendSetupUtterance.route(text, current: project) == .question {
                guard !busy else {
                    voice.sayResult(busyLabel + " Please ask again when I’m ready, or say Cancel.", delegationID: delegationID); return
                }
                askQuestion(text, research: Self.wantsResearch(text), delegationID: delegationID)
                return
            }
            if busy && workKind != "intake" && workKind != "capture" {
                voice.sayResult(busyLabel + " You can say Cancel.", delegationID: delegationID); return
            }
            collectDetails(text: text)
            return
        }
        if stage == .diagnosis, diagnosis?.status == .moreEvidence,
           !text.contains("?"), !["what", "how", "why", "can", "could"].contains(text.lowercased().split(separator: " ").first.map(String.init) ?? "") {
            editProject(); project.problem = String((project.problem + ". " + text).prefix(1800))
            collectDetails(text: text); return
        }
        if busy {
            voice.sayResult(busyLabel + " You can say Cancel.", delegationID: delegationID); return
        }
        if stage == .parts && !Self.wantsResearch(text) && !Self.isPartsQuestion(text) {
            reviewParts(text: text); return
        }
        askQuestion(text, research: Self.wantsResearch(text), delegationID: delegationID)
    }

    private func explainUnavailableStepCompletion(delegationID: String) {
        let message = busy
            ? busyLabel + " Tell me again when I’m ready, or say Cancel."
            : stage == .guide
            ? "Close this screen to return to your step, then tell me you’ve finished."
            : "Open a checklist step first, then tell me you’ve finished."
        voiceNotice = message
        voice.sayResult(message, delegationID: delegationID); syncDisplay()
    }

    private static func isPartsQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("?") || ["explain", "tell me", "help me", "help with", "show me", "check whether"].contains(where: { lower.hasPrefix($0) }) || ["what", "how", "why", "can", "could", "which", "is", "are", "does", "do", "where", "should", "will", "would"].contains(lower.split(separator: " ").first.map(String.init) ?? "")
    }
    static func wantsResearch(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["look up", "look it up", "search", "manual", "manufacturer", "tips", "tricks", "find more", "additional info", "torque", "specification"].contains { lower.contains($0) }
    }
    func askQuestion(_ text: String, research: Bool = false, delegationID: String? = nil) {
        guard appActive, !busy else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stepCompletionPromptContext = nil
        cancelVoiceReply(); helpText = ""
        let key = research ? openAIKey() : modelKey()
        guard !key.isEmpty else {
            voiceNotice = research ? "Add your OpenAI key in Settings for source lookups." : "Add your Meta key in Settings for repair questions."
            lastAnswer = voiceNotice; voice.sayResult(voiceNotice!); syncDisplay(); return
        }
        let id = UUID(); voiceReplyID = id
        let contextToken = photoContextToken, details = project
        let currentDiagnosis = diagnosis, step = stage == .guide ? currentStep : nil
        let history = String(voice.conversationContext.suffix(12_000))
        voiceReplyPending = true; replyLabel = research ? "Looking up guidance…" : "Thinking…"
        lastAnswer = nil; answerSources = []; clearLiveAnswer()
        let useLive = liveViewEnabled, liveGeneration = liveViewGeneration
        liveQuestionUsesCamera = useLive
        if useLive { replyLabel = "Looking…" }
        startFeedback(research ? "I’m looking for guidance for your model." : "Let me check that.")
        syncDisplay()
        voiceReplyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = useLive ? try await self.freshLivePhoto() : nil
                guard self.voiceReplyID == id, !Task.isCancelled,
                      !useLive || (self.liveViewEnabled && self.liveViewGeneration == liveGeneration) else { return }
                if let image { self.rememberProjectPhoto(image) }
                self.replyLabel = research ? "Looking up guidance…" : "Thinking…"; self.syncDisplay()
                self.liveQuestionSubmitted = useLive
                let answer: String, spoken: String, sources: [MendSource]
                var visual: MendLiveAnswer?
                if research {
                    let result = try await self.researchQuestion(text, details, currentDiagnosis, step, image, key)
                    answer = result.text; spoken = result.spokenText; sources = result.sources
                    if let image { visual = MendLiveAnswer(photoID: image.id, answer: spoken, marker: nil) }
                } else if let image {
                    let result = try await self.answerLiveQuestion(text, details, currentDiagnosis, step, history, image, key)
                        .validated(expectedPhotoID: image.id)
                    answer = result.answer; spoken = answer; sources = []; visual = result
                } else {
                    answer = try await self.answerRepairQuestion(text, details, currentDiagnosis, step, history, key)
                    spoken = answer; sources = []
                }
                guard self.voiceReplyID == id, !Task.isCancelled else { return }
                self.voiceReplyPending = false; self.voiceReplyTask = nil; self.liveQuestionUsesCamera = false; self.finishFeedback()
                guard self.photoContextToken == contextToken, self.project == details, self.appActive else { self.syncDisplay(); return }
                self.lastAnswer = answer; self.answerSources = sources
                self.liveAnswerPhoto = image; self.liveAnswer = visual; self.liveAnswerFocused = true
                // Keep the unconfirmed project and its Create steps control visible.
                // Setup answers appear in the existing inline answer card.
                if useLive || (self.presentation == nil && ![.welcome, .capture, .confirmation].contains(self.stage)) || self.presentation == .details {
                    self.presentation = .details; self.glassesPageForDetails()
                }
                self.rememberStepCompletionPrompt(spoken)
                self.voice.sayResult(spoken, delegationID: delegationID); self.syncDisplay()
            } catch {
                guard self.voiceReplyID == id, !Task.isCancelled else { return }
                self.voiceReplyPending = false; self.voiceReplyTask = nil; self.liveQuestionUsesCamera = false; self.finishFeedback()
                guard self.photoContextToken == contextToken, self.project == details, self.appActive else { self.syncDisplay(); return }
                self.voiceNotice = error.localizedDescription; self.lastAnswer = error.localizedDescription
                self.voice.sayResult("I couldn’t get that answer. \(error.localizedDescription)", delegationID: delegationID)
                self.syncDisplay()
            }
        }
    }
    private var voiceSelectionContext: String {
        photoContextToken + ":" + (presentation?.rawValue ?? "main") + ":\(glassesPage):\(actionPage)"
    }

    private var currentStepCompletionPromptContext: String? {
        guard stage == .guide, currentStep != nil else { return nil }
        return projectGeneration.uuidString + ":" + photoContextToken
    }

    private func rememberStepCompletionPrompt(_ text: String, completionInvitation: Bool = false) {
        guard let context = currentStepCompletionPromptContext else { stepCompletionPromptContext = nil; return }
        let asksCompletion = MendVoiceActions.asksForStepCompletion(text)
        stepCompletionPromptContext = asksCompletion || completionInvitation
            ? MendStepCompletionPrompt(context: context, allowsBareAffirmation: asksCompletion) : nil
    }

    func holdVoiceForCamera() {
        cameraAudioID = UUID(); voiceAudioRestore?.cancel(); voiceAudioRestore = nil
        if voice.isActive { voice.setCaptureSuspended(true) }
    }
    func restoreVoiceAfterCamera() {
        let id = cameraAudioID
        voiceAudioRestore?.cancel()
        voiceAudioRestore = Task { [weak self] in
            guard let self, id == self.cameraAudioID, !Task.isCancelled else { return }
            do {
                try await self.glasses.stopCameraAndWait()
                guard id == self.cameraAudioID, !Task.isCancelled else { return }
                self.voice.setCaptureSuspended(false)
            } catch {
                guard id == self.cameraAudioID, !Task.isCancelled else { return }
                self.voiceNotice = "The camera has not closed yet. Reconnect the glasses to restore replies."
            }
            self.voiceAudioRestore = nil; self.syncDisplay()
        }
    }
    func speakCurrentState() {
        guard voice.isActive else { return }
        if busy { voice.sayResult(busyLabel); return }
        if presentation == .details, let lastAnswer {
            let spoken = MendResearchAnswer(text: lastAnswer, sources: answerSources).spokenText
            rememberStepCompletionPrompt(spoken)
            voice.sayResult(spoken); return
        }
        if let presentation, ![.preview, .details].contains(presentation) {
            let lead = presentation == .settings ? "Settings. Enter keys privately on your iPhone." : presentation == .actions ? "Actions." : presentation == .photo ? "Photo detail." : presentation == .checklist ? "Your checklist." : presentation == .sources ? "Sources." : "Continue on your iPhone, or say Close."
            voice.sayResult(lead + " " + availableActions.filter(\.enabled).prefix(7).map(\.title).joined(separator: ", ")); return
        }
        let text: String
        switch stage {
        case .welcome: text = Self.openingPrompt
        case .capture:
            let guesses = [("make", project.make), ("model", project.model), ("problem", project.problem)]
                .filter { project.suggestedFields.contains($0.0) && !$0.1.isEmpty }.map(\.1)
            let lead = guesses.isEmpty ? "" : "My best guess is \(guesses.joined(separator: ", ")). "
            text = lead + (project.isReady ? "The details are ready. Say Review details." : (setupPrompt ?? Self.openingPrompt))
        case .confirmation: text = (project.suggestedFields.isEmpty ? "I have " : "My best guess is ") + "\(project.make), \(project.model). The problem is: \(project.problem). Is that right? Say Confirm, or tell me what to change."
        case .parts:
            let found = partsItems.isEmpty ? "This guide doesn’t call for extra parts or tools. " : "I’ve found the items you’ll need. "
            let links = partsShoppingLinks.isEmpty ? "" : "The shopping links are in the app. "
            text = found + links + "Show me what you have, or say Ready when you have everything."
        case .diagnosis:
            guard let diagnosis else { return }
            text = diagnosis.status == .ready ? "Your checklist has \(diagnosis.steps.count) steps. " + diagnosis.precautions.joined(separator: " ") + " Choose any step to open it." : diagnosis.summary + " " + diagnosis.questions.joined(separator: " ")
        case .guide:
            guard let step = currentStep else { return }
            text = "Step \(stepIndex + 1). \(step.instruction) " + (step.caution.map { "Care: \($0). " } ?? "") + "Check: \(step.expectedResult) Tell me when you’ve finished."
        case .complete: text = "All steps checked. Test the result, and tell me if you still need help."
        }
        rememberStepCompletionPrompt(text, completionInvitation: stage == .guide)
        voice.sayResult(text)
    }
    var voiceContext: String {
        var lines = ["Fixi repair state: \(stage.rawValue). \(busy ? busyLabel : "Ready")",
                     "Project: \(project.make), \(project.model). Problem: \(String(problem.prefix(1800)))",
                     "Available controls: " + availableActions.filter(\.enabled).map(\.title).joined(separator: ", "),
                     "Never act on assistant speech. Only the app dispatches explicit user selections."]
        if stage == .guide, let step = currentStep { lines.append("Current step: \(step.title). \(step.instruction). Check: \(step.expectedResult). Caution: \(step.caution ?? "None")") }
        return lines.joined(separator: "\n")
    }

    func openSettings() {
        metaKeyDraft = MendKeyStore.read(); voiceKeyDraft = openAIKey()
        settingsMessage = nil; presentation = .settings; actionPage = 0; syncDisplay()
    }
    func closePresentation(_ expected: MendPresentation) {
        guard presentation == expected else { return }
        presentation = nil; actionPage = 0
        if expected == .settings { metaKeyDraft = ""; voiceKeyDraft = "" }
        if expected == .audioOutput {
            audioOutput.finishRouteSelection(keepSessionActive: voiceOpen)
            audioOutput.refresh()
            if !audioOutput.needsGlassesOutput, voice.isActive, !voiceRepliesPaused, !busy, !voiceReplyPending {
                if voiceNotice?.hasSuffix(GlassesAudioRoute.selectionRequiredMessage) == true { voiceNotice = nil }
                if let lastAnswer { voice.sayResult(MendResearchAnswer(text: lastAnswer, sources: answerSources).spokenText) }
                else { speakCurrentState() }
            }
        }
        syncDisplay()
    }

    var mainActions: [MendAction] {
        var actions: [MendAction] = []
        if busy || voiceReplyPending { actions.append(MendAction(id: .cancel, title: "Cancel")) }
        if !busy {
            switch stage {
            case .welcome:
                actions += [MendAction(id: .startProject, title: "Start project"), MendAction(id: .tryExample, title: "Try an example"), MendAction(id: .submitDetails, title: "Continue", enabled: !setupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)]
            case .capture:
                actions += photoActions
                actions += [MendAction(id: .submitDetails, title: "Add details", enabled: !setupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), MendAction(id: .reviewProject, title: "Review details", enabled: canConfirmProject)]
            case .confirmation:
                actions += [MendAction(id: .confirmProject, title: "Confirm", enabled: canConfirmProject), MendAction(id: .editProject, title: "Edit details")]
                actions += photoActions
            case .parts:
                actions += [MendAction(id: .confirmParts, title: "Ready"), MendAction(id: .reviewParts, title: "Check parts"), MendAction(id: .editProject, title: "Edit details")]
                actions += photoActions
            case .diagnosis:
                if diagnosis?.status == .ready {
                    actions.append(MendAction(id: .startGuide, title: "Start guide"))
                    actions.append(MendAction(id: .showParts, title: "Parts"))
                    actions += checklistMenuActions
                } else { actions += photoActions }
                actions += [MendAction(id: .moreDetails, title: "More details"), MendAction(id: .editProject, title: "Edit details")]
            case .guide:
                if stepIndex > 0 { actions.append(MendAction(id: .previousStep, title: "Previous step")) }
                if !isDemo {
                    actions.append(MendAction(id: .findExample, title: "Find example", enabled: !exampleImageLoading && !voiceReplyPending))
                }
                if stepExample != nil {
                    actions.append(MendAction(id: .exampleSource, title: "Example source", aliases: ["open example source"], enabled: !voiceReplyPending && !isDemo))
                }
                var aliases = ["checked", "i m done", "i am done", "okay i did that", "ok i did that", "finished this step"]
                if presentation == nil { aliases.append("done") }
                if stepIndex + 1 == diagnosis?.steps.count { aliases += ["finish", "finish repair"] }
                actions += [MendAction(id: .nextStep, title: "Complete", aliases: aliases), MendAction(id: .backToChecklist, title: "Back"), MendAction(id: .showChecklist, title: "Checklist"), MendAction(id: .askHelp, title: "Help with this step"), MendAction(id: .findTips, title: "Find tips"), MendAction(id: .moreDetails, title: "More details")]
                if !isDemo { actions += photoActions }
            case .complete:
                actions += [MendAction(id: .reviewSteps, title: "Review steps"), MendAction(id: .showChecklist, title: "Checklist"), MendAction(id: .askHelp, title: "Ask for help")]
                actions += checklistMenuActions
            }
        }
        if currentPhoto != nil, stage != .guide || stepExample == nil { actions.append(MendAction(id: .enlargePhoto, title: "Enlarge photo", enabled: !busy)) }
        actions += photoFocusActions
        if lastAnswer != nil && !actions.contains(where: { $0.id == .moreDetails }) {
            actions.append(MendAction(id: .moreDetails, title: "More details"))
        }
        if stage != .welcome { actions.append(MendAction(id: .newRepair, title: "New project")) }
        if !answerSources.isEmpty { actions.append(MendAction(id: .showSources, title: "Sources")) }
        actions += connectionActions
        actions += [MendAction(id: .compareDesigns, title: "Compare designs"), MendAction(id: .settings, title: "Settings"), MendAction(id: .previewDisplay, title: "Preview glasses display"), MendAction(id: .showActions, title: "Menu")]
        if errorMessage != nil { actions.append(MendAction(id: .clearError, title: "Dismiss error")) }
        actions += voiceActions + liveViewActions
        return actions
    }
    var photoFocusActions: [MendAction] {
        guard canFocusPhoto, presentation == .photo || stepExample == nil && showsStepCameraPhoto else { return [] }
        return [MendAction(id: photoIsFocused ? .showFullPhoto : .focusPhoto,
                           title: photoIsFocused ? "Full photo" : "Close-up", enabled: !busy)]
    }
    var photoActions: [MendAction] {
        [MendAction(id: .capture, title: "Take photo", enabled: !busy && !isDemo && !voiceStarting && !voiceStopping),
         MendAction(id: .choosePhoto, title: "Choose photo", enabled: !busy)] + (UIImagePickerController.isSourceTypeAvailable(.camera) ? [MendAction(id: .phoneCamera, title: "iPhone camera", enabled: !busy)] : [])
    }
    var connectionActions: [MendAction] {
        if glasses.registered {
            return [MendAction(id: .connect, title: "Start glasses session", enabled: !busy && !voiceStarting), MendAction(id: .disconnect, title: "Disconnect")]
        }
        return [MendAction(id: .register, title: "Connect through Meta AI", enabled: glasses.registrationReady && !busy)]
    }
    var voiceActions: [MendAction] {
        if voiceOpen {
            var actions = [MendAction(id: .stopVoice, title: voiceStopping ? "Ending voice" : "End voice", enabled: !voiceStopping)]
            if voice.isActive {
                if voice.listeningMode == .oneTurn {
                    actions.append(MendAction(id: voice.isListeningForTurn ? .muteMic : .talk,
                        title: voice.isListeningForTurn ? "Stop listening" : "Talk", enabled: !voiceStopping))
                } else {
                    actions.append(MendAction(id: voice.isMuted ? .unmuteMic : .muteMic,
                        title: voice.isMuted ? "Unmute mic" : "Mute mic", enabled: !voiceStopping))
                }
                actions.append(MendAction(id: voiceRepliesPaused ? .resumeReplies : .pauseReplies, title: voiceRepliesPaused ? "Resume replies" : "Pause replies"))
                actions.append(MendAction(id: .repeatStep, title: "Read this screen"))
                if presentation != .settings && presentation != .audioOutput {
                    actions.append(MendAction(id: .audioOutput, title: "Audio output", aliases: ["choose glasses", "glasses audio"]))
                }
                if voice.isSpeaking { actions.append(MendAction(id: .stopSpeaking, title: "Stop speaking")) }
            }
            return actions
        }
        return [MendAction(id: .startVoice, title: "Glasses", enabled: !busy && !audioOutput.testPlaying)]
    }
    var availableActions: [MendAction] {
        var actions: [MendAction]
        switch presentation {
        case .comparison:
            actions = [MendAction(id: .useFocus, title: "Focus"), MendAction(id: .useFlow, title: "Flow"),
                       MendAction(id: .useGuide, title: "Guide"), MendAction(id: .closeComparison, title: "Done")] + voiceActions
        case .settings:
            actions = [MendAction(id: .saveKey, title: "Save Meta key"), MendAction(id: .forgetKey, title: "Forget Meta key"),
                       MendAction(id: .saveVoiceKey, title: "Save OpenAI key"), MendAction(id: .forgetVoiceKey, title: "Forget OpenAI key"),
                       MendAction(id: .testSound, title: "Test sound", enabled: !busy && !audioOutput.testPlaying && !voice.captureSuspended),
                       MendAction(id: .audioOutput, title: "Audio output"), MendAction(id: .closeSettings, title: "Done")] + connectionActions + voiceActions
            if audioOutput.testPlaying { actions.append(MendAction(id: .stopSound, title: "Stop sound test")) }
        case .checklist: actions = checklistMenuActions + [MendAction(id: .closeChecklist, title: "Done")] + voiceActions
        case .sources: actions = sourceActions + [MendAction(id: .closeSources, title: "Done")] + voiceActions
        case .details:
            actions = [MendAction(id: .submitQuestion, title: "Ask", enabled: !helpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy && !voiceReplyPending), MendAction(id: .findTips, title: "Find tips", enabled: !busy && !voiceReplyPending), MendAction(id: .closeDetails, title: "Done")] + voiceActions
            if stage == .guide { actions += mainActions.filter { $0.id == .nextStep } }
            if !answerSources.isEmpty { actions.append(MendAction(id: .showSources, title: "Sources")) }
            if busy || voiceReplyPending { actions.append(MendAction(id: .cancel, title: "Cancel")) }
            if glassesPage > 0 { actions.append(MendAction(id: .back, title: "Previous page", aliases: ["back page"])) }
            if glassesPage + 1 < displayPages.count { actions.append(MendAction(id: .more, title: "More")) }
        case .preview: actions = [MendAction(id: .closePreview, title: "Done")] + voiceActions
        case .photo: actions = photoFocusActions + [MendAction(id: .closePhoto, title: "Done")] + voiceActions
        case .library, .camera, .audioOutput: actions = [MendAction(id: .closePicker, title: "Close")] + voiceActions
        case .actions:
            actions = mainActions.filter { $0.id != .showActions }
            actions.append(MendAction(id: .closeActions, title: "Done"))

        case nil:
            actions = mainActions
            if !showsInlineChecklist && !busy {
                if glassesPage + 1 < displayPages.count { actions.append(MendAction(id: .more, title: "More")) }
                if glassesPage > 0 { actions.append(MendAction(id: .back, title: "Previous page", aliases: ["back page"])) }
            }
        }
        for action in liveViewActions where !actions.contains(where: { $0.id == action.id }) { actions.append(action) }
        if stage == .guide, let presentation, [.photo, .sources, .preview].contains(presentation),
           let complete = mainActions.first(where: { $0.id == .nextStep }) {
            // Explicit "Step done" stays local while inspecting this step's image or sources.
            actions.append(complete)
        }
        if presentation == .details { actions += liveAnswerFocusActions }
        if presentation == nil, stage == .parts { actions += partsShoppingActions }
        if (busy || voiceReplyPending) && !actions.contains(where: { $0.id == .cancel }) {
            actions.append(MendAction(id: .cancel, title: "Cancel"))
        }
        return actions
    }
    private static var dismissActions: Set<MendActionID> { [.closeSettings, .closePhoto, .closePicker, .closePreview, .closeActions, .closeChecklist, .closeSources, .closeDetails, .closeComparison] }
    var menuActions: [MendAction] {
        let actions = mainActions.filter { $0.enabled && $0.id != .showActions && !MendActionID.stepIDs.contains($0.id) }
        let microphone = actions.filter { [.talk, .muteMic, .unmuteMic].contains($0.id) }
        return microphone + actions.filter { ![.talk, .muteMic, .unmuteMic].contains($0.id) }
    }
    /// Persistent action bar shared by all phone styles and native display cards.
    var bottomActions: [MendAction] {
        let available = availableActions
        let microphone: MendActionID = !voice.isActive ? .startVoice : voice.listeningMode == .oneTurn
            ? (voice.isListeningForTurn ? .muteMic : .talk) : (voice.isMuted ? .unmuteMic : .muteMic)
        var ids: [MendActionID]
        switch presentation {
        case .actions: ids = [.closeActions, microphone]
        case .settings: ids = [.closeSettings, microphone]
        case .comparison: ids = [.closeComparison, microphone]
        case .checklist: ids = [.closeChecklist, microphone]
        case .sources: ids = [.closeSources, microphone]
        case .details:
            ids = [busy || voiceReplyPending ? .cancel : (helpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .findTips : .submitQuestion), .closeDetails, microphone]
        case .photo: ids = [photoIsFocused ? .showFullPhoto : .focusPhoto, .closePhoto, microphone]
        case .preview: ids = [.closePreview, microphone]
        case .library, .camera, .audioOutput: ids = [.closePicker, microphone]
        case nil:
            if busy || voiceReplyPending { ids = [.cancel, microphone, .showActions] }
            else {
                switch stage {
                case .welcome: ids = [setupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .startProject : .submitDetails, microphone, .showActions]
                case .capture: ids = [!setupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .submitDetails : canConfirmProject ? .reviewProject : .capture, microphone, .showActions]
                case .confirmation: ids = [.confirmProject, microphone, .showActions]
                case .parts: ids = [setupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .confirmParts : .reviewParts, microphone, .showActions]
                case .diagnosis: ids = [diagnosis?.status == .ready ? .showParts : .editProject, microphone, .showActions]
                case .guide: ids = [.nextStep, .backToChecklist, voice.isActive ? microphone : .showActions]
                case .complete: ids = [.newRepair, microphone, .showActions]
                }
            }
        }
        return ids.compactMap { id in available.first { $0.id == id } }
    }
    var showsInlineChecklist: Bool { presentation == nil && stage == .diagnosis && diagnosis?.status == .ready && !busy && !voiceReplyPending }
    func isEnabled(_ id: MendActionID) -> Bool { availableActions.contains { $0.id == id && $0.enabled } }

    /// Every button and voice selection reaches this exact guarded dispatcher.
    func perform(_ requestedID: MendActionID) {
        let id: MendActionID = requestedID == .completeStep ? .nextStep : requestedID
        guard appActive, isEnabled(id) else { return }
        if ![.startLiveView, .pauseLiveView, .showLiveFullPhoto, .focusLivePhoto, .muteMic, .unmuteMic, .focusListening, .pauseReplies, .resumeReplies, .stopSpeaking, .more, .back, .moreDetails, .showSources, .audioOutput, .closePicker, .nextActions, .previousActions, .showFullPhoto, .focusPhoto, .compareDesigns, .closeComparison, .useFocus, .useFlow, .useGuide].contains(id) { cancelVoiceReply() }
        if ![.startLiveView, .pauseLiveView, .showLiveFullPhoto, .focusLivePhoto, .muteMic, .unmuteMic, .focusListening, .pauseReplies, .resumeReplies, .stopSpeaking, .showFullPhoto, .focusPhoto, .compareDesigns, .closeComparison, .useFocus, .useFlow, .useGuide].contains(id) { voice.interruptPlayback() }
        if presentation == .actions, ![.nextActions, .previousActions, .closeActions, .talk, .muteMic, .unmuteMic, .focusListening].contains(id) { presentation = nil; actionPage = 0 }
        if [.nextStep, .previousStep, .startGuide, .newRepair, .reviewSteps, .backToChecklist, .confirmParts, .showParts].contains(id) { presentation = nil; actionPage = 0 }
        if let index = MendActionID.stepIDs.firstIndex(of: id) { openChecklistStep(index); return }
        if let index = MendActionID.checkStepIDs.firstIndex(of: id) { toggleChecklistStep(index); return }
        if let index = MendActionID.sourceIDs.firstIndex(of: id) { openResearchSource(index); return }
        if let index = MendActionID.shoppingIDs.firstIndex(of: id) {
            guard let link = partsShoppingLinks.first(where: { $0.itemIndex == index }) else { return }
            openShoppingURL(link.url); return
        }
        switch id {
        case .findExample: loadStepExampleIfNeeded(retry: true, force: true)
        case .exampleSource: openCurrentExampleSource()
        case .startLiveView: startLiveView()
        case .pauseLiveView: pauseLiveView()
        case .showLiveFullPhoto: liveAnswerFocused = false
        case .focusLivePhoto: liveAnswerFocused = true
        case .compareDesigns: presentation = .comparison; actionPage = 0
        case .closeComparison: closePresentation(.comparison)
        case .useFocus, .useFlow, .useGuide:
            experience = id == .useFocus ? .focus : id == .useFlow ? .flow : .guide
            saveExperience(experience); presentation = nil; actionPage = 0
        case .startProject: startProject(); speakCurrentState()
        case .reviewProject: reviewProject()
        case .confirmProject: confirmProject()
        case .confirmParts: confirmParts()
        case .showParts: showParts()
        case .reviewParts:
            if Self.wantsResearch(setupText) || Self.isPartsQuestion(setupText) {
                let question = setupText; setupText = ""
                askQuestion(question, research: Self.wantsResearch(question))
            } else { reviewParts(text: setupText) }
        case .backToChecklist: backToChecklist()
        case .editProject: editProject()
        case .submitDetails: collectDetails(text: setupText)
        case .showChecklist: presentation = .checklist; actionPage = 0
        case .closeChecklist: closePresentation(.checklist)
        case .moreDetails: presentation = .details; glassesPageForDetails()
        case .closeDetails: closePresentation(.details)
        case .askHelp:
            presentation = .details; glassesPageForDetails()
            askQuestion(currentStep.map { "Explain the instruction \($0.title) in simple terms with one practical tip. Don’t skip any caution." } ?? "Help me understand this repair and what I should check next.")
        case .submitQuestion: askQuestion(helpText, research: Self.wantsResearch(helpText))
        case .findTips:
            presentation = .details; glassesPageForDetails()
            askQuestion(currentStep.map { "Find manufacturer guidance and practical tips for this instruction: \($0.title). \($0.instruction)" } ?? "Find guidance for this project and problem.", research: true)
        case .showSources: presentation = .sources; actionPage = 0
        case .closeSources: closePresentation(.sources)
        case .capture: capture()
        case .choosePhoto: presentation = .library; actionPage = 0
        case .phoneCamera: cameraSheetToken = photoContextToken; presentation = .camera; actionPage = 0
        case .identify: diagnose()
        case .startGuide: startGuide(); speakCurrentState()
        case .previousStep: previousStep(); speakCurrentState()
        case .nextStep: checkAndAdvance(); speakCurrentState()
        case .newRepair: newRepair(); speakCurrentState()
        case .reviewSteps: reviewSteps(); speakCurrentState()
        case .settings: openSettings()
        case .closeSettings: closePresentation(.settings)
        case .previewDisplay: presentation = .preview; actionPage = 0
        case .closePreview: closePresentation(.preview)
        case .enlargePhoto: presentation = .photo; actionPage = 0
        case .showFullPhoto: setPhotoFocused(false)
        case .focusPhoto: setPhotoFocused(true)
        case .closePhoto, .closePicker: if let shown = presentation { closePresentation(shown) }
        case .connect: glasses.connect(startCamera: false)
        case .register: Task { await glasses.register() }
        case .disconnect: pauseLiveView(); if busy { cancel() }; endVoice(); glasses.disconnect()
        case .tryExample: loadDemo(); speakCurrentState()
        case .startVoice: startVoice()
        case .stopVoice: endVoice()
        case .muteMic:
            heardSpeech = false; voiceUtteranceContext = nil
            voice.mute()
        case .unmuteMic:
            heardSpeech = false; voiceUtteranceContext = nil
            voice.unmute()
        case .talk:
            heardSpeech = false; voiceUtteranceContext = nil
            voiceNotice = nil
            voice.listenForOneTurn()
        case .focusListening: break // Retired wake-word toggle.
        case .pauseReplies: voiceRepliesPaused = true; voice.setOutputEnabled(false)
        case .resumeReplies: voiceRepliesPaused = false; voice.setOutputEnabled(true); voice.sayResult("Spoken replies are back on.")
        case .muteVoice, .unmuteVoice: break // These controls are intentionally not offered: microphone-off cannot be voice-resumed.
        case .repeatStep: speakCurrentState()
        case .stopSpeaking: voice.interruptPlayback()
        case .cancel: cancel(); voice.sayResult("Canceled.")
        case .clearError: errorMessage = nil
        case .saveKey:
            do { try MendKeyStore.save(metaKeyDraft); settingsMessage = "Meta key saved on this iPhone." } catch { settingsMessage = error.localizedDescription }
        case .forgetKey:
            do { try MendKeyStore.save(""); metaKeyDraft = ""; settingsMessage = "Meta key removed." } catch { settingsMessage = error.localizedDescription }
        case .saveVoiceKey:
            do { try writeResearchKey(voiceKeyDraft); voice.setOutputAPIKey(voiceKeyDraft); settingsMessage = "OpenAI key saved on this iPhone." } catch { settingsMessage = error.localizedDescription }
        case .forgetVoiceKey:
            do { try writeResearchKey(nil); voiceKeyDraft = ""; voice.setOutputAPIKey(""); settingsMessage = "OpenAI key removed." } catch { settingsMessage = error.localizedDescription }
        case .testSound: testSound()
        case .stopSound: stopSoundTest()
        case .audioOutput: showAudioOutput()
        case .showActions:
            presentation = .actions; actionPage = 0
            voice.sayResult("Available controls: " + menuActions.prefix(8).map(\.title).joined(separator: ", ") + (voice.listeningMode == .oneTurn ? ". Select a row, or tap Talk and say a label." : ". Say a label to choose it."))
        case .closeActions: closePresentation(.actions)
        case .nextActions: actionPage += 1
        case .previousActions: actionPage = max(0, actionPage - 1)
        case .more: glassesNext()
        case .back: glassesPrevious()
        default: break
        }
        syncDisplay()
    }

    func showAudioOutput() {
        metaKeyDraft = ""; voiceKeyDraft = ""
        prepareAudioOutputForSelection()
        presentation = .audioOutput; actionPage = 0
        syncDisplay()
    }

    func testSound() {
        guard appActive, audioTestTask == nil, !voice.captureSuspended else { return }
        let id = UUID(); audioTestID = id
        voice.setOutputEnabled(false)
        audioTestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.audioTestID == id {
                    self.audioTestTask = nil; self.voice.setOutputEnabled(!self.voiceRepliesPaused); self.syncDisplay()
                }
            }
            do {
                try await self.glasses.stopCameraAndWait()
                try Task.checkCancellation()
                try await self.audioOutput.testSound(keepSessionActive: self.voiceOpen)
            }
            catch is CancellationError { }
            catch { if self.audioTestID == id { self.settingsMessage = error.localizedDescription } }
        }
    }
    func stopSoundTest() {
        guard audioTestTask != nil || audioOutput.testPlaying else { return }
        audioTestID = UUID(); audioTestTask?.cancel(); audioTestTask = nil; audioOutput.cancelTest()
        voice.setOutputEnabled(!voiceRepliesPaused)
    }

    var sourceActions: [MendAction] {
        Array(answerSources.prefix(5).enumerated()).map { index, source in MendAction(id: MendActionID.sourceIDs[index], title: "Open source \(index + 1)", aliases: [source.title]) }
    }
    var partsShoppingActions: [MendAction] {
        partsShoppingLinks.compactMap { link in
            guard MendActionID.shoppingIDs.indices.contains(link.itemIndex) else { return nil }
            return MendAction(id: MendActionID.shoppingIDs[link.itemIndex], title: "Find \(link.title) on Amazon",
                aliases: ["Amazon item \(link.itemIndex + 1)", "shop item \(link.itemIndex + 1)"], enabled: !busy && !voiceReplyPending)
        }
    }
    func openPartsShoppingLink(_ index: Int) {
        guard MendActionID.shoppingIDs.indices.contains(index) else { return }
        perform(MendActionID.shoppingIDs[index])
    }
    func openSource(_ index: Int) {
        guard MendActionID.sourceIDs.indices.contains(index) else { return }
        perform(MendActionID.sourceIDs[index])
    }
    private func openResearchSource(_ index: Int) {
        guard answerSources.indices.contains(index) else { return }
        UIApplication.shared.open(answerSources[index].url)
    }

    func renderGlasses() {
        // Background callbacks may arrive after the microphone shuts down. Keep
        // their card passive until the phone app is in the foreground again.
        guard appActive else {
            let signature = "phone-app-disconnected"
            guard lastDisplaySignature != signature else { return }
            lastDisplaySignature = signature
            glasses.showCard(title: "Phone app disconnected", text: "Open the app to continue.",
                             image: nil, previous: false, next: false, actions: [], items: [],
                             staticRows: [], preferredActionID: nil)
            return
        }
        var title = "Your project", text = "", image = annotatedImage
        var actions = bottomActions
        var items: [MendAction] = []
        var staticRows: [String] = []
        let checklist = presentation == .checklist || showsInlineChecklist || (presentation == nil && stage == .complete)
        if checklist {
            title = "Checklist · \(checkedSteps.count)/\(diagnosis?.steps.count ?? 0)"
            items = checklistActions.map { action in
                let index = MendActionID.stepIDs.firstIndex(of: action.id) ?? 0
                let checked = diagnosis.map { checkedSteps.contains($0.steps[index].id) } == true
                return MendAction(id: action.id, title: (checked ? "✓ " : "○ ") + action.title, enabled: action.enabled)
            }
            image = nil
        } else if presentation == nil, stage == .parts {
            let pages = partsDisplayPages
            let page = min(glassesPage, pages.count - 1)
            title = "Parts & tools" + (pages.count > 1 ? " · \(page + 1)/\(pages.count)" : "")
            staticRows = pages[page].rows; text = pages[page].text; image = nil
        } else if presentation == .actions {
            title = "Menu"; items = menuActions; image = nil
        } else if let presentation {
            image = nil
            switch presentation {
            case .details:
                title = "Help"; text = displayPages[min(glassesPage, displayPages.count - 1)]; image = liveAnswerImage
                items = liveAnswerFocusActions + availableActions.filter { [.showSources, .nextStep].contains($0.id) }
            case .sources: title = "Sources"; items = sourceActions
            case .settings:
                title = "Settings"; text = "Enter keys privately on your iPhone."
                items = availableActions.filter { !Self.dismissActions.contains($0.id) && ![.startVoice, .talk, .muteMic, .unmuteMic, .saveKey, .saveVoiceKey, .forgetKey, .forgetVoiceKey].contains($0.id) }
            case .comparison: title = "Choose a design"; items = availableActions.filter { [.useFocus, .useFlow, .useGuide].contains($0.id) }
            case .photo: title = photoIsFocused ? "Close-up" : "Full photo"; image = annotatedImage
            case .audioOutput: title = "Glasses audio"; text = "Choose your glasses in the iPhone audio picker. " + audioOutput.routeName
            default: title = "On your iPhone"; text = "Continue on your iPhone."
            }
        } else {
            switch stage {
            case .welcome: title = "What should we work on today?"; image = nil
            case .capture: title = "Your project"
            case .confirmation: title = "Have I got it right?"
            case .parts: title = "Parts & tools"; image = nil
            case .diagnosis: title = "Your checklist"
            case .guide: title = "\(stepIndex + 1)/\(diagnosis?.steps.count ?? 0) · \(currentStep?.title ?? "Step")"
            case .complete: title = "All steps checked"
            }
            text = stage == .welcome ? "" : displayPages[min(glassesPage, displayPages.count - 1)]
        }
        // Reading pages never completes a step. The last page restores its actions.
        if (presentation == nil && !checklist || presentation == .details), !busy, !voiceReplyPending {
            let pages = displayPages
            if glassesPage + 1 < pages.count, let more = availableActions.first(where: { $0.id == .more }) {
                if actions.isEmpty { actions = [more] } else { actions[0] = more }
            }
            if glassesPage > 0, let back = availableActions.first(where: { $0.id == .back }) {
                // Keep the microphone control reachable on every native page.
                let micIDs: Set<MendActionID> = [.talk, .muteMic, .unmuteMic]
                if let index = actions.indices.first(where: { $0 > 0 && !micIDs.contains(actions[$0].id) }) {
                    actions[index] = back
                } else if actions.count < 3 { actions.append(back) }
            }
        }
        if presentation == nil, stage == .guide {
            if let example = stepExample {
                title = example.label + " · " + title
                image = example.image
            } else if !showsStepCameraPhoto {
                image = nil
            }
        }
        if let progressTitle { title = progressTitle; text = progressDetail; image = nil; items = []; staticRows = [] }
        let preferredActionID = items.first(where: \.enabled)?.id.rawValue
        // Keep native cards focused on the task. Microphone and camera status
        // remain on the phone; progress already appears once above.
        if isDemo && !(stage == .guide && stepExample != nil && presentation == nil) { title = "Example · " + title }
        let marker = (try? JSONEncoder().encode(currentMarker)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let actionSignature = (actions + items).map { $0.id.rawValue + $0.title + String($0.enabled) }.joined()
        let signature = [experience.rawValue, title, text, staticRows.joined(separator: "\n"),
                         currentPhoto?.id ?? "", liveAnswerPhoto?.id ?? "", String(liveAnswerFocused),
                         marker, String(photoIsFocused), actionSignature, preferredActionID ?? "",
                         stepExample?.source.url.absoluteString ?? "", stepExample?.caption ?? ""].joined()
        guard signature != lastDisplaySignature else { return }
        lastDisplaySignature = signature
        glasses.showCard(title: title, text: text, image: image, previous: false, next: false,
                         actions: actions.map { MendGlassesAction(id: $0.id.rawValue, label: $0.title, enabled: $0.enabled) },
                         items: items.map { MendGlassesAction(id: $0.id.rawValue, label: $0.title, enabled: $0.enabled) },
                         staticRows: staticRows, preferredActionID: preferredActionID)
    }
}

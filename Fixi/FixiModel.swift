import Foundation
import Observation
import UIKit

enum MendStage: String { case welcome, capture, confirmation, parts, diagnosis, guide, complete }
enum MendPresentation: String { case settings, preview, photo, actions, library, camera, audioOutput, checklist, sources, details, comparison }

@Observable @MainActor
final class FixiModel {
    let glasses: FixiGlasses
    let voice: any ConversationVoiceSession
    let audioOutput: AudioOutputMonitor
    var experience: MendExperience = .focus
    @ObservationIgnored var saveExperience: (MendExperience) -> Void = { _ in }
    var presentation: MendPresentation?
    var actionPage = 0
    var metaKeyDraft = ""
    var voiceKeyDraft = ""
    var settingsMessage: String?
    var voiceNotice: String?
    var voiceRepliesPaused = false
    var voiceStarting = false
    var voiceStopping = false
    var voiceReplyPending = false
    var heardSpeech = false
    var appActive = true
    var cameraSheetToken = ""
    @ObservationIgnored var voiceLifecycle: Task<Void, Never>?
    @ObservationIgnored var voiceReplyTask: Task<Void, Never>?
    @ObservationIgnored var voiceAudioRestore: Task<Void, Never>?
    @ObservationIgnored var audioTestTask: Task<Void, Never>?
    @ObservationIgnored var voiceGeneration = UUID()
    @ObservationIgnored var voiceReplyID = UUID()
    @ObservationIgnored var voiceUtteranceContext: String?
    @ObservationIgnored var voiceUtteranceWasSetup = false
    @ObservationIgnored var projectGeneration = UUID()
    @ObservationIgnored var voiceUtteranceProject: UUID?
    @ObservationIgnored var stepCompletionPromptContext: MendStepCompletionPrompt?
    @ObservationIgnored var voiceUtteranceCompletionPromptContext: MendStepCompletionPrompt?
    @ObservationIgnored var cameraAudioID = UUID()
    @ObservationIgnored var audioTestID = UUID()
    @ObservationIgnored var lastDisplaySignature = ""
    @ObservationIgnored var recentVoiceQuestions: [String] = []
    var liveViewEnabled = false
    @ObservationIgnored var voiceStartedLiveView = false
    var livePermissionHandoff = false
    var liveStatusVersion = 0
    var liveViewNotice: String?
    var livePreviewStatus: String?
    var liveOutputHeld = false
    var liveFrameAcquiring = false
    var liveQuestionUsesCamera = false
    var liveQuestionSubmitted = false
    var liveAnswer: MendLiveAnswer?
    var liveAnswerPhoto: MendPhoto?
    var liveAnswerFocused = true
    @ObservationIgnored var liveAnswerCache: (key: String, value: PhotoCanvas.Presentation)?
    @ObservationIgnored var liveViewGeneration = UUID()
    @ObservationIgnored var liveAcquisitionID = UUID()
    @ObservationIgnored var liveCameraLoop: Task<Void, Never>?
    @ObservationIgnored var acquireLivePhoto: (() async throws -> MendPhoto)?
    @ObservationIgnored var answerLiveQuestion: (String, MendProjectDetails, MendDiagnosis?, MendStep?, String, MendPhoto, String) async throws -> MendLiveAnswer = {
        try await MendLiveQuestionClient().answer(question: $0, details: $1, diagnosis: $2, step: $3, history: $4, photo: $5, key: $6)
    }
    @ObservationIgnored var researchQuestion: (String, MendProjectDetails, MendDiagnosis?, MendStep?, MendPhoto?, String) async throws -> MendResearchAnswer = {
        try await MendResearchClient().answer(question: $0, details: $1, diagnosis: $2, step: $3, key: $5, photo: $4)
    }
    var stage: MendStage = .welcome
    var project = MendProjectDetails()
    var problem: String { get { project.problem } set { project.problem = newValue } }
    var setupText = ""
    static let openingPrompt = "What should we work on today? Tell me the details and show me the project so I can create your step-by-step guide."
    var setupPrompt: String? = FixiModel.openingPrompt
    var helpText = ""
    var lastAnswer: String?
    var answerSources: [MendSource] = []
    var selectedHelpStepIndex: Int?
    var stepExample: MendExampleImage?
    var stepPhotoReference: MendStepPhotoReference?
    @ObservationIgnored var projectPhotos: [MendPhoto] = []
    @ObservationIgnored var stepVisualPreparation = MendStepVisualPreparation()
    @ObservationIgnored var stepCameraGuidance = MendStepCameraGuidance()
    @ObservationIgnored var locateStepCameraTarget: (MendPhoto, MendStep, String) async throws -> MendGrounding = {
        try await MendClient().locate(jpeg: $0.jpeg, photoID: $0.id, step: $1, key: $2)
    }
    @ObservationIgnored var waitForStepCameraGuidanceTimeout: () async throws -> Void = {
        try await Task.sleep(for: .seconds(60))
    }
    @ObservationIgnored var findPhotoGuides: (MendProjectDetails, [MendStep], [MendPhoto], String) async throws -> [MendStepPhotoReference] = {
        try await MendPhotoGuideClient().locate(details: $0, steps: $1, photos: $2, key: $3)
    }
    var exampleImageLoading = false
    var exampleImageNotice: String?
    @ObservationIgnored var waitForExampleImageTimeout: () async throws -> Void = { try await Task.sleep(for: .seconds(90)) }
    @ObservationIgnored var findExampleImage: (MendProjectDetails, MendStep, String) async throws -> MendExampleImage? = {
        try await MendExampleImageClient().find(details: $0, step: $1, key: $2)
    }
    @ObservationIgnored var openExampleURL: (URL) -> Void = { UIApplication.shared.open($0) }
    var confirmedProject: MendProjectDetails?
    var progressDetail = ""
    var replyLabel = "Thinking…"
    var workKind = ""
    @ObservationIgnored var feedbackTask: Task<Void, Never>?
    @ObservationIgnored var feedbackID = UUID()
    @ObservationIgnored var feedbackSpoken = false
    @ObservationIgnored var setupHistory = ""
    // Injectable service seams keep flow regression tests entirely offline.
    @ObservationIgnored var collectProject: (MendProjectDetails, String, Data?, String?, String) async throws -> MendIntakeResult = {
        try await MendIntakeClient().collect(current: $0, text: $1, jpeg: $2, photoID: $3, key: $4)
    }
    @ObservationIgnored var createPlan: (MendProjectDetails, Data?, String, String) async throws -> MendDiagnosis = {
        try await MendClient().plan(details: $0, jpeg: $1, photoID: $2, key: $3)
    }
    @ObservationIgnored var answerRepairQuestion: (String, MendProjectDetails, MendDiagnosis?, MendStep?, String, String) async throws -> String = {
        try await MendConversationClient().answer(question: $0,
            problem: "Make: \($1.make). Model: \($1.model). " + String($1.problem.prefix(1400)) +
                ($1.suggestedFields.isEmpty ? "" : " Best-guess fields: " + $1.suggestedFields.sorted().joined(separator: ", ") + "."),
            diagnosis: $2, step: $3, history: $4, key: $5)
    }
    @ObservationIgnored var modelKey: () -> String = { MendKeyStore.read() }
    @ObservationIgnored var openAIKey: () -> String = { OpenAIKeyStore.read() }
    @ObservationIgnored var prepareAudioOutputForSelection: () -> Void = {}
    @ObservationIgnored var writeResearchKey: (String?) throws -> Void = {
        if let value = $0 { try OpenAIKeyStore.save(value) }
        else { try OpenAIKeyStore.remove() }
    }
    var partsPhoto: MendPhoto?
    var partsIssues: [String] = []
    var partsMessage: String?
    var partsConfirmed = false
    var partsReviewPending: Bool { busy && workKind == "parts" }
    var partsItems: [String] { (diagnosis?.tools ?? []) + (diagnosis?.parts ?? []) }
    /// Short read-only lists fit as one card. Longer lists use bounded groups
    /// because DAT exposes no scrolling control for noninteractive content.
    var partsDisplayPages: [(rows: [String], text: String)] {
        var result: [(rows: [String], text: String)] = []
        var rows: [String] = []
        for item in partsItems {
            if !rows.isEmpty, rows.count >= 3 || rows.reduce(0, { $0 + $1.count }) + item.count > 240 {
                result.append((rows, "")); rows = []
            }
            rows.append(item)
        }
        if !rows.isEmpty { result.append((rows, "")) }
        if result.isEmpty { result = [([], "No extra parts or tools listed.")] }
        else if !partsShoppingLinks.isEmpty { result[0].text = "Shopping links are in the app." }
        for issue in partsIssues {
            result += Self.pages("Check: " + issue).map { ([], $0) }
        }
        return result
    }
    var partsShoppingLinks: [MendShoppingLink] {
        guard diagnosis?.status == .ready else { return [] }
        return MendShoppingLinks.make(tools: diagnosis?.tools ?? [], parts: diagnosis?.parts ?? [], confirmedProject: confirmedProject)
    }
    @ObservationIgnored var openShoppingURL: (URL) -> Void = { UIApplication.shared.open($0) }
    @ObservationIgnored var checkParts: (MendProjectDetails, MendDiagnosis, String, MendPhoto?, String) async throws -> MendPartsReview = {
        try await MendPartsClient().check(details: $0, diagnosis: $1, text: $2, photo: $3, key: $4)
    }
    private(set) var photo: MendPhoto?
    private(set) var diagnosis: MendDiagnosis?
    private(set) var stepIndex = 0
    private(set) var checkedSteps: Set<String> = []
    private(set) var busy = false
    private(set) var busyLabel = ""
    private(set) var isDemo = false
    var errorMessage: String?
    private(set) var groundingMessage: String?
    private(set) var glassesPage = 0
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var captureContext: (requestID: UUID, stepID: String?)?
    private var stepPhotos: [String: MendPhoto] = [:]
    private var stepMarkers: [String: PhotoMarker] = [:]
    private var refreshedSteps: Set<String> = []
    private var fullPhotoSelection: String?
    @ObservationIgnored private var photoPresentationCache: (key: String, value: PhotoCanvas.Presentation)?

    init(configurationError: String?, voiceSession: (any ConversationVoiceSession)? = nil, audioOutput: AudioOutputMonitor? = nil) {
        let controller = FixiGlasses(configurationError: configurationError)
        glasses = controller
        self.audioOutput = audioOutput ?? AudioOutputMonitor()
        voice = voiceSession ?? TranscriptVoiceSession(makeSpeechInput: { [weak controller] in
            guard let controller else { throw LiveVoiceError.message("The glasses connection is unavailable.") }
            return try await controller.makeSpeechInput()
        })
        glasses.onPhoto = { [weak self] data in self?.receiveGlassesPhoto(data) }
        glasses.onCaptureFailed = { [weak self] message in self?.captureFailed(message) }
        glasses.onNext = { [weak self] in self?.perform(.more) }
        glasses.onPrevious = { [weak self] in self?.perform(.back) }
        glasses.onNavigateBoundary = { [weak self] forward in self?.navigateGlassesBoundary(forward: forward) }
        glasses.onCapture = { [weak self] in self?.perform(.capture) }
        glasses.onAction = { [weak self] id in
            guard let action = MendActionID(rawValue: id) else { return }
            self?.perform(action)
        }
        prepareAudioOutputForSelection = { [weak monitor = self.audioOutput] in monitor?.prepareForRouteSelection() }
        configureVoice()
        glasses.onStateChange = { [weak self] in self?.syncDisplay() }
        self.audioOutput.onStateChange = { [weak self] in
            guard let self else { return }
            if !self.audioOutput.needsGlassesOutput, self.voiceNotice?.hasSuffix(GlassesAudioRoute.selectionRequiredMessage) == true {
                self.voiceNotice = nil
            }
            self.syncDisplay()
        }
        syncDisplay()
    }
    var currentStep: MendStep? {
        guard let diagnosis, diagnosis.steps.indices.contains(stepIndex) else { return nil }
        return diagnosis.steps[stepIndex]
    }
    var currentPhoto: MendPhoto? {
        if stage == .parts { return partsPhoto ?? photo }
        guard stage == .guide, let step = currentStep else { return photo }
        if let reference = stepPhotoReference, reference.stepID == step.id { return reference.photo }
        return stepPhotos[step.id] ?? photo
    }
    var currentMarker: PhotoMarker? {
        guard stage == .guide, let step = currentStep else { return nil }
        if let reference = stepPhotoReference, reference.stepID == step.id { return reference.marker }
        if refreshedSteps.contains(step.id) { return stepMarkers[step.id] }
        return step.requiresFreshPhoto == true ? nil : step.marker
    }
    var needsStepExample: Bool {
        stage == .guide && currentStep != nil && !hasStepPhotoTarget
    }
    var hasStepPhotoTarget: Bool {
        guard stage == .guide, let marker = currentMarker, let photo = currentPhoto,
              currentMarkerPhotoID == photo.id else { return false }
        return PhotoFocus.isValid(marker)
    }
    /// An unmarked project overview does not illustrate a repair step.
    var showsStepCameraPhoto: Bool {
        stage != .guide || (hasStepPhotoTarget && !stepPhotoManuallySuppressed)
    }
    /// Visual preparation is silent. Instructions remain usable without a picture.
    var stepVisualStatus: String? { nil }
    private var photoSelectionID: String { (currentPhoto?.id ?? "") + ":" + (currentStep?.id ?? "") }
    private var currentMarkerPhotoID: String? {
        guard stage == .guide, let step = currentStep else { return nil }
        if let reference = stepPhotoReference, reference.stepID == step.id { return reference.photo.id }
        return refreshedSteps.contains(step.id) ? stepPhotos[step.id]?.id : diagnosis?.photoID
    }
    private var photoPresentation: PhotoCanvas.Presentation? {
        guard let photo = currentPhoto else { return nil }
        let marker = (try? JSONEncoder().encode(currentMarker)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let focused = fullPhotoSelection != photoSelectionID
        let key = photoSelectionID + ":" + (currentMarkerPhotoID ?? "") + marker + String(focused)
        if photoPresentationCache?.key == key { return photoPresentationCache?.value }
        let value = PhotoCanvas.presentation(photo, marker: currentMarker, markerPhotoID: currentMarkerPhotoID, focused: focused)
        photoPresentationCache = (key, value)
        return value
    }
    var annotatedImage: UIImage? { photoPresentation?.image }
    var canFocusPhoto: Bool { photoPresentation?.canFocus == true }
    var photoIsFocused: Bool { photoPresentation?.isFocused == true }
    func setPhotoFocused(_ focused: Bool) { fullPhotoSelection = focused ? nil : photoSelectionID }

    /// Retain only deliberately supplied/used stills for this repair, not the
    /// continuous camera stream or downloaded example pictures.
    func rememberProjectPhoto(_ incoming: MendPhoto, prepare: Bool = true) {
        // Markers refer to the capture ID, even when two captures have identical pixels.
        guard !isDemo, !projectPhotos.contains(where: { $0.id == incoming.id }) else { return }
        cancelStepVisualPreparation()
        projectPhotos.append(incoming)
        if prepare { prepareStepVisuals() }
    }

    /// Known targets come from their original grounding result, independent of
    /// whichever cached reference happens to be selected on screen.
    func knownStepPhotoReferences() -> [MendStepPhotoReference] {
        guard let diagnosis else { return [] }
        return diagnosis.steps.compactMap { step in
            let source: MendPhoto?, marker: PhotoMarker?
            if refreshedSteps.contains(step.id) {
                source = stepPhotos[step.id]; marker = stepMarkers[step.id]
            } else {
                source = photo?.id == diagnosis.photoID ? photo : nil
                marker = step.requiresFreshPhoto == true ? nil : step.marker
            }
            guard let source, let marker, PhotoFocus.isValid(marker) else { return nil }
            return MendStepPhotoReference(stepID: step.id, photo: source, marker: marker)
        }
    }

    var hasKey: Bool { !modelKey().isEmpty }
    var canConfirmProject: Bool { project.isReady && !busy }
    var checklistActions: [MendAction] {
        guard let diagnosis, diagnosis.status == .ready else { return [] }
        return diagnosis.steps.enumerated().map { index, step in
            MendAction(id: MendActionID.stepIDs[index], title: "Step \(index + 1) · \(step.title)", aliases: [step.title, "step \(index + 1)", "show step \(index + 1)", "help with step \(index + 1)", "step " + Self.numberWords[index]], enabled: !busy)
        }
    }
    var checklistCompletionActions: [MendAction] {
        guard let diagnosis, diagnosis.status == .ready else { return [] }
        return diagnosis.steps.enumerated().map { index, step in
            let number = index + 1, word = Self.numberWords[index]
            let checked = checkedSteps.contains(step.id)
            let title = checked ? "Reopen step \(number)" : "Mark step \(number) done"
            let aliases = checked
                ? ["uncheck step \(number)", "uncheck step \(word)", "reopen step \(word)", "clear step \(number) check"]
                : ["check step \(number)", "check step \(word)", "step \(number) done", "step \(word) done", "mark step \(word) done", "complete step \(number)"]
            return MendAction(id: MendActionID.checkStepIDs[index], title: title, aliases: aliases, enabled: !busy)
        }
    }
    /// Each checklist row opens its step; completion is a deliberate detail action.
    var checklistMenuActions: [MendAction] { checklistActions }
    static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
    var photoContextToken: String { "\(requestID):\(stage.rawValue):\(currentStep?.id ?? "none")" }

    func capture() {
        guard appActive, !busy, !voiceStarting, !voiceStopping else { return }
        cancelStepCameraGuidance()
        cancelVoiceReply()
        if isDemo { errorMessage = "Start a new repair to capture a real problem."; return }
        guard glasses.registered else { errorMessage = "Connect Fixi through Meta AI first, or choose a photo."; return }
        holdVoiceForCamera()
        let id = UUID(); requestID = id
        captureContext = (id, stage == .guide ? currentStep?.id : nil)
        busy = true; busyLabel = "Opening camera…"; workKind = "capture"
        startFeedback("Taking a photo.")
        syncDisplay()
        if !glasses.streaming { glasses.connect() }
        request = Task { [weak self] in
            for _ in 0..<180 {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                if self.glasses.streaming {
                    self.busyLabel = "Taking photo…"; self.syncDisplay()
                    self.glasses.capturePhoto()
                    return
                }
                if let message = self.glasses.errorMessage, !self.glasses.requestingCameraPermission {
                    self.captureFailed(message); return
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            self?.captureFailed("The camera did not become ready. Check Meta AI and try again.")
        }
    }
    private func receiveGlassesPhoto(_ data: Data) {
        guard let context = captureContext, context.requestID == requestID,
              context.stepID == (stage == .guide ? currentStep?.id : nil) else { return }
        captureContext = nil; request?.cancel(); request = nil; busy = false; workKind = ""; finishFeedback()
        restoreVoiceAfterCamera()
        acceptPhoto(data, source: "Glasses camera")
    }
    private func captureFailed(_ message: String) {
        guard captureContext != nil else { return }
        captureContext = nil; request?.cancel(); request = nil; busy = false; workKind = ""; finishFeedback()
        restoreVoiceAfterCamera()
        errorMessage = message; syncDisplay()
        if [.welcome, .capture, .confirmation].contains(stage), !setupHistory.isEmpty {
            voiceNotice = "The photo failed, but I can still use what you said."
            collectDetails(text: "", includePhoto: false)
        }
    }
    func acceptPhoto(_ data: Data, source: String, expectedToken: String? = nil) {
        guard expectedToken == nil || expectedToken == photoContextToken else { return }
        guard !busy else { return }
        cancelStepCameraGuidance()
        cancelVoiceReply()
        do {
            let incoming = try MendPhoto.make(data: data, source: source)
            rememberProjectPhoto(incoming, prepare: false)
            if stage == .parts {
                partsPhoto = incoming
                prepareStepVisuals()
                reviewParts(photo: incoming)
            } else if stage == .guide, let step = currentStep {
                refreshStepPhoto(incoming, step: step)
            } else {
                resetAnalysis()
                photo = incoming; isDemo = false; stage = .capture
                collectDetails(text: "", includePhoto: true, useLivePhoto: false)
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func startProject() {
        guard !busy else { return }
        stage = .capture; setupPrompt = Self.openingPrompt
        syncDisplay()
    }
    func reviewProject() {
        guard canConfirmProject else { return }
        cancelVoiceReply(); presentation = nil; stage = .confirmation; glassesPage = 0
        syncDisplay(); speakCurrentState()
    }
    func editProject() {
        guard !busy else { return }
        cancelStepVisualPreparation(clearCache: true)
        cancelVoiceReply(); confirmedProject = nil; stage = .capture; presentation = nil
        setupPrompt = "Tell me what to change."; syncDisplay()
    }
    /// Intake never creates a guide. Missing information can arrive in any order.
    func collectDetails(text: String, includePhoto: Bool = true, useLivePhoto: Bool = true) {
        guard appActive, stage == .capture || stage == .confirmation || stage == .welcome else { return }
        guard !busy || workKind == "intake" || workKind == "capture" else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { setupHistory = String((setupHistory + "\n" + text).suffix(3000)) }
        // Native speech can finish while the camera is opening. Keep it for the
        // photo intake instead of dropping a description spoken during capture.
        if busy && workKind == "capture" { syncDisplay(); return }
        guard !setupHistory.isEmpty || (includePhoto && (photo != nil || liveViewEnabled)) else { reviewProject(); return }
        let key = modelKey()
        guard !key.isEmpty else { errorMessage = "Add your Meta key in Settings, or enter the three details below."; stage = .capture; syncDisplay(); return }
        cancelVoiceReply(); request?.cancel(); confirmedProject = nil
        let id = UUID(); requestID = id
        let snapshot = project, savedImage = includePhoto ? photo : nil, description = setupHistory
        let useLive = includePhoto && useLivePhoto && liveViewEnabled
        let liveGeneration = liveViewGeneration
        stage = .capture; busy = true; workKind = "intake"; busyLabel = useLive ? "Looking…" : savedImage == nil ? "Noting the details…" : "Checking your photo…"
        setupText = ""; errorMessage = nil; startFeedback("I’m checking the project details."); syncDisplay()
        request = Task { [weak self] in
            guard let self else { return }
            do {
                var image = savedImage
                if useLive {
                    do { image = try await self.freshLivePhoto() }
                    catch {
                        image = nil
                        self.liveViewNotice = "No fresh view. Using what you said."
                    }
                    guard self.requestID == id, !Task.isCancelled else { throw CancellationError() }
                    if !self.liveViewEnabled || self.liveViewGeneration != liveGeneration { image = nil }
                    if let image { self.photo = image; self.rememberProjectPhoto(image, prepare: false) }
                    self.busyLabel = image == nil ? "Noting the details…" : "Checking your view…"
                    self.syncDisplay()
                }
                let result = try await self.collectProject(snapshot, description, image?.jpeg, image?.id, key)
                guard !Task.isCancelled, self.requestID == id else { return }
                self.busy = false; self.workKind = ""; self.request = nil; self.finishFeedback()
                // A typed edit while extraction ran wins; never overwrite a newer field.
                var merged = result.details
                for (name, path) in [("make", \MendProjectDetails.make), ("model", \MendProjectDetails.model), ("problem", \MendProjectDetails.problem)] {
                    if self.project[keyPath: path] != snapshot[keyPath: path] || self.project.suggestedFields.contains(name) != snapshot.suggestedFields.contains(name) {
                        merged[keyPath: path] = self.project[keyPath: path]
                        if self.project.suggestedFields.contains(name) { merged.suggestedFields.insert(name) }
                        else { merged.suggestedFields.remove(name) }
                    }
                }
                self.project = merged; self.setupPrompt = result.prompt; self.setupHistory = ""
                self.stage = merged.isReady ? .confirmation : .capture
                self.glassesPage = 0; self.syncDisplay(); self.speakCurrentState()
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.busy = false; self.workKind = ""; self.request = nil; self.finishFeedback()
                let reason = String(error.localizedDescription.prefix(300))
                self.errorMessage = reason
                self.setupPrompt = reason
                self.syncDisplay()
                self.voice.sayResult("I couldn’t collect the details. " + reason)
            }
        }
    }
    /// Explicit confirmation is the only production route that generates steps.
    func confirmProject() {
        guard appActive, !busy, stage == .confirmation, project.isReady else { return }
        let key = modelKey()
        guard !key.isEmpty else { errorMessage = "Add your Meta Model API key in Settings."; syncDisplay(); return }
        cancelVoiceReply(); resetAnalysis(); confirmedProject = project
        let details = project, image = photo, id = UUID()
        requestID = id
        let photoID = image?.id ?? "text-project-" + id.uuidString
        busy = true; workKind = "plan"; busyLabel = "Building your steps…"
        errorMessage = nil; startFeedback("I’m building your checklist."); syncDisplay()
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.createPlan(details, image?.jpeg, photoID, key)
                guard !Task.isCancelled, self.requestID == id else { return }
                guard self.project == details else {
                    self.busy = false; self.workKind = ""; self.request = nil; self.finishFeedback()
                    self.confirmedProject = nil; self.stage = .capture; self.syncDisplay(); return
                }
                self.diagnosis = result; self.stage = result.status == .ready ? .parts : .diagnosis; self.busy = false; self.workKind = ""; self.request = nil
                self.finishFeedback(); self.glassesPage = 0; self.syncDisplay(); self.speakCurrentState()
                if result.status == .ready { self.prepareStepVisuals() }
                if result.status == .ready, let image { self.reviewParts(photo: image) }
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.busy = false; self.workKind = ""; self.request = nil; self.finishFeedback()
                let detailsChanged = self.project != details
                if detailsChanged { self.confirmedProject = nil; self.stage = .capture }
                self.errorMessage = error.localizedDescription; self.syncDisplay()
                self.voice.sayResult(detailsChanged
                    ? "I couldn’t build the steps. Check your updated project details, then review and confirm them."
                    : "I couldn’t build the steps. Please confirm the details again.")
            }
        }
    }
    // Compatibility for an old control: review intake, never bypass confirmation.
    func diagnose() { if stage == .confirmation { confirmProject() } else { collectDetails(text: setupText) } }

    private func refreshStepPhoto(_ incoming: MendPhoto, step: MendStep) {
        guard !isDemo else { errorMessage = "Start a new repair before analyzing a real photo."; return }
        let key = modelKey()
        guard !key.isEmpty else { errorMessage = "Add your Meta Model API key in Settings to update the step photo."; return }
        cancelExampleImage()
        let id = UUID(); requestID = id; busy = true; workKind = "grounding"; busyLabel = "Finding the part…"
        startFeedback("I’m finding the part in this photo.")
        // Clear the old marker immediately: a new photo must never inherit old coordinates.
        stepPhotos[step.id] = incoming; stepMarkers[step.id] = nil; refreshedSteps.insert(step.id)
        groundingMessage = nil
        syncDisplay()
        request = Task { [weak self] in
            do {
                let result = try await MendClient().locate(jpeg: incoming.jpeg, photoID: incoming.id, step: step, key: key)
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.stepMarkers[step.id] = result.marker
                self.groundingMessage = result.message
                if let marker = result.marker {
                    self.acceptForegroundStepPhotoTarget(stepID: step.id, photo: incoming, marker: marker)
                }
                self.busy = false; self.workKind = ""; self.request = nil; self.finishFeedback(); self.glassesPage = 0; self.syncDisplay()
                self.voice.sayResult(result.message)
                self.prepareStepVisuals()
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.busy = false; self.workKind = ""; self.request = nil; self.finishFeedback()
                self.groundingMessage = "The target has not been located in this photo. Try a clearer view."
                self.errorMessage = error.localizedDescription; self.syncDisplay()
                self.prepareStepVisuals()
            }
        }
    }
    /// Check only evidence actually supplied. An empty review is deliberately silent.
    func reviewParts(text: String = "", photo incoming: MendPhoto? = nil) {
        guard appActive, !busy, stage == .parts, let diagnosis, diagnosis.status == .ready else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = modelKey()
        guard !key.isEmpty else { partsMessage = "Add your Meta key in Settings to check parts."; syncDisplay(); return }
        // A new spoken inventory supersedes an older photo; never present it as a current view.
        let saved = incoming ?? (text.isEmpty ? partsPhoto : nil)
        let useLive = incoming == nil && liveViewEnabled
        guard saved != nil || useLive || !text.isEmpty else {
            partsMessage = "Show your parts or tell me what you have."; syncDisplay(); return
        }
        cancelVoiceReply(); request?.cancel()
        let id = UUID(), details = project, generation = liveViewGeneration
        requestID = id; busy = true; workKind = "parts"; busyLabel = "Checking parts…"
        partsMessage = nil; setupText = ""; syncDisplay()
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let image = useLive ? try await self.freshLivePhoto() : saved
                guard !Task.isCancelled, self.requestID == id,
                      !useLive || (self.liveViewEnabled && self.liveViewGeneration == generation) else { throw CancellationError() }
                if let image { self.rememberProjectPhoto(image) }
                let review = try await self.checkParts(details, diagnosis, text, image, key).validated(expectedPhotoID: image?.id)
                guard !Task.isCancelled, self.requestID == id else { return }
                self.busy = false; self.workKind = ""; self.request = nil
                guard self.project == details, self.stage == .parts else { self.syncDisplay(); return }
                self.partsPhoto = image ?? self.partsPhoto; self.partsIssues = review.issues
                if !review.issues.isEmpty { self.partsConfirmed = false; self.voice.sayResult(review.issues.joined(separator: " ")) }
                self.syncDisplay()
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.busy = false; self.workKind = ""; self.request = nil
                guard self.project == details, self.stage == .parts else { self.syncDisplay(); return }
                self.partsMessage = error is CancellationError ? "Parts check paused." : "Couldn’t check parts. Try another photo or describe the labels."
                self.syncDisplay()
            }
        }
    }
    func confirmParts() {
        guard !busy, stage == .parts, diagnosis?.status == .ready else { return }
        // Readiness is the wearer's confirmation, never an inferred visual guarantee.
        partsConfirmed = true; stage = .diagnosis; presentation = nil; glassesPage = 0
        syncDisplay(); speakCurrentState()
    }
    func showParts() {
        guard !busy, diagnosis?.status == .ready else { return }
        cancelVoiceReply(); clearStepHelp(); stage = .parts; presentation = nil; glassesPage = 0; syncDisplay()
    }
    func backToChecklist() {
        guard !busy, diagnosis?.status == .ready else { return }
        cancelVoiceReply(); stage = checkedSteps.count == diagnosis?.steps.count ? .complete : .diagnosis
        presentation = nil; glassesPage = 0; clearStepHelp(); syncDisplay()
    }

    func startGuide() {
        guard !busy, partsConfirmed, diagnosis?.status == .ready else { return }
        cancelVoiceReply()
        stage = .guide
        stepIndex = diagnosis?.steps.firstIndex(where: { !checkedSteps.contains($0.id) }) ?? 0
        glassesPage = 0; clearStepHelp(); syncDisplay(); loadStepExampleIfNeeded()
    }
    func checkAndAdvance() {
        guard !busy, stage == .guide, let step = currentStep, let diagnosis else { return }
        cancelVoiceReply()
        checkedSteps.insert(step.id); glassesPage = 0; groundingMessage = nil
        clearStepHelp()
        presentation = nil; actionPage = 0
        if checkedSteps.count == diagnosis.steps.count { stage = .complete }
        else {
            let after = diagnosis.steps.indices.filter { $0 > stepIndex }
            let before = diagnosis.steps.indices.filter { $0 <= stepIndex }
            if let next = (after + before).first(where: { !checkedSteps.contains(diagnosis.steps[$0].id) }) {
                stepIndex = next; stage = .guide
            } else { stage = .diagnosis }
        }
        syncDisplay()
        if stage == .guide { loadStepExampleIfNeeded() }
    }
    func previousStep() {
        guard !busy, stage == .guide, stepIndex > 0 else { return }
        cancelVoiceReply()
        stepIndex -= 1; glassesPage = 0; groundingMessage = nil; clearStepHelp(); syncDisplay()
        loadStepExampleIfNeeded()
    }
    func reviewSteps() { cancelVoiceReply(); stage = .diagnosis; stepIndex = 0; glassesPage = 0; clearStepHelp(); syncDisplay() }
    func selectChecklistStep(_ index: Int) {
        guard MendActionID.stepIDs.indices.contains(index) else { return }
        perform(MendActionID.stepIDs[index])
    }
    func toggleChecklistStepCompletion(_ index: Int) {
        guard MendActionID.checkStepIDs.indices.contains(index) else { return }
        perform(MendActionID.checkStepIDs[index])
    }
    /// Checking a row changes only its completion state. It never opens or advances
    /// a step, so inspecting a checklist cannot accidentally mark work complete.
    func toggleChecklistStep(_ index: Int) {
        guard !busy, let diagnosis, diagnosis.status == .ready, diagnosis.steps.indices.contains(index) else { return }
        cancelVoiceReply()
        let step = diagnosis.steps[index]
        if checkedSteps.contains(step.id) { checkedSteps.remove(step.id) }
        else { checkedSteps.insert(step.id) }
        if checkedSteps.count == diagnosis.steps.count {
            stage = .complete; presentation = nil; actionPage = 0; glassesPage = 0; clearStepHelp()
        } else if stage == .complete {
            stage = .diagnosis; glassesPage = 0
        }
        syncDisplay()
    }
    func openChecklistStep(_ index: Int) {
        guard !busy, partsConfirmed, let diagnosis, diagnosis.steps.indices.contains(index) else { return }
        cancelVoiceReply(); stage = .guide; stepIndex = index; glassesPage = 0; presentation = nil
        groundingMessage = nil; clearStepHelp(); syncDisplay(); speakCurrentState()
        loadStepExampleIfNeeded()
    }
    func clearStepHelp() {
        stepCompletionPromptContext = nil; voiceUtteranceCompletionPromptContext = nil
        cancelExampleImage(); clearLiveAnswer(); fullPhotoSelection = nil; lastAnswer = nil; answerSources = []; helpText = ""; selectedHelpStepIndex = nil
    }

    func cancel() {
        let wasCapturing = captureContext != nil
        if workKind == "intake" || workKind == "capture" { setupHistory = "" }
        captureContext = nil; requestID = UUID(); request?.cancel(); request = nil; busy = false; workKind = ""; finishFeedback()
        if wasCapturing { glasses.cancelCapture(); glasses.stopCamera() }
        if wasCapturing { restoreVoiceAfterCamera() }
        syncDisplay()
    }
    func newRepair() {
        // A new project keeps the current foreground conversation and its
        // camera choice. An explicitly paused camera stays paused.
        if !voice.isActive { pauseLiveView() }
        cancelVoiceReply()
        projectGeneration = UUID()
        projectPhotos = []
        voice.resetConversation()
        cancel(); resetAnalysis(); photo = nil; project = MendProjectDetails(); confirmedProject = nil; setupHistory = ""; setupText = ""; setupPrompt = Self.openingPrompt
        isDemo = false; stage = .welcome; clearStepHelp()
        errorMessage = nil; recentVoiceQuestions = []; presentation = nil; syncDisplay()
    }
    func resumeFromBackground() {
        livePermissionHandoff = false; appActive = true
        glasses.setCameraForeground(true)
        syncDisplay()
        prepareStepVisuals()
    }
    func pauseForBackground() {
        let authorizing = glasses.requestingCameraPermission || glasses.requestingVoicePermission
        if !authorizing { appActive = false }
        glasses.setCameraForeground(false)
        guard !authorizing else {
            livePermissionHandoff = true; syncDisplay(); return
        }
        appActive = false; pauseLiveView(notice: "Live view paused while the app is away."); stopSoundTest(); endVoice()
        cancelStepVisualPreparation()
        audioOutput.finishRouteSelection(keepSessionActive: false)
        if busy { cancel() }
        glasses.stopCamera()
        syncDisplay()
    }
    private func resetAnalysis() {
        cancelStepVisualPreparation(clearCache: true)
        cancelExampleImage()
        cancelVoiceReply()
        clearStepHelp()
        diagnosis = nil; checkedSteps = []; stepIndex = 0; glassesPage = 0
        partsPhoto = nil; partsIssues = []; partsMessage = nil; partsConfirmed = false
        stepPhotos = [:]; stepMarkers = [:]; refreshedSteps = []; groundingMessage = nil
    }

    /// All text is paged; no safety instruction is silently truncated for the display.
    static func pages(_ text: String, limit: Int = 170) -> [String] {
        var pages: [String] = []; var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if current.count + word.count + 1 > limit && !current.isEmpty { pages.append(current); current = "" }
            if word.count > limit {
                if !current.isEmpty { pages.append(current); current = "" }
                var rest = word
                while rest.count > limit { pages.append(String(rest.prefix(limit))); rest = String(rest.dropFirst(limit)) }
                current = rest
            } else { current += (current.isEmpty ? "" : " ") + word }
        }
        if !current.isEmpty { pages.append(current) }
        return pages.isEmpty ? [""] : pages
    }
    var displayPages: [String] {
        if presentation == .details {
            if let answer = lastAnswer {
                return Self.pages(MendResearchAnswer(text: answer, sources: answerSources).spokenText, limit: 150)
            }
            if stage == .guide, let step = currentStep {
                return ([step.instruction] + (step.caution.map { ["Care: " + $0] } ?? []) + ["Check: " + step.expectedResult]).flatMap { Self.pages($0, limit: 150) }
            }
            if let diagnosis { return ([diagnosis.summary] + diagnosis.precautions).flatMap { Self.pages($0, limit: 150) } }
        }
        switch stage {
        case .welcome: return ["What should we work on today?"]
        case .capture:
            let missing = project.missingFields.joined(separator: ", ")
            let values = [("make", project.make), ("model", project.model), ("problem", project.problem)]
                .filter { !$0.1.isEmpty }.map { project.suggestedFields.contains($0.0) ? $0.1 + "?" : $0.1 }
            let summary = values.joined(separator: " · ")
            let next = errorMessage != nil ? (setupPrompt ?? "Try describing it again.") : missing.isEmpty ? "Details ready. Review to continue." : (summary.isEmpty ? "Show me the project and tell me what you’d like to fix." : "A little more about the " + missing + " will help.")
            return Self.pages((summary.isEmpty ? "" : summary + "\n") + next)
        case .confirmation:
            return Self.pages((project.suggestedFields.isEmpty ? "" : "Best guess · please check\n") + "\(project.make) · \(project.model)\n\(project.problem)\nHave I got it right?")
        case .parts:
            return partsDisplayPages.map { ($0.rows + ($0.text.isEmpty ? [] : [$0.text])).joined(separator: "\n") }
        case .diagnosis:
            guard let d = diagnosis else { return ["No steps yet."] }
            if d.status != .ready { return (d.questions.isEmpty ? [d.summary] : [d.summary] + d.questions).flatMap { Self.pages($0) } }
            let sections = ["\(d.steps.count) steps · " + d.title] + (d.tools.isEmpty ? [] : ["Tools: " + d.tools.joined(separator: ", ")]) + d.precautions.map { "Before starting: " + $0 }
            return sections.flatMap { Self.pages($0) }
        case .guide:
            guard let s = currentStep else { return ["No step available."] }
            var sections = [s.instruction]
            if let caution = s.caution { sections.append("Care: " + caution) }
            sections.append("Check: " + s.expectedResult)
            return sections.flatMap { Self.pages($0) }
        case .complete: return ["All steps checked. Test the result."]
        }
    }
    func syncDisplay() {
        voice.sendContext(voiceContext)
        renderGlasses()
        updateStepCameraGuidance()
    }
    func glassesPageForDetails() { glassesPage = 0; actionPage = 0 }
    /// A swipe past the last control changes the view, never checks work off
    /// or substitutes for the user's project/parts confirmation.
    func navigateGlassesBoundary(forward: Bool) {
        guard appActive, !busy, !voiceReplyPending else { return }
        let checklist = presentation == .checklist || showsInlineChecklist || (presentation == nil && stage == .complete)
        let paged = presentation == .details || (presentation == nil && !checklist)
        if paged {
            if forward, glassesPage + 1 < displayPages.count {
                glassesPage += 1; syncDisplay(); return
            }
            if !forward, glassesPage > 0 {
                glassesPage -= 1; syncDisplay(); return
            }
        }
        if let presentation {
            glassesPage = 0
            closePresentation(presentation)
            return
        }
        switch stage {
        case .welcome:
            if forward { glassesPage = 0; startProject() }
        case .capture:
            if forward { if canConfirmProject { reviewProject() } }
            else { stage = .welcome; glassesPage = 0; syncDisplay() }
        case .confirmation:
            if !forward { glassesPage = 0; editProject() }
            else if diagnosis?.status == .ready, confirmedProject == project { showParts() }
        case .parts:
            if forward { if partsConfirmed { backToChecklist() } }
            else { reviewProject() }
        case .diagnosis:
            if diagnosis?.status == .ready {
                if forward { openChecklistStep(0) } else { showParts() }
            } else if !forward { reviewProject() }
        case .guide:
            let nextIndex = stepIndex + (forward ? 1 : -1)
            if diagnosis?.steps.indices.contains(nextIndex) == true { openChecklistStep(nextIndex) }
            else { backToChecklist() }
        case .complete:
            if !forward { reviewSteps() }
        }
    }
    func glassesNext() {
        guard !busy else { return }
        if glassesPage + 1 < displayPages.count { glassesPage += 1; syncDisplay(); return }
        if presentation == .details { return }
        switch stage {
        case .diagnosis: startGuide()
        case .guide: checkAndAdvance()
        case .complete: newRepair()
        case .capture: reviewProject()
        case .welcome: startProject()
        case .confirmation: confirmProject()
        case .parts: confirmParts()
        }
    }
    func glassesPrevious() {
        guard !busy else { return }
        if glassesPage > 0 { glassesPage -= 1; syncDisplay() } else { previousStep() }
    }
    func loadDemo() {
        pauseLiveView()
        projectGeneration = UUID()
        projectPhotos = []
        voice.resetConversation()
        cancel(); resetAnalysis(); isDemo = true
        let image = PhotoCanvas.examplePhoto()
        photo = MendPhoto(id: "demo-hinge", jpeg: image.jpegData(compressionQuality: 0.9)!, image: image, source: "Illustrated example", capturedAt: Date())
        project = MendProjectDetails(make: "Unknown", model: "Cabinet hinge", problem: "The cabinet door feels loose.")
        confirmedProject = project
        diagnosis = MendDiagnosis(photoID: "demo-hinge", status: .ready, title: "A loose cabinet hinge", summary: "Example: a loose mounting screw may let a cabinet door wobble. Confirm the hinge and screw match your cabinet before starting.", evidence: ["The example highlights the hinge mounting screws."], confidence: .medium, questions: [], tools: ["Correct-size Phillips screwdriver"], precautions: ["Support the door. Stop if the hinge is damaged or the screw spins without tightening."], steps: [
            MendStep(id: "support", title: "Support the door", instruction: "Hold the door steady so its weight is not pulling on the hinge.", expectedResult: "The door stays supported while you work.", caution: "Ask someone to help if the door is heavy.", marker: PhotoMarker(kind: "circle", x: 0.48, y: 0.14, width: 0.35, height: 0.71, endX: nil, endY: nil, label: "Support this door")),
            MendStep(id: "tighten", title: "Tighten the loose screw", instruction: "Fit the screwdriver into the highlighted mounting screw. Turn gently clockwise until snug.", expectedResult: "The screw feels snug and the hinge no longer moves at that mounting point.", caution: "Do not force it. Stop if the screw spins freely.", marker: PhotoMarker(kind: "arrow", x: 0.76, y: 0.26, width: nil, height: nil, endX: 0.567, endY: 0.425, label: "Mounting screw")),
            MendStep(id: "check", title: "Check the door", instruction: "Keep supporting the door, then open and close it slowly to check the hinge.", expectedResult: "The door moves smoothly and the hinge stays secure. If it is still loose, stop and reassess.", caution: nil, marker: PhotoMarker(kind: "circle", x: 0.35, y: 0.33, width: 0.27, height: 0.30, endX: nil, endY: nil, label: "Check the hinge"))
        ])
        stage = .diagnosis; partsConfirmed = true; glassesPage = 0
        // The labeled example can be controlled by the same voice/gesture actions.
        syncDisplay()
    }
#if DEBUG
    func previewSavedStepPhoto() {
        loadDemo(); openChecklistStep(1)
        guard let original = photo, let step = currentStep, let marker = currentMarker else { return }
        let earlier = MendPhoto(id: "preview-earlier-photo", jpeg: original.jpeg, image: original.image,
                                source: "Illustrated example", capturedAt: Date().addingTimeInterval(-300))
        stepPhotoReference = MendStepPhotoReference(stepID: step.id, photo: earlier, marker: marker)
        syncDisplay()
    }
    /// Generated hinge artwork only: no camera, web lookup, or API request.
    func previewMissingStepImage(loading: Bool) {
        previewStepExample()
        stepExample = nil
        exampleImageLoading = loading
        exampleImageNotice = loading ? nil : "No matching example found. Show the part or try Find example."
        syncDisplay()
    }
    func previewTinyDot(fullPhoto: Bool = false) {
        loadDemo()
        guard let fixture = diagnosis, fixture.steps.indices.contains(1) else { return }
        var steps = fixture.steps
        let original = steps[1]
        steps[1] = MendStep(id: original.id, title: original.title,
            instruction: "The dot marks the mounting screw. Fit the screwdriver and turn gently clockwise until snug.",
            expectedResult: original.expectedResult, caution: original.caution,
            marker: PhotoMarker(kind: "dot", x: 544.0 / 960.0, y: 272.0 / 640.0,
                                width: nil, height: nil, endX: nil, endY: nil, label: "Mounting screw"))
        diagnosis = MendDiagnosis(photoID: fixture.photoID, status: fixture.status, title: fixture.title,
            summary: fixture.summary, evidence: fixture.evidence, confidence: fixture.confidence,
            questions: fixture.questions, tools: fixture.tools, precautions: fixture.precautions,
            steps: steps, parts: fixture.parts)
        stepIndex = 1; stage = .guide; presentation = nil; glassesPage = 0
        setPhotoFocused(!fullPhoto)
        syncDisplay()
    }

    /// Exercises the production reference-image layout with explicitly labeled
    /// local illustration data. No remote source is fetched by this preview.
    func previewStepExample() {
        loadDemo()
        guard let fixture = diagnosis else { return }
        let step = MendStep(id: "preview-example", title: "Find the mounting screw",
            instruction: "Use the example to identify the mounting screw on your hinge.",
            expectedResult: "You can identify the matching screw.", caution: "Keep the door supported.",
            marker: nil, photoHint: "Show your hinge for a precise marker.", requiresFreshPhoto: true)
        diagnosis = MendDiagnosis(photoID: fixture.photoID, status: fixture.status, title: fixture.title,
            summary: fixture.summary, evidence: fixture.evidence, confidence: fixture.confidence,
            questions: fixture.questions, tools: fixture.tools, precautions: fixture.precautions,
            steps: [step], parts: fixture.parts)
        photo = nil; stepIndex = 0; stage = .guide; presentation = nil; glassesPage = 0
        stepExample = MendExampleImage(image: PhotoCanvas.examplePhoto(),
            source: MendSource(title: "Local illustration · interface preview", url: URL(string: "https://example.org/illustration")!),
            caption: "Interface preview — local illustration")
        syncDisplay()
    }

    func previewLongChecklist() {
        loadDemo()
        guard let fixture = diagnosis else { return }
        let titles = ["Support the door", "Look at the upper hinge", "Look at the lower hinge", "Match the screwdriver", "Find the loose mounting screw", "Tighten the mounting screw", "Check the remaining mounts", "Open and close the door", "Compare the door gap", "Listen for rubbing", "Recheck the hinge", "Review the result"]
        let steps = titles.enumerated().map { index, title in
            MendStep(id: "preview-\(index)", title: title, instruction: "Example step \(index + 1). This fixture demonstrates a longer checklist.", expectedResult: "Review this example row.", caution: nil, marker: nil)
        }
        diagnosis = MendDiagnosis(photoID: fixture.photoID, status: .ready, title: "A longer example checklist", summary: fixture.summary, evidence: fixture.evidence, confidence: fixture.confidence, questions: [], tools: fixture.tools, precautions: fixture.precautions, steps: steps, parts: [])
        checkedSteps = ["preview-0", "preview-1"]; stage = .diagnosis; syncDisplay()
    }
#endif

}

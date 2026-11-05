import SwiftUI
import MWDATCore

@main
struct FixiApp: App {
    @State private var model: FixiModel
#if DEBUG
    private let intakeProbeRunID: String?
    private let localSpeechCheckRunID: String?
#endif
    init() {
        let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
        let previewScreen = arguments.first(where: { $0.hasPrefix("--preview-screen=") })?.components(separatedBy: "=").last
#else
        let previewScreen: String? = nil
#endif
        let preview = arguments.contains("--demo") || previewScreen != nil
        let testing = NSClassFromString("XCTestCase") != nil
#if DEBUG
        intakeProbeRunID = MendIntakeProbe.requestedRunID
        localSpeechCheckRunID = MendLocalSpeechCheck.requestedRunID
        let probing = intakeProbeRunID != nil || localSpeechCheckRunID != nil
#else
        let probing = false
#endif
        var error: NSError?
        if !preview && !testing && !probing { ObjC_Wearables.configure(&error) }
        _model = State(initialValue: FixiModel(configurationError: preview || testing || probing ? "Preview mode" : error?.localizedDescription))
        let activeModel = _model.wrappedValue
        activeModel.experience = MendExperience(rawValue: UserDefaults.standard.string(forKey: "MendSight.experience") ?? "") ?? .focus
        activeModel.saveExperience = { UserDefaults.standard.set($0.rawValue, forKey: "MendSight.experience") }
#if DEBUG
        if let choice = arguments.first(where: { $0.hasPrefix("--preview-style=") })?.components(separatedBy: "=").last,
           let experience = MendExperience(rawValue: choice) { activeModel.experience = experience }
#endif
        if preview {
            let model = _model.wrappedValue
            switch previewScreen {
            case "welcome": break
            case "capture": model.startProject()
            case "thinking": model.startProject(); model.voiceReplyPending = true; model.replyLabel = "Thinking…"
            case "comparison": model.presentation = .comparison
            case "confirmation": model.loadDemo(); model.stage = .confirmation; model.confirmedProject = nil
#if DEBUG
            case "menu": model.loadDemo(); model.presentation = .actions
            case "example-loading": model.previewMissingStepImage(loading: true)
            case "example-unavailable": model.previewMissingStepImage(loading: false)
            case "saved-photo": model.previewSavedStepPhoto()
            case "dot": model.previewTinyDot()
            case "dot-full": model.previewTinyDot(fullPhoto: true)
            case "step-example": model.previewStepExample()
            case "parts":
                model.loadDemo(); model.stage = .parts; model.partsConfirmed = false
            case "checklist-long": model.previewLongChecklist()
            case "live-view": model.previewLiveView(answer: false)
            case "live-answer": model.previewLiveView(answer: true)
#endif
            case "step", "full-photo":
                model.loadDemo(); model.openChecklistStep(1)
                if previewScreen == "full-photo" { model.setPhotoFocused(false) }
            default: model.loadDemo()
            }
            model.syncDisplay()
        }
    }
    var body: some Scene {
        WindowGroup {
            FixiView(model: model)
                .preferredColorScheme(.dark)
                .tint(MendTheme.mint)
                .task {
#if DEBUG
                    if let localSpeechCheckRunID { await MendLocalSpeechCheck.run(id: localSpeechCheckRunID, model: model) }
                    else if let intakeProbeRunID { await MendIntakeProbe.run(id: intakeProbeRunID, model: model) }
#endif
                }
                .onOpenURL { url in
                    guard url.scheme == "mendsight",
                          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                            .contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
                    Task { await model.glasses.handleURL(url) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    model.pauseForBackground()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    model.resumeFromBackground()
                }
        }
    }
}

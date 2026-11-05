import Foundation

/// The same IDs drive touch, glasses gestures, and explicit spoken button selections.
enum MendActionID: String, Codable, CaseIterable {
    case findExample, exampleSource
    case confirmParts, showParts, reviewParts, backToChecklist
    case startLiveView, pauseLiveView, showLiveFullPhoto, focusLivePhoto
    case compareDesigns, closeComparison, useFocus, useFlow, useGuide
    case capture, choosePhoto, phoneCamera, identify, startGuide, previousStep, nextStep
    case newRepair, reviewSteps, settings, closeSettings, previewDisplay, closePreview
    case enlargePhoto, closePhoto, showFullPhoto, focusPhoto, connect, register, disconnect, tryExample
    case startVoice, muteVoice, unmuteVoice, stopVoice, repeatStep, stopSpeaking
    case muteMic, unmuteMic, focusListening, talk
    case cancel, clearError, saveKey, forgetKey, saveVoiceKey, forgetVoiceKey
    case testSound, stopSound, audioOutput, showActions, more, back
    case pauseReplies, resumeReplies, closeActions, nextActions, previousActions, closePicker
    case startProject, reviewProject, confirmProject, editProject, submitDetails, showChecklist, closeChecklist
    case completeStep, askHelp, moreDetails, findTips, showSources, closeSources, closeDetails, submitQuestion
    case step1, step2, step3, step4, step5, step6, step7, step8, step9, step10, step11, step12
    case checkStep1, checkStep2, checkStep3, checkStep4, checkStep5, checkStep6, checkStep7, checkStep8, checkStep9, checkStep10, checkStep11, checkStep12
    case source1, source2, source3, source4, source5
    case shop1, shop2, shop3, shop4, shop5, shop6, shop7, shop8, shop9, shop10, shop11, shop12
    case shop13, shop14, shop15, shop16, shop17, shop18, shop19, shop20, shop21, shop22, shop23, shop24
    static let stepIDs: [Self] = [.step1,.step2,.step3,.step4,.step5,.step6,.step7,.step8,.step9,.step10,.step11,.step12]
    static let checkStepIDs: [Self] = [.checkStep1,.checkStep2,.checkStep3,.checkStep4,.checkStep5,.checkStep6,.checkStep7,.checkStep8,.checkStep9,.checkStep10,.checkStep11,.checkStep12]
    static let sourceIDs: [Self] = [.source1,.source2,.source3,.source4,.source5]
    static let shoppingIDs: [Self] = [.shop1,.shop2,.shop3,.shop4,.shop5,.shop6,.shop7,.shop8,.shop9,.shop10,.shop11,.shop12,
        .shop13,.shop14,.shop15,.shop16,.shop17,.shop18,.shop19,.shop20,.shop21,.shop22,.shop23,.shop24]
}

struct MendAction: Identifiable, Equatable {
    let id: MendActionID
    let title: String
    let aliases: [String]
    let enabled: Bool

    init(id: MendActionID, title: String, aliases: [String] = [], enabled: Bool = true) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.enabled = enabled
    }
}

enum MendVoiceResolution: Equatable {
    case action(MendActionID)
    case help
    case unmatched
}

struct MendStepCompletionPrompt: Equatable {
    let context: String
    let allowsBareAffirmation: Bool
}

enum MendVoiceActions {
    private static let naturalStepCompletionPhrases = [
        "i m done", "i am done", "i m finished", "i am finished", "i was done", "i was finished",
        "i m all done", "i am all done", "i ve finished", "i have finished", "i finished",
        "i ve completed it", "i have completed it", "i completed it", "i finished it",
        "i m done with this step", "i am done with this step", "i m finished with this step", "i am finished with this step"
    ]
    private static let explicitStepCompletionPhrases = [
        "step done", "step complete", "step completed", "done with this step", "done with the step",
        "this step is done", "the step is done", "this step is complete", "the step is complete",
        "i completed this step", "i completed the step", "i finished this step", "i finished the step",
        "i have completed this step", "i have completed the step", "i have finished this step", "i have finished the step",
        "i ve completed this step", "i ve completed the step", "i ve finished this step", "i ve finished the step",
        "complete step", "complete this step", "complete the step", "mark this step complete", "mark the step complete",
        "mark this step as complete", "mark the step as complete", "mark this step done", "mark the step done"
    ] + naturalStepCompletionPhrases.flatMap { phrase in
        [phrase, "yes " + phrase, "yeah " + phrase, "yep " + phrase, "okay " + phrase]
    }

    /// Recognizes completion intent even where no step control is available, so
    /// the coordinator can explain that locally instead of asking the AI to act.
    /// Bare navigation and modal dismissal words are deliberately not included.
    static func isExplicitStepCompletion(_ text: String) -> Bool {
        let completion = MendAction(id: .completeStep, title: "Step done", aliases: explicitStepCompletionPhrases)
        return resolve(text, available: [completion]) == .action(.completeStep)
    }

    /// These short answers need a specific, current completion question. They
    /// are never aliases on a normal step control or project confirmation.
    static func isStepCompletionAffirmation(_ text: String) -> Bool {
        let answer = MendAction(id: .completeStep, title: "Yes", aliases: ["yeah", "yep", "yup"] + completionSelfReports)
        return resolve(text, available: [answer]) == .action(.completeStep)
    }

    /// "Tell me when you have finished" invites a self-report, while a bare
    /// "yes" could simply acknowledge the instruction and must not check it off.
    static func isStepCompletionSelfReport(_ text: String) -> Bool {
        let answer = MendAction(id: .completeStep, title: "I am", aliases: completionSelfReports)
        return resolve(text, available: [answer]) == .action(.completeStep)
    }

    private static let completionSelfReports = [
            "i am", "i was", "i did", "i have",
            "yes i am", "yes i was", "yes i did", "yes i have",
            "yeah i am", "yeah i was", "yep i am", "yep i was"
    ]

    /// Inspect the last question, not merely a completion word anywhere in an
    /// answer. A later question about help or tools must own a following "yes".
    static func asksForStepCompletion(_ text: String) -> Bool {
        guard text.count <= 12_000 else { return false }
        let clauses = text.split(whereSeparator: { ".!?\n".contains($0) })
        var lastQuestion: String?
        var offset = text.startIndex
        for clause in clauses {
            guard let range = text.range(of: String(clause), range: offset..<text.endIndex) else { continue }
            offset = range.upperBound
            if offset < text.endIndex, text[offset] == "?" { lastQuestion = normalized(String(clause)) }
        }
        guard var question = lastQuestion else { return false }
        for prefix in ["and ", "so ", "okay ", "ok "] where question.hasPrefix(prefix) {
            question = String(question.dropFirst(prefix.count))
        }
        let directQuestions: Set<String> = [
            "are you done", "are you finished", "are you all done", "were you done", "were you finished",
            "have you finished", "have you completed it", "did you finish", "did you complete it",
            "did you finish it", "have you finished it", "have you done it", "have you done that"
        ]
        if directQuestions.contains(question) { return true }
        let subjects = ["this step", "the step", "that step", "it", "that"]
        for subject in subjects {
            if ["are you done with ", "are you finished with ", "have you finished ", "have you completed ",
                "did you finish ", "did you complete ", "have you done "].contains(where: { question == $0 + subject }) { return true }
            if ["done", "complete", "completed", "finished"].contains(where: { question == "is " + subject + " " + $0 }) { return true }
        }
        return false
    }

    /// A transcript is an action only when the entire utterance names one currently
    /// available control. Never infer actions from conversational or model text.
    static func resolve(_ text: String, available: [MendAction]) -> MendVoiceResolution {
        guard text.count <= 300, !containsUnsafeSyntax(text) else { return .unmatched }
        let spoken = normalized(text)
        guard !spoken.isEmpty else { return .unmatched }

        var candidates = Set([spoken])
        let polite = removingPlease(spoken)
        candidates.insert(polite)
        for prefix in ["tap ", "select ", "press ", "choose "] where polite.hasPrefix(prefix) {
            let selection = removingPlease(String(polite.dropFirst(prefix.count)))
            candidates.insert(selection)
            if selection.hasPrefix("the ") { candidates.insert(String(selection.dropFirst(4))) }
        }
        // "Select the next button" is still an exact control selection.
        for candidate in Array(candidates) where candidate.hasSuffix(" button") {
            candidates.insert(String(candidate.dropLast(7)))
        }

        var matched = Set<MendActionID>()
        for action in available where action.enabled {
            let names = Set(([action.title] + action.aliases + aliases(for: action.id)).map(normalized))
            if !candidates.intersection(names).isEmpty { matched.insert(action.id) }
        }
        // A label and another control's alias must never silently choose a winner.
        if matched.count > 1 { return .unmatched }
        if let action = matched.first { return .action(action) }
        let help: Set<String> = ["help", "voice help", "help with voice", "voice commands", "available commands"]
        return candidates.isDisjoint(with: help) ? .unmatched : .help
    }

    private static func normalized(_ text: String) -> String {
        let lowercase = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = lowercase.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return words.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func removingPlease(_ text: String) -> String {
        var value = text
        if value.hasPrefix("please ") { value = String(value.dropFirst(7)) }
        if value.hasSuffix(" please") { value = String(value.dropLast(7)) }
        return value
    }

    private static func containsUnsafeSyntax(_ text: String) -> Bool {
        // Quotes and question marks indicate discussion about a control rather than
        // a direct selection. Apostrophes remain available for contraction checks.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(where: { "?\"“”„«»‘`".contains($0) }) || trimmed.hasPrefix("'") || trimmed.hasSuffix("'") || trimmed.hasPrefix("’") || trimmed.hasSuffix("’") { return true }
        let words = Set(normalized(text).split(separator: " ").map(String.init))
        let forbidden: Set<String> = ["not", "no", "never", "don", "dont", "cannot", "can", "won", "wont", "shouldn", "shouldnt",
            "wouldn", "wouldnt", "isn", "isnt", "didn", "didnt", "doesn", "doesnt", "without",
            "what", "why", "how", "when", "where", "whether", "if", "unless", "say", "saying", "said", "quote"]
        return !words.isDisjoint(with: forbidden)
    }

    private static func aliases(for action: MendActionID) -> [String] {
        switch action {
        case .confirmParts: return ["ready", "i have everything", "i have all the parts", "parts ready", "let s get to work"]
        case .showParts: return ["parts", "show parts", "tools and parts"]
        case .reviewParts: return ["check parts", "check my parts", "review parts"]
        case .backToChecklist: return ["back", "go back", "back to checklist", "return to checklist"]
        case .startLiveView: return ["live view", "camera on", "start live view", "resume camera"]
        case .pauseLiveView: return ["pause camera", "camera off", "stop live view", "stop camera"]
        case .showLiveFullPhoto: return ["full image", "show full image"]
        case .focusLivePhoto: return ["close up image", "focus image"]
        case .compareDesigns: return ["compare designs", "change design", "switch design"]
        case .closeComparison: return ["close designs", "close", "done"]
        case .useFocus: return ["focus design", "use focus", "choose focus"]
        case .useFlow: return ["flow design", "use flow", "choose flow"]
        case .useGuide: return ["guide design", "use guide", "choose guide"]
        case .capture: return ["capture", "take photo", "take a photo", "capture photo", "update photo", "take step photo", "capture glasses photo"]
        case .choosePhoto: return ["choose photo", "choose a photo", "photo library"]
        case .phoneCamera: return ["phone camera", "open camera"]
        case .identify: return ["identify", "identify problem", "identify the problem", "analyze photo"]
        case .startGuide: return ["start", "checked", "start guide", "start repair guide", "begin guide"]
        case .previousStep: return ["previous", "previous step", "go back a step"]
        case .nextStep: return ["next", "checked", "next step", "checked next", "checked and next", "check and advance", "i did that", "i did it", "i ve done that", "that s done", "completed"] + explicitStepCompletionPhrases
        case .newRepair: return ["new repair", "start new repair", "start a new repair"]
        case .reviewSteps: return ["review steps", "review repair", "review guide"]
        case .settings: return ["settings", "open settings"]
        case .closeSettings: return ["close settings", "done", "close"]
        case .previewDisplay: return ["preview display", "display preview", "preview glasses", "glasses preview"]
        case .closePreview: return ["close preview", "close", "done"]
        case .enlargePhoto: return ["enlarge photo", "show photo", "open photo", "full screen photo"]
        case .showFullPhoto: return ["full photo", "show full photo", "zoom out"]
        case .focusPhoto: return ["close up", "zoom in", "focus photo"]
        case .closePhoto: return ["close photo", "close", "done"]
        case .connect: return ["connect", "connect glasses"]
        case .register: return ["register", "register glasses", "connect meta ai"]
        case .disconnect: return ["disconnect", "disconnect glasses"]
        case .tryExample: return ["try example", "try an example", "example repair", "try an example repair"]
        case .startVoice: return ["glasses", "talk live", "start voice", "start voice chat", "start talking"]
        case .muteVoice: return ["mute", "mute voice", "mute microphone"]
        case .unmuteVoice: return ["unmute", "unmute voice", "unmute microphone"]
        case .muteMic: return ["mute", "mute me", "mute mic", "mute microphone", "mute the microphone", "microphone off"]
        case .unmuteMic: return ["unmute", "unmute me", "unmute mic", "unmute microphone", "unmute the microphone", "microphone on"]
        case .talk: return [] // Only touch/gesture may open a microphone turn.
        case .focusListening: return [] // Legacy action is no longer offered.
        case .stopVoice: return ["stop voice", "end voice", "end voice chat", "stop voice chat"]
        case .repeatStep: return ["repeat step", "repeat the step", "read step", "read this step"]
        case .stopSpeaking: return ["stop speaking", "stop talking", "quiet"]
        case .cancel: return ["cancel"]
        case .clearError: return ["dismiss error", "clear error", "dismiss"]
        case .saveKey: return ["save key", "save model key", "save meta key"]
        case .forgetKey: return ["forget key", "forget model key", "forget meta key"]
        case .saveVoiceKey: return ["save voice key", "save openai key"]
        case .forgetVoiceKey: return ["forget voice key", "forget openai key"]
        case .testSound: return ["test sound", "test audio", "play test sound"]
        case .stopSound: return ["stop sound", "stop test sound", "stop audio test"]
        case .audioOutput: return ["audio output", "choose audio output", "sound output", "choose glasses", "glasses audio"]
        case .showActions: return ["menu", "show actions", "show buttons", "actions", "buttons"]
        case .more: return ["more", "more actions", "next page"]
        case .back: return ["back page", "previous page"]
        case .pauseReplies: return ["pause replies", "pause spoken replies", "pause voice replies", "pause speech"]
        case .resumeReplies: return ["resume replies", "resume spoken replies", "resume voice replies", "resume speech"]
        case .closeActions: return ["close actions", "close buttons", "close"]
        case .nextActions: return ["next actions", "more actions", "next page"]
        case .previousActions: return ["previous actions", "previous page", "back"]
        case .closePicker: return ["close picker", "close photo picker", "cancel"]
        case .startProject: return ["start project", "let s start", "get started"]
        case .reviewProject: return ["review details", "review project"]
        case .confirmProject: return ["create steps", "confirm", "confirmed", "yes", "that s right", "that s correct", "looks right", "make the plan"]
        case .editProject: return ["edit details", "change details"]
        case .submitDetails: return ["add details", "save details"]
        case .showChecklist: return ["checklist", "show checklist", "show steps"]
        case .closeChecklist: return ["close checklist", "close", "done"]
        case .completeStep: return []
        case .askHelp: return ["help", "help with this step", "help me", "explain this step"]
        case .moreDetails: return ["more details", "details"]
        case .findTips: return ["find tips", "tips", "tips and tricks", "look it up"]
        case .showSources: return ["sources", "show sources"]
        case .closeSources: return ["close sources", "close", "done"]
        case .closeDetails: return ["close details", "close", "done"]
        case .submitQuestion: return ["ask", "ask question"]
        default: return []
        }
    }
}

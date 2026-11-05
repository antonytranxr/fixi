#if DEBUG
import AVFoundation
import Foundation

/// Explicit local-only check: no keys, network requests, microphone, or camera.
@MainActor enum MendLocalSpeechCheck {
    private static var started = false
    private static let phrase = "Fixi voice check. Your repair answer will be read aloud without a separate conversation."

    static var requestedRunID: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--mendsight-local-speech-check"),
              arguments.indices.contains(index + 1) else { return nil }
        let id = arguments[index + 1]
        return id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) == nil ? nil : id
    }

    static func run(id: String, model: FixiModel) async {
        guard !started, id == requestedRunID else { return }
        started = true
        model.stage = .capture
        model.setupPrompt = "Checking the iPhone speech voice…"
        let began = Date()
        let output = SystemSpeechOutput()
        var transcript = ""
        var failed = false
        output.onTranscript = { transcript = $0 }
        output.onFailure = { _ in failed = true }
        var report: [String: Any] = ["runID": id, "phase": "starting", "engine": "AVSpeechSynthesizer",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "usesAPIKey": false, "usesNetwork": false, "usesMicrophone": false, "requiresBluetoothOutput": true]
        do {
            try save(report, id: id)
            try await output.start(apiKey: "")
            report["phase"] = "speaking"
            report["selectedOutputTypes"] = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
            try save(report, id: id)
            let completed = await output.speak(phrase)
            report["phase"] = "complete"
            report["synthesizerFinished"] = completed
            report["transcriptMatchesSuppliedText"] = transcript == phrase
            report["failureReported"] = failed
            report["elapsedMilliseconds"] = Int(Date().timeIntervalSince(began) * 1000)
            try save(report, id: id)
            model.setupPrompt = completed ? "Local speech check completed." : "Local speech check did not finish."
        } catch {
            let selectionRequired = error.localizedDescription == GlassesAudioRoute.selectionRequiredMessage
            report["phase"] = selectionRequired ? "needs_output_selection" : "failed"
            report["startRejected"] = true
            report["selectionRequired"] = selectionRequired
            report["synthesizerFinished"] = false
            report["transcriptSubmitted"] = !transcript.isEmpty
            report["elapsedMilliseconds"] = Int(Date().timeIntervalSince(began) * 1000)
            try? save(report, id: id)
            model.setupPrompt = selectionRequired ? "Choose your glasses in Audio output." : "The local speech check could not finish."
        }
        output.stop()
    }

    private static func save(_ report: [String: Any], id: String) throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = documents.appendingPathComponent("MendSightDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(id + ".json"), options: [.atomic, .completeFileProtection])
    }
}
#endif

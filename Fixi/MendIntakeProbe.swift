#if DEBUG
import Foundation
import UIKit

/// Explicit launch-only diagnostic. The configured credential never leaves the
/// app except in the normal Authorization header sent to Meta's API.
@MainActor
enum MendIntakeProbe {
    private static let phrase = "i can't restart my mac book pro"
    private static let maximumBytes = 1024 * 1024
    private static var started = false
    private static var productionOnly: Bool { ProcessInfo.processInfo.arguments.contains("--mendsight-intake-probe-production") }

    static var requestedRunID: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--mendsight-intake-probe"),
              arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil ? value : nil
    }

    static func run(id: String, model: FixiModel) async {
        guard !started, id == requestedRunID else { return }
        started = true
        model.stage = .capture
        model.setupPrompt = "Running the intake connection check. No glasses microphone or camera is used."
        let key = MendKeyStore.read()
        var report: [String: Any] = [
            "runID": id, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "fixture": "restart-macbook-with-neutral-image", "keyAvailable": !key.isEmpty,
            "mode": productionOnly ? "production-client" : "comparison",
            "phase": "starting", "attempts": []
        ]
        do {
            try save(report, id: id)
            guard !key.isEmpty else {
                report["phase"] = "missing_key"; try save(report, id: id)
                model.setupPrompt = "The connection check could not find a saved Meta key."
                return
            }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            guard let jpeg = image.jpegData(compressionQuality: 0.8) else { throw ProbeError.image }
            if productionOnly {
                report["phase"] = "requesting_production_client"; try save(report, id: id)
                model.setupPrompt = "Checking the production intake client…"
                report["attempts"] = [await productionAttempt(jpeg: jpeg, key: key)]
                report["phase"] = "complete"; try save(report, id: id)
                model.setupPrompt = "The production intake check is complete. Its report contains no API key, photo, or raw model response."
                return
            }
            var baseline = try MendIntakeClient.requestBody(current: .init(), text: phrase, jpeg: jpeg, photoID: "diagnostic-neutral-image")
            // Keep the failing build's settings fixed even after the real builder
            // is corrected; comparison must not quietly change its baseline.
            baseline["max_output_tokens"] = 1800
            baseline.removeValue(forKey: "reasoning")
            var attempts: [[String: Any]] = []
            for name in ["baseline", "low-reasoning-4096"] {
                try Task.checkCancellation()
                var body = baseline
                if name != "baseline" {
                    body["reasoning"] = ["effort": "low"]
                    body["max_output_tokens"] = 4096
                }
                report["phase"] = "requesting_" + name; try save(report, id: id)
                model.setupPrompt = "Checking intake \(attempts.count + 1) of 2…"
                let attemptResult = await attempt(name: name, body: body, key: key)
                attempts.append(attemptResult)
                report["attempts"] = attempts
                report["phase"] = "finished_" + name; try save(report, id: id)
            }
            report["phase"] = "complete"; try save(report, id: id)
            model.setupPrompt = "The intake connection check is complete. Its diagnostic report contains no API key, photo, or raw model response."
        } catch {
            report["phase"] = error is CancellationError ? "cancelled" : "probe_failed"
            report["probeError"] = error is MendError ? appError(error, key: key) : "Local diagnostic setup or file write failed."
            try? save(report, id: id)
            model.setupPrompt = "The intake connection check stopped. Any completed diagnostic result was saved."
        }
    }

    private static func productionAttempt(jpeg: Data, key: String) async -> [String: Any] {
        let began = Date()
        var result: [String: Any] = ["name": "production-client"]
        do {
            let decoded = try await MendIntakeClient().collect(current: .init(), text: phrase, jpeg: jpeg, photoID: "diagnostic-neutral-image", key: key)
            result["decodeSuccess"] = true
            result["project"] = projectSummary(decoded.details, key: key)
        } catch {
            result["decodeSuccess"] = false
            if error is MendError { result["clientError"] = appError(error, key: key) }
            else {
                let ns = error as NSError
                result["transportDomain"] = token(ns.domain, key: key); result["transportCode"] = ns.code
            }
        }
        result["elapsedMilliseconds"] = Int(Date().timeIntervalSince(began) * 1000)
        return result
    }

    private static func attempt(name: String, body: [String: Any], key: String) async -> [String: Any] {
        let began = Date()
        var result: [String: Any] = ["name": name, "phase": "requesting", "request": [
            "model": token(body["model"], key: key),
            "maxOutputTokens": body["max_output_tokens"] as? Int ?? 0,
            "reasoningEffort": (body["reasoning"] as? [String: Any])?["effort"] as? String ?? "default",
            "hasSyntheticPhoto": true
        ]]
        do {
            let encoded = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: URL(string: "https://api.meta.ai/v1/responses")!)
            request.httpMethod = "POST"; request.httpBody = encoded; request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 90; configuration.timeoutIntervalForResource = 90
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProbeError.response }
            result["httpStatus"] = http.statusCode
            guard response.expectedContentLength <= maximumBytes else { throw ProbeError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw ProbeError.tooLarge }
                data.append(byte)
                if data.count % 16_384 == 0 { try Task.checkCancellation() }
            }
            result["responseBytes"] = data.count
            result["response"] = summarize(data, key: key)
            result["phase"] = "received"
            do {
                let decoded = try MendIntakeClient.decodeResponse(data, current: .init(), text: phrase, hasPhoto: true)
                result["decodeSuccess"] = true
                result["project"] = projectSummary(decoded.details, key: key)
            } catch {
                result["decodeSuccess"] = false
                result["decoderError"] = appError(error, key: key)
            }
        } catch {
            result["phase"] = error is CancellationError ? "cancelled" : "transport_failed"
            if let error = error as? ProbeError { result["transportFailure"] = error.rawValue }
            else {
                let ns = error as NSError
                result["transportDomain"] = token(ns.domain, key: key)
                result["transportCode"] = ns.code
            }
        }
        result["elapsedMilliseconds"] = Int(Date().timeIntervalSince(began) * 1000)
        return result
    }

    /// Records structure and known numeric fields, never raw output or reasoning.
    private static func summarize(_ data: Data, key: String) -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["jsonObject": false] }
        var result: [String: Any] = ["jsonObject": true, "status": token(root["status"], key: key)]
        if let incomplete = root["incomplete_details"] as? [String: Any] { result["incompleteReason"] = token(incomplete["reason"], key: key) }
        if let error = root["error"] as? [String: Any] {
            var errorSummary = ["code": token(error["code"], key: key), "type": token(error["type"], key: key), "param": token(error["param"], key: key)]
            if let message = error["message"] as? String { errorSummary["message"] = scrub(message, key: key, maximum: 400) }
            result["error"] = errorSummary
        }
        if let usage = root["usage"] as? [String: Any] {
            var numbers: [String: Int] = [:]
            for name in ["input_tokens", "output_tokens", "total_tokens"] {
                if let value = usage[name] as? Int, value >= 0 { numbers[name] = value }
            }
            for (group, name) in [("input_tokens_details", "cached_tokens"), ("output_tokens_details", "reasoning_tokens")] {
                if let value = (usage[group] as? [String: Any])?[name] as? Int, value >= 0 { numbers[name] = value }
            }
            result["usage"] = numbers
        }
        let items = root["output"] as? [[String: Any]] ?? []
        result["outputItems"] = items.prefix(32).map { item -> [String: Any] in
            let parts = item["content"] as? [[String: Any]] ?? []
            return ["type": token(item["type"], key: key), "status": token(item["status"], key: key),
                    "contentTypes": parts.prefix(32).map { token($0["type"], key: key) }]
        }
        let parts = items.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let text = parts.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        result["outputTextBytes"] = text.utf8.count
        if !text.isEmpty {
            if let wire = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                result["answerStructure"] = wireStructure(wire, key: key)
            } else { result["answerJSONValid"] = false }
        }
        return result
    }

    private static func wireStructure(_ wire: [String: Any], key: String) -> [String: Any] {
        var result: [String: Any] = ["topLevel": typedKeys(wire, key: key)]
        guard let updates = wire["updates"] as? [String: Any] else { return result }
        result["updates"] = typedKeys(updates, key: key)
        var fields: [String: Any] = [:]
        for name in ["make", "model", "problem"] {
            guard let field = updates[name] as? [String: Any] else { continue }
            var shape: [String: Any] = ["members": typedKeys(field, key: key), "source": token(field["source"], key: key)]
            if let quote = field["userQuote"] as? String {
                shape["userQuoteMatchesFixture"] = !quote.isEmpty && phrase.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if let correction = field["correction"] as? Bool { shape["correction"] = correction }
            fields[name] = shape
        }
        result["fields"] = fields
        return result
    }

    private static func typedKeys(_ object: [String: Any], key: String) -> [[String: String]] {
        object.keys.sorted().prefix(32).map { ["name": token($0, key: key), "type": valueType(object[$0])] }
    }
    private static func valueType(_ value: Any?) -> String {
        switch value {
        case is NSNull: return "null"
        case is String: return "string"
        case is [String: Any]: return "object"
        case is [Any]: return "array"
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        default: return "missing"
        }
    }
    private static func token(_ value: Any?, key: String) -> String {
        guard let value = value as? String else { return "missing" }
        let clean = scrub(value, key: key, maximum: 128)
        guard clean == value, clean.range(of: "^[A-Za-z0-9_.\\[\\]-]{1,128}$", options: .regularExpression) != nil else { return "redacted_or_other" }
        return clean
    }
    private static func scrub(_ text: String, key: String, maximum: Int) -> String {
        var clean = text
        for secret in Set([key, key.trimmingCharacters(in: .whitespacesAndNewlines)]) where !secret.isEmpty {
            clean = clean.replacingOccurrences(of: secret, with: "[redacted]")
        }
        clean = clean.replacingOccurrences(of: "(?i)(?:Bearer\\s+\\S+|sk-[A-Za-z0-9_-]+)", with: "[redacted]", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "(?i)(?:api[_ -]?key|token|authorization)\\s*[:=]\\s*[^\\s,;]+", with: "[redacted]", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "[A-Za-z0-9+/_=-]{48,}", with: "[redacted]", options: .regularExpression)
        clean = clean.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }.map(String.init).joined()
        return String(clean.prefix(maximum))
    }
    private static func appError(_ error: Error, key: String) -> String {
        if case MendError.message(let message) = error { return scrub(message, key: key, maximum: 400) }
        return "The app could not decode the diagnostic response."
    }
    private static func projectSummary(_ details: MendProjectDetails, key: String) -> [String: Any] {
        ["make": scrub(details.make, key: key, maximum: 120),
         "model": scrub(details.model, key: key, maximum: 160),
         "problem": scrub(details.problem, key: key, maximum: 1800),
         "suggestedFields": details.suggestedFields.sorted()]
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
    private enum ProbeError: String, Error { case image, response, tooLarge }
}
#endif

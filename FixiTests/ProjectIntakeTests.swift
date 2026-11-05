import XCTest
@testable import Fixi

final class ProjectIntakeTests: XCTestCase {
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
    private var missing: [String: Any] { field(nil, source: "missing") }
    private func field(_ value: String?, source: String, correction: Bool = false, quote: String? = nil) -> [String: Any] {
        ["value": value as Any? ?? NSNull(), "source": source, "correction": correction, "userQuote": quote as Any? ?? NSNull()]
    }
    private func envelope(_ value: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: value)
        return try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message",
            "content": [["type": "output_text", "text": String(decoding: body, as: UTF8.self)]]]]])
    }
    private func intake(make: [String: Any]? = nil, model: [String: Any]? = nil, problem: [String: Any]? = nil) throws -> Data {
        try envelope(["updates": ["make": make ?? missing, "model": model ?? missing, "problem": problem ?? missing],
                      "prompt": "What model is it? You can say Unknown."])
    }
    private func incomplete(reason: String = "max_output_tokens") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": "incomplete", "error": NSNull(),
            "incomplete_details": ["reason": reason], "output": [["type": "message",
                "content": [["type": "output_text", "text": "{\"updates\":"]]]]])
    }
    private var readyDetails: MendProjectDetails {
        MendProjectDetails(make: "Unknown", model: "Unknown", problem: "The cabinet door is loose.")
    }
    private func diagnosis(step: MendStep) -> MendDiagnosis {
        MendDiagnosis(photoID: "project-1", status: .ready, title: "Check the hinge",
                      summary: "You reported a loose cabinet door.", evidence: ["User reports a loose door."],
                      confidence: .medium, questions: [], tools: ["Screwdriver"], precautions: [], steps: [step])
    }
    private func step(marker: PhotoMarker? = nil, hint: String? = nil, fresh: Bool? = nil) -> MendStep {
        MendStep(id: "s1", title: "Support the door", instruction: "Hold the door steady.", expectedResult: "The door is supported.",
                 caution: nil, marker: marker, photoHint: hint, requiresFreshPhoto: fresh)
    }

    func testMissingFieldsTrimWhitespaceAndNullsDecodeAsMissing() throws {
        let details = MendProjectDetails(make: " \n", model: "PAX", problem: "")
        XCTAssertEqual(details.missingFields, ["make", "problem"])
        XCTAssertFalse(details.isReady)
        let decoded = try JSONDecoder().decode(MendProjectDetails.self, from: Data(#"{"make":null,"model":"PAX","problem":null}"#.utf8))
        XCTAssertEqual(decoded.make, "")
        XCTAssertEqual(decoded.missingFields, ["make", "problem"])
        XCTAssertTrue(decoded.suggestedFields.isEmpty)
        XCTAssertTrue(readyDetails.isReady)
    }

    func testQuestionRoutingKeepsKnownProblemsOutOfIntakeButRetainsMissingTaskAndSymptomEvidence() {
        let known = MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Will not restart")
        for question in ["how do I restart it", "Please explain that", "Why won't it restart?", "Can I keep using it?", "Where is the model number?"] {
            XCTAssertEqual(MendSetupUtterance.route(question, current: known), .question, question)
        }
        let missingProblem = MendProjectDetails(make: "Unknown", model: "Laptop")
        for evidence in ["How do I restart it?", "Why won’t my laptop restart?", "Why is my display blank?", "Help me replace the hinge", "my mac book pro wont restart"] {
            XCTAssertEqual(MendSetupUtterance.route(evidence, current: missingProblem), .details, evidence)
        }
        for question in ["What model is this?", "Where can I find the model number?", "How do I take a photo?", "How do I mute the microphone?", "What does this button do?"] {
            XCTAssertEqual(MendSetupUtterance.route(question, current: missingProblem), .question, question)
        }
        for correction in ["It's a different model", "Actually it will restart but then shuts down", "The maker is Unknown", "I don't know the model"] {
            XCTAssertEqual(MendSetupUtterance.route(correction, current: known), .details, correction)
        }
    }

    func testHowToTaskEvidenceDoesNotRequireAnInventedFaultAndKeepsPhotoIdentity() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro", suggestedFields: ["make", "model"])
        let utterance = "how do I restart it"
        let result = try MendIntakeClient.decodeResponse(
            intake(problem: field("Wants help restarting the laptop", source: "user", quote: utterance)),
            current: current, text: utterance, hasPhoto: false)
        XCTAssertEqual(result.details.make, current.make); XCTAssertEqual(result.details.model, current.model)
        XCTAssertEqual(result.details.suggestedFields, current.suggestedFields)
        XCTAssertEqual(result.details.problem, "Wants help restarting the laptop")
        XCTAssertTrue(result.details.isReady)
    }

    func testPhotoOnlyIntakeExtractsOnlySuppliedImageEvidence() throws {
        let body = try MendIntakeClient.requestBody(current: .init(), text: "", jpeg: jpeg, photoID: "label-1")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(body["store"] as? Bool, false)
        let data = try intake(make: field("IKEA", source: "photo"), model: field("PAX", source: "photo"))
        let result = try MendIntakeClient.decodeResponse(data, current: .init(), text: "", hasPhoto: true)
        XCTAssertEqual(result.details.make, "IKEA")
        XCTAssertEqual(result.details.model, "PAX")
        XCTAssertEqual(result.details.missingFields, ["problem"])
        XCTAssertThrowsError(try MendIntakeClient.decodeResponse(data, current: .init(), text: "", hasPhoto: false))
    }

    func testIncrementalSpeechPreservesExistingAnswersAndNullDoesNotErase() throws {
        let current = MendProjectDetails(make: "IKEA", model: "PAX")
        let result = try MendIntakeClient.decodeResponse(intake(problem: field("door is loose", source: "user", quote: "The door is loose")),
                                                       current: current, text: "The door is loose", hasPhoto: false)
        XCTAssertEqual(result.details.make, "IKEA")
        XCTAssertEqual(result.details.model, "PAX")
        XCTAssertEqual(result.details.problem, "door is loose")
        XCTAssertTrue(result.details.isReady)
    }

    func testNaturalCorrectionRequiresActualUtteranceButNoMagicCorrectionWords() throws {
        let current = MendProjectDetails(make: "LG", model: "A1", problem: "Door is loose")
        let utterance = "It is Bosch"
        let result = try MendIntakeClient.decodeResponse(intake(make: field("Bosch", source: "user", quote: utterance)),
                                                       current: current, text: utterance, hasPhoto: false)
        XCTAssertEqual(result.details.make, "Bosch")
        XCTAssertEqual(result.details.model, "A1")
        XCTAssertThrowsError(try MendIntakeClient.decodeResponse(intake(make: field("Whirlpool", source: "user", quote: "It is Whirlpool")),
                                                                current: current, text: utterance, hasPhoto: false))
    }

    func testPhotoConflictPreservesUserStatementButNaturalSpeechCanReplaceIt() throws {
        let current = MendProjectDetails(make: "LG")
        let photo = try MendIntakeClient.decodeResponse(intake(make: field("Bosch", source: "photo")), current: current, text: "", hasPhoto: true)
        XCTAssertEqual(photo.details.make, "LG")
        let speech = try MendIntakeClient.decodeResponse(intake(make: field("Bosch", source: "user", quote: "Bosch")), current: current, text: "Bosch", hasPhoto: false)
        XCTAssertEqual(speech.details.make, "Bosch")
        XCTAssertTrue(speech.details.suggestedFields.isEmpty)
        XCTAssertTrue(photo.prompt.contains("kept what you told me"))
    }

    func testMacBookSpeechNormalizesModelInfersMakerAndRecordsReportedFrozenScreen() throws {
        let utterance = "my mac book pro was frozen"
        let response = try intake(make: field("Apple", source: "user_inference", quote: utterance),
                                  model: field("MacBook Pro", source: "user", quote: utterance),
                                  problem: field("Screen frozen", source: "user", quote: utterance))
        let result = try MendIntakeClient.decodeResponse(response, current: .init(), text: utterance, hasPhoto: false)
        XCTAssertEqual(result.details.make, "Apple")
        XCTAssertEqual(result.details.model, "MacBook Pro")
        XCTAssertEqual(result.details.problem, "Screen frozen")
        XCTAssertEqual(result.details.suggestedFields, ["make"])
        XCTAssertTrue(result.details.isReady)
        XCTAssertTrue(result.prompt.contains("best guess"))
    }

    func testPhotoCanSuggestProductFamilyAndVisibleSymptomForReview() throws {
        let response = try intake(make: field("Apple", source: "photo_inference"),
                                  model: field("MacBook Pro", source: "photo_inference"),
                                  problem: field("Screen appears cracked", source: "photo_inference"))
        let result = try MendIntakeClient.decodeResponse(response, current: .init(), text: "", hasPhoto: true)
        XCTAssertEqual(result.details.make, "Apple")
        XCTAssertEqual(result.details.model, "MacBook Pro")
        XCTAssertEqual(result.details.problem, "Screen appears cracked")
        XCTAssertEqual(result.details.suggestedFields, ["make", "model", "problem"])
        XCTAssertTrue(result.details.isReady)
        XCTAssertThrowsError(try MendIntakeClient.decodeResponse(response, current: .init(), text: "", hasPhoto: false))
    }

    func testSpokenModelYearIsRetainedThroughConfirmationAndPlanContext() throws {
        let utterance = "My 2018 Honda Civic needs a new engine air filter"
        let response = try intake(make: field("Honda", source: "user", quote: utterance),
                                  model: field("Civic (2018)", source: "user", quote: utterance),
                                  problem: field("Replace the engine air filter", source: "user", quote: utterance))
        let result = try MendIntakeClient.decodeResponse(response, current: .init(), text: utterance, hasPhoto: false)
        XCTAssertEqual(result.details.model, "Civic (2018)")
        XCTAssertTrue(result.details.isReady)
        XCTAssertTrue(result.details.suggestedFields.isEmpty)

        let followup = try requestContext(MendIntakeClient.requestBody(current: result.details, text: "Yes", jpeg: nil, photoID: nil))
        XCTAssertEqual((followup["current_details"] as? [String: Any])?["model"] as? String, "Civic (2018)")
        let plan = try requestContext(MendClient.planRequestBody(details: result.details, jpeg: nil, photoID: "car-1"))
        XCTAssertEqual((plan["confirmed_project"] as? [String: String])?["model"], "Civic (2018)")
    }

    func testPhotoYearCanEnrichDirectModelFamilyAndRetainsBestGuessUntilReviewed() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Wants help restarting")
        let response = try intake(model: field("MacBook Pro (2021)", source: "photo_inference"))
        let result = try MendIntakeClient.decodeResponse(response, current: current, text: "", hasPhoto: true)
        XCTAssertEqual(result.details.model, "MacBook Pro (2021)")
        XCTAssertEqual(result.details.make, current.make)
        XCTAssertEqual(result.details.problem, current.problem)
        XCTAssertEqual(result.details.suggestedFields, ["model"], "An inferred year makes the complete model identity a best guess")
        XCTAssertTrue(result.prompt.contains("best guess"))
        XCTAssertThrowsError(try MendIntakeClient.decodeResponse(response, current: current, text: "", hasPhoto: false))

        let differentFamily = try MendIntakeClient.decodeResponse(intake(model: field("MacBook Air (2021)", source: "photo_inference")),
                                                                current: current, text: "", hasPhoto: true)
        XCTAssertEqual(differentFamily.details.model, current.model, "Year enrichment must not let a photo replace a directly stated family")
        XCTAssertTrue(differentFamily.prompt.contains("kept what you told me"))
    }

    func testAmbiguousPhotoYearRangeIsAReviewableModelNotAnAdditionalRequiredField() throws {
        let response = try intake(make: field("Apple", source: "photo_inference"),
                                  model: field("MacBook Pro (2016–2019)", source: "photo_inference"))
        let initial = try MendIntakeClient.decodeResponse(response, current: .init(), text: "", hasPhoto: true)
        XCTAssertEqual(initial.details.model, "MacBook Pro (2016–2019)")
        XCTAssertEqual(initial.details.suggestedFields, ["make", "model"])
        XCTAssertEqual(initial.details.missingFields, ["problem"])
        let utterance = "How do I restart it?"
        let completed = try MendIntakeClient.decodeResponse(intake(problem: field("Wants help restarting", source: "user", quote: utterance)),
                                                            current: initial.details, text: utterance, hasPhoto: false)
        XCTAssertTrue(completed.details.isReady)
        XCTAssertEqual(completed.details.model, "MacBook Pro (2016–2019)")
        XCTAssertEqual(completed.details.suggestedFields, ["make", "model"])
    }

    func testEstablishedYearIsNotDowngradedByFamilyRestatementOrLaterInference() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro (2021)", problem: "Screen frozen")
        let utterance = "My MacBook Pro is frozen"
        for model in [field("MacBook Pro", source: "user", quote: utterance),
                      field("MacBook Pro (2016–2019)", source: "user_inference", quote: utterance),
                      field("MacBook Pro (2023)", source: "photo_inference")] {
            let result = try MendIntakeClient.decodeResponse(intake(model: model), current: current, text: utterance, hasPhoto: true)
            XCTAssertEqual(result.details, current)
        }
        var guessed = current
        guessed.suggestedFields = ["model"]
        let repeatedFamily = try MendIntakeClient.decodeResponse(intake(model: field("MacBook Pro", source: "user", quote: utterance)),
                                                                current: guessed, text: utterance, hasPhoto: false)
        XCTAssertEqual(repeatedFamily.details, guessed, "Repeating the family must not silently confirm or remove a guessed year")
    }

    func testDirectYearCorrectionOrUnknownYearCanReplaceAnEarlierYear() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro (2021)", problem: "Screen frozen", suggestedFields: ["model"])
        let correction = "It is the 2023 MacBook Pro"
        let corrected = try MendIntakeClient.decodeResponse(intake(model: field("MacBook Pro (2023)", source: "user", correction: true, quote: correction)),
                                                           current: current, text: correction, hasPhoto: false)
        XCTAssertEqual(corrected.details.model, "MacBook Pro (2023)")
        XCTAssertTrue(corrected.details.suggestedFields.isEmpty)
        XCTAssertEqual(corrected.details.problem, current.problem)

        let unknown = "I don't know the year, just MacBook Pro"
        let yearRemoved = try MendIntakeClient.decodeResponse(intake(model: field("MacBook Pro", source: "user", correction: true, quote: unknown)),
                                                              current: corrected.details, text: unknown, hasPhoto: false)
        XCTAssertEqual(yearRemoved.details.model, "MacBook Pro")
        XCTAssertTrue(yearRemoved.details.isReady, "A missing year must not block a project with a known family and problem")
    }

    func testLegibleModelYearLabelEnrichesKnownFamilyWithoutUncertainty() throws {
        let current = MendProjectDetails(make: "Honda", model: "Civic", problem: "Replace the engine air filter")
        let result = try MendIntakeClient.decodeResponse(intake(model: field("Civic (2018)", source: "photo")),
                                                       current: current, text: "", hasPhoto: true)
        XCTAssertEqual(result.details.model, "Civic (2018)")
        XCTAssertTrue(result.details.suggestedFields.isEmpty)
        XCTAssertTrue(result.details.isReady)
    }

    func testSymptomNegationDoesNotAuthorizeRemovingTheModelYear() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro (2021)", problem: "Wants help restarting")
        for utterance in ["My 2021 MacBook Pro is not restarting", "My 2021 MacBook Pro isn't working", "I don't know why my 2021 MacBook Pro won't restart"] {
            let result = try MendIntakeClient.decodeResponse(intake(model: field("MacBook Pro", source: "user", quote: utterance)),
                                                           current: current, text: utterance, hasPhoto: false)
            XCTAssertEqual(result.details.model, current.model, utterance)
        }
        for utterance in ["I'm not sure of the year", "I don't know the model year", "The year is wrong", "It is not a 2021 MacBook Pro"] {
            let result = try MendIntakeClient.decodeResponse(intake(model: field("MacBook Pro", source: "user", correction: true, quote: utterance)),
                                                           current: current, text: utterance, hasPhoto: false)
            XCTAssertEqual(result.details.model, "MacBook Pro", utterance)
        }
    }

    func testProviderCannotClearGuessedYearFromFamilyOnlyQuoteOrBareYes() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro (2021)", problem: "Wants help restarting", suggestedFields: ["model"])
        for utterance in ["MacBook Pro", "My MacBook Pro is not restarting", "Yes", "I can't confirm the year", "I don't know if the year is correct"] {
            let result = try MendIntakeClient.decodeResponse(intake(model: field(current.model, source: "user", quote: utterance)),
                                                           current: current, text: utterance, hasPhoto: false)
            XCTAssertEqual(result.details, current, utterance)
            XCTAssertTrue(result.prompt.contains("best guess"))
        }
        for utterance in ["It is a 2021 MacBook Pro", "Yes, the year is correct"] {
            let result = try MendIntakeClient.decodeResponse(intake(model: field(current.model, source: "user", quote: utterance)),
                                                           current: current, text: utterance, hasPhoto: false)
            XCTAssertEqual(result.details.model, current.model)
            XCTAssertTrue(result.details.suggestedFields.isEmpty, utterance)
        }
    }

    func testIdentifyingLaptopDoesNotRequireInventingASymptomFromItsStillImage() throws {
        let response = try intake(make: field("Apple", source: "photo_inference"), model: field("MacBook Pro", source: "photo_inference"))
        let result = try MendIntakeClient.decodeResponse(response, current: .init(), text: "", hasPhoto: true)
        XCTAssertEqual(result.details.suggestedFields, ["make", "model"])
        XCTAssertEqual(result.details.missingFields, ["problem"])
        XCTAssertEqual(result.details.problem, "")
        XCTAssertFalse(result.details.isReady)
        let incomplete = try MendIntakeClient.decodeResponse(intake(model: field("MacBook Pro", source: "user", quote: "my mac book pro")),
                                                            current: .init(), text: "my mac book pro", hasPhoto: false)
        XCTAssertEqual(incomplete.details.problem, "")
        XCTAssertFalse(incomplete.details.isReady)
    }

    func testUserNaturallyReplacesEveryPhotoGuessWithoutCorrectionKeywords() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Screen appears cracked",
                                         suggestedFields: ["make", "model", "problem"])
        let utterance = "It is a Dell XPS 13 and the screen is frozen"
        let response = try intake(make: field("Dell", source: "user", quote: utterance),
                                  model: field("XPS 13", source: "user", quote: utterance),
                                  problem: field("Screen frozen", source: "user", quote: utterance))
        let result = try MendIntakeClient.decodeResponse(response, current: current, text: utterance, hasPhoto: false)
        XCTAssertEqual(result.details, MendProjectDetails(make: "Dell", model: "XPS 13", problem: "Screen frozen"))
        XCTAssertTrue(result.details.suggestedFields.isEmpty)
    }

    func testMissingFieldsPreserveGuessMetadataAndDirectRestatementClearsOnlyItsField() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro", suggestedFields: ["make", "model"])
        let response = try intake(make: field("Apple", source: "user", quote: "It is Apple"),
                                  model: field("MacBook Pro", source: "unchanged"))
        let result = try MendIntakeClient.decodeResponse(response, current: current, text: "It is Apple", hasPhoto: false)
        XCTAssertEqual(result.details.suggestedFields, ["model"])
        let missingResult = try MendIntakeClient.decodeResponse(intake(), current: current, text: "Hello", hasPhoto: false)
        XCTAssertEqual(missingResult.details, current)
    }

    func testNewPhotoMayRefineAnEarlierGuess() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro", suggestedFields: ["make", "model"])
        let result = try MendIntakeClient.decodeResponse(intake(make: field("Dell", source: "photo"), model: field("XPS 13", source: "photo")),
                                                       current: current, text: "", hasPhoto: true)
        XCTAssertEqual(result.details.make, "Dell")
        XCTAssertEqual(result.details.model, "XPS 13")
        XCTAssertTrue(result.details.suggestedFields.isEmpty, "Legible direct labels replace uncertain visual guesses")
    }

    func testMatchingInferenceNeverDowngradesAnExistingDirectUserStatement() throws {
        let current = MendProjectDetails(make: "Apple", model: "MacBook Pro")
        let photo = try MendIntakeClient.decodeResponse(intake(make: field("Apple", source: "photo_inference"),
                                                              model: field("MacBook Pro", source: "photo_inference")),
                                                       current: current, text: "", hasPhoto: true)
        XCTAssertEqual(photo.details, current)
        XCTAssertTrue(photo.details.suggestedFields.isEmpty)
        let utterance = "my MacBook Pro is frozen"
        let speech = try MendIntakeClient.decodeResponse(intake(make: field("Apple", source: "user_inference", quote: utterance),
                                                               problem: field("Screen frozen", source: "user", quote: utterance)),
                                                        current: current, text: utterance, hasPhoto: false)
        XCTAssertEqual(speech.details.make, "Apple")
        XCTAssertEqual(speech.details.model, "MacBook Pro")
        XCTAssertEqual(speech.details.problem, "Screen frozen")
        XCTAssertTrue(speech.details.suggestedFields.isEmpty)
    }

    func testGuessMetadataRoundTripsAndAppearsInRequestContext() throws {
        let details = MendProjectDetails(make: "Apple", model: "MacBook Pro", suggestedFields: ["make"])
        XCTAssertEqual(try JSONDecoder().decode(MendProjectDetails.self, from: JSONEncoder().encode(details)), details)
        XCTAssertThrowsError(try MendProjectDetails(make: "Apple", suggestedFields: ["serial"]).validated())
        XCTAssertThrowsError(try MendProjectDetails(suggestedFields: ["make"]).validated())
        let body = try MendIntakeClient.requestBody(current: details, text: "It is Apple", jpeg: nil, photoID: nil)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(context["current_suggested_fields"] as? [String], ["make"])
        XCTAssertEqual(context["details_confirmed"] as? Bool, false)
    }

    func testUnknownNeedsExplicitUserStatementForTheApplicableField() throws {
        XCTAssertThrowsError(try MendIntakeClient.decodeResponse(intake(make: field("Unknown", source: "photo")), current: .init(), text: "", hasPhoto: true))
        XCTAssertThrowsError(try MendIntakeClient.decodeResponse(intake(make: field("Unknown", source: "user", quote: "I don't know the model")),
                                                                current: .init(), text: "I don't know the model", hasPhoto: false))
        let text = "I don't know the model"
        let result = try MendIntakeClient.decodeResponse(intake(model: field("Unknown", source: "user", quote: text)),
                                                       current: .init(make: "IKEA"), text: text, hasPhoto: false)
        XCTAssertEqual(result.details.model, "Unknown")
        let generic = "This is a generic cabinet"
        let genericResult = try MendIntakeClient.decodeResponse(intake(make: field("Unknown", source: "user", quote: generic),
                                                                      model: field("Unknown", source: "user", quote: generic)),
                                                              current: .init(problem: "Loose hinge"), text: generic, hasPhoto: false)
        XCTAssertTrue(genericResult.details.isReady)
    }

    func testIntakeSchemaRequiresCorrectionEvidenceAndRejectsInvalidInputSizes() throws {
        let body = try MendIntakeClient.requestBody(current: .init(), text: "IKEA", jpeg: nil, photoID: nil)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        try assertStrictObjects(schema)
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        XCTAssertTrue(serialized.contains("userQuote"))
        XCTAssertTrue(serialized.contains("correction"))
        XCTAssertTrue(serialized.contains("photo_inference"))
        XCTAssertTrue(serialized.contains("user_inference"))
        XCTAssertFalse(serialized.contains("steps"))
        XCTAssertThrowsError(try MendIntakeClient.requestBody(current: .init(), text: "", jpeg: jpeg, photoID: nil))
        XCTAssertThrowsError(try MendIntakeClient.requestBody(current: .init(), text: String(repeating: "x", count: 3001), jpeg: nil, photoID: nil))
    }

    func testCollectRetriesExplicitTokenExhaustionOnceWithUnchangedEvidence() async throws {
        let first = try incomplete()
        let second = try intake(make: field("IKEA", source: "user", quote: "IKEA"))
        var requests: [[String: Any]] = []
        var keys: [String] = []
        let client = MendIntakeClient { body, key in
            requests.append(body); keys.append(key)
            return requests.count == 1 ? first : second
        }
        let result = try await client.collect(current: .init(), text: "IKEA", jpeg: jpeg, photoID: "label-1", key: "test-key")
        XCTAssertEqual(result.details.make, "IKEA")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(keys, ["test-key", "test-key"])
        XCTAssertEqual(requests[0]["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(requests[1]["max_output_tokens"] as? Int, 8192)
        for request in requests {
            XCTAssertEqual((request["reasoning"] as? [String: String])?["effort"], "low")
            XCTAssertEqual(request["store"] as? Bool, false)
            XCTAssertNil(request["key"])
        }
        requests[0].removeValue(forKey: "max_output_tokens")
        requests[1].removeValue(forKey: "max_output_tokens")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: requests[0], options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: requests[1], options: [.sortedKeys]))
    }

    func testCollectStopsAfterSecondTokenExhaustionAndNeverAcceptsPartialAnswer() async throws {
        let complete = try intake(make: field("IKEA", source: "user", quote: "IKEA"))
        var partial = try XCTUnwrap(JSONSerialization.jsonObject(with: complete) as? [String: Any])
        partial["status"] = "incomplete"
        partial["incomplete_details"] = ["reason": "max_output_tokens"]
        let response = try JSONSerialization.data(withJSONObject: partial)
        var calls = 0
        let client = MendIntakeClient { _, _ in calls += 1; return response }
        do {
            _ = try await client.collect(current: .init(), text: "IKEA", jpeg: nil, photoID: nil, key: "test-key")
            XCTFail("Even valid-looking partial text must not be accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("answer limit"))
        }
        XCTAssertEqual(calls, 2)
    }

    func testCollectDoesNotRetryUnrelatedIncompleteFailedOrMalformedEnvelopes() async throws {
        let secret = "raw-server-details-should-not-be-shown"
        let payloads: [[String: Any]] = [
            ["status": "incomplete", "output": [], "incomplete_details": ["reason": "content_filter"]],
            ["status": "incomplete", "output": []],
            ["status": "failed", "output": [], "error": ["message": secret]],
            ["status": "completed", "output": [], "error": ["message": secret]],
            ["status": "incomplete", "output": [], "error": ["message": secret], "incomplete_details": ["reason": "max_output_tokens"]],
            ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"]],
            ["status": "incomplete", "output": "not-an-array", "incomplete_details": ["reason": "max_output_tokens"]],
            ["status": "completed", "output": [], "incomplete_details": ["reason": "max_output_tokens"]]
        ]
        let responses = try payloads.map { try JSONSerialization.data(withJSONObject: $0) } + [Data("not JSON".utf8)]
        for response in responses {
            var calls = 0
            let client = MendIntakeClient { _, _ in calls += 1; return response }
            do {
                _ = try await client.collect(current: .init(), text: "IKEA", jpeg: nil, photoID: nil, key: "test-key")
                XCTFail("Invalid or unfinished output should fail")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
            XCTAssertEqual(calls, 1)
        }
    }

    func testCollectDoesNotRetryAuthorizationRateLimitNetworkOrCancellationErrors() async throws {
        let failures: [Error] = [
            MendError.message("Meta could not authorize this request."),
            MendError.message("Meta's rate or account limit was reached."),
            URLError(.timedOut), CancellationError()
        ]
        for failure in failures {
            var calls = 0
            let client = MendIntakeClient { _, _ in calls += 1; throw failure }
            do {
                _ = try await client.collect(current: .init(), text: "IKEA", jpeg: nil, photoID: nil, key: "test-key")
                XCTFail("Transport errors must propagate")
            } catch {
                XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
            }
            XCTAssertEqual(calls, 1)
        }
    }

    func testCollectDoesNotRetryInvalidEvidenceFromCompletedAnswer() async throws {
        let response = try intake(make: field("Apple", source: "user", quote: "Apple"))
        var calls = 0
        let client = MendIntakeClient { _, _ in calls += 1; return response }
        do {
            _ = try await client.collect(current: .init(), text: "IKEA", jpeg: nil, photoID: nil, key: "test-key")
            XCTFail("Unrelated evidence must fail without retry")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not supported"))
        }
        XCTAssertEqual(calls, 1)
    }

    func testCancellationAfterFirstResponsePreventsTokenBudgetRetry() async throws {
        let response = try incomplete()
        var calls = 0
        let client = MendIntakeClient { _, _ in
            calls += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return response
        }
        let task = Task {
            try await client.collect(current: .init(), text: "IKEA", jpeg: nil, photoID: nil, key: "test-key")
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop intake before retrying")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testResponseDiagnosticsDistinguishTokenLimitFailedAndUnreadableAnswers() throws {
        let failed = try JSONSerialization.data(withJSONObject: ["status": "failed", "output": [],
            "error": ["message": "private backend detail"]])
        let missingStatus = try JSONSerialization.data(withJSONObject: ["output": []])
        let cases: [(Data, String)] = [
            (try incomplete(), "answer limit"),
            (try incomplete(reason: "content_filter"), "stopped before finishing"),
            (failed, "could not finish"),
            (missingStatus, "unreadable answer"),
            (Data("not JSON".utf8), "unreadable answer")
        ]
        for (response, message) in cases {
            XCTAssertThrowsError(try MendClient.responseText(response)) { error in
                XCTAssertTrue(error.localizedDescription.contains(message))
                XCTAssertFalse(error.localizedDescription.contains("private backend detail"))
            }
        }
    }

    func testConfirmedTextOnlyPlanHasNoImageAndRejectsMissingDetails() throws {
        let body = try MendClient.planRequestBody(details: readyDetails, jpeg: nil, photoID: "project-1")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        let text = try XCTUnwrap(content[0]["text"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(context["has_photo"] as? Bool, false)
        XCTAssertEqual(context["details_confirmed_by_user"] as? Bool, true)
        XCTAssertEqual(context["photo_id"] as? String, "project-1")
        XCTAssertThrowsError(try MendClient.planRequestBody(details: .init(problem: "Loose hinge"), jpeg: nil, photoID: "project-1"))
    }

    func testTextOnlyPlanCannotReturnMarkers() throws {
        let circle = PhotoMarker(kind: "circle", x: 0.2, y: 0.2, width: 0.2, height: 0.2, endX: nil, endY: nil, label: "Hinge")
        let invalid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnosis(step: step(marker: circle)))) as! [String: Any]
        XCTAssertThrowsError(try MendClient.decodePlanResponse(envelope(invalid), expectedPhotoID: "project-1", hasPhoto: false))
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnosis(step: step()))) as! [String: Any]
        XCTAssertNoThrow(try MendClient.decodePlanResponse(envelope(valid), expectedPhotoID: "project-1", hasPhoto: false))
    }

    func testFreshPhotoStepCannotUseOldMarkerAndNeedsUsefulHint() throws {
        let circle = PhotoMarker(kind: "circle", x: 0.2, y: 0.2, width: 0.2, height: 0.2, endX: nil, endY: nil, label: "Hinge")
        XCTAssertThrowsError(try diagnosis(step: step(marker: circle, hint: "Show the hinge", fresh: true)).validated(expectedPhotoID: "project-1"))
        XCTAssertThrowsError(try diagnosis(step: step(fresh: true)).validated(expectedPhotoID: "project-1"))
        XCTAssertThrowsError(try diagnosis(step: step(hint: " ", fresh: true)).validated(expectedPhotoID: "project-1"))
        XCTAssertThrowsError(try diagnosis(step: step(hint: "Show the hinge", fresh: false)).validated(expectedPhotoID: "project-1"))
        XCTAssertNoThrow(try diagnosis(step: step(hint: "Show the hinge straight on", fresh: true)).validated(expectedPhotoID: "project-1", hasPhoto: false))
    }

    func testOlderStepsDecodeWithAbsentPhotoMetadata() throws {
        let old = Data(#"{"id":"s1","title":"Support door","instruction":"Hold the door.","expectedResult":"It is supported.","caution":null,"marker":null}"#.utf8)
        let decoded = try JSONDecoder().decode(MendStep.self, from: old)
        XCTAssertNil(decoded.photoHint)
        XCTAssertNil(decoded.requiresFreshPhoto)
        XCTAssertNoThrow(try diagnosis(step: decoded).validated(expectedPhotoID: "project-1"))
    }

    private func assertStrictObjects(_ schema: [String: Any]) throws {
        if schema["type"] as? String == "object" {
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys))
            for child in properties.values { try assertStrictObjects(child) }
        }
        if let items = schema["items"] as? [String: Any] { try assertStrictObjects(items) }
        for option in schema["anyOf"] as? [[String: Any]] ?? [] { try assertStrictObjects(option) }
    }

    private func requestContext(_ body: [String: Any]) throws -> [String: Any] {
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

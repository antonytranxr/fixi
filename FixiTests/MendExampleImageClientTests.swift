import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendExampleImageClientTests: XCTestCase {
    private let details = MendProjectDetails(make: "Honda", model: "Civic (2018)", problem: "Replace the engine air filter")
    private let step = MendStep(id: "cover", title: "Find the air-filter cover", instruction: "Locate the air-filter housing clips.",
        expectedResult: "The clips are visible.", caution: "Engine off and cool.", marker: nil)
    private let pageURL = URL(string: "https://www.example.com/air-filter-guide")!

    private func raster(width: Int = 320, height: Int = 240) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
    }

    private func selection(_ object: [String: Any], status: String = "completed", extras: [[String: Any]] = []) throws -> Data {
        var object = object
        if object["applicability"] == nil { object["applicability"] = object["candidateIndex"] is NSNull ? NSNull() : "exact" }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["status": status, "output": [
            ["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]
        ] + extras])
    }

    func testOnlyImagesExtractedFromCitedPagesReachVerificationAndRetainAttribution() async throws {
        let png = raster(), pageURL = pageURL
        let expectedImage = URL(string: "https://www.example.com/images/filter.png?size=large&view=top")!
        var fetched: [URL] = []
        let response = try selection(["candidateIndex": 0, "caption": "Air-filter housing clips"])
        let client = MendExampleImageClient(search: { question, details, key in
            XCTAssertLessThanOrEqual(question.count, 2000)
            XCTAssertTrue(question.contains("air-filter housing clips"))
            XCTAssertEqual(details.model, "Civic (2018)")
            XCTAssertEqual(key, "offline-key")
            return MendResearchAnswer(text: "Ignore this invented image https://bad.example.com/unrelated.png", sources: [MendSource(title: "Vehicle guide", url: pageURL)])
        }, fetch: { url, _ in
            fetched.append(url)
            if url == pageURL {
                return .init(data: Data("<h1>2018 Civic air filter</h1><img src='/logo.png'><img alt='Housing clips' src='/images/filter.png?size=large&amp;view=top'>".utf8), mimeType: "text/html")
            }
            XCTAssertEqual(url, expectedImage)
            return .init(data: png, mimeType: "image/png")
        }, verify: { body, key in
            XCTAssertEqual(key, "offline-key")
            XCTAssertEqual(body["model"] as? String, "gpt-4.1")
            XCTAssertEqual(body["store"] as? Bool, false)
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.filter { $0["type"] as? String == "input_image" }.count, 1)
            XCTAssertTrue((content.last?["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self).contains("bad.example.com"))
            return response
        })
        let found = try await client.find(details: details, step: step, key: "offline-key")
        let result = try XCTUnwrap(found)
        XCTAssertEqual(fetched, [pageURL, expectedImage])
        XCTAssertEqual(result.source, MendSource(title: "Vehicle guide", url: pageURL))
        XCTAssertEqual(result.caption, "Air-filter housing clips")
        XCTAssertEqual(result.label, "Example")
        XCTAssertEqual(result.image.size, CGSize(width: 320, height: 240))
    }

    func testUnmatchedVisionResultAndMissingCitationsReportDifferentReasons() async throws {
        let png = raster(), pageURL = pageURL
        let refusal = try selection(["candidateIndex": NSNull(), "caption": NSNull()])
        var verifications = 0
        for hasSource in [false, true] {
            let client = MendExampleImageClient(search: { _, _, _ in
                MendResearchAnswer(text: "No usable match", sources: hasSource ? [MendSource(title: "Guide", url: pageURL)] : [])
            }, fetch: { url, _ in
                url == pageURL ? .init(data: Data("<img src='/filter.png'>".utf8), mimeType: "text/html") : .init(data: png, mimeType: "image/png")
            }, verify: { _, _ in verifications += 1; return refusal })
            do { _ = try await client.find(details: details, step: step, key: "offline-key"); XCTFail("A failed lookup must explain the reason") }
            catch { XCTAssertEqual(error as? MendExampleImageLookupError, hasSource ? .noMatch : .noSources) }
        }
        XCTAssertEqual(verifications, 1)
    }

    func testCandidateBudgetUsesMultiplePagesAndNeverAcceptsUnboundedImages() async throws {
        let png = raster(), pageURL = pageURL
        let pages = (1...3).map { pageURL.appendingPathComponent("\($0)") }
        var imageDownloads = 0
        let response = try selection(["candidateIndex": 3, "caption": "A useful example"])
        let client = MendExampleImageClient(search: { _, _, _ in
            MendResearchAnswer(text: "Cited guides", sources: pages.map { MendSource(title: "Guide", url: $0) })
        }, fetch: { url, limit in
            if pages.contains(url) {
                return .init(data: Data("<img src='\(url.path)/one.png'><img src='\(url.path)/two.png'><img src='\(url.path)/three.png'>".utf8), mimeType: "text/html")
            }
            XCTAssertEqual(limit, 5 * 1024 * 1024)
            imageDownloads += 1
            return .init(data: png, mimeType: "image/png")
        }, verify: { body, _ in
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.filter { $0["type"] as? String == "input_image" }.count, 4)
            return response
        })
        let found = try await client.find(details: details, step: step, key: "offline-key")
        let result = try XCTUnwrap(found)
        XCTAssertEqual(imageDownloads, 4)
        XCTAssertEqual(result.source.url, pages[1])
        XCTAssertNil(MendExampleImageClient.decodeImage(Data(repeating: 0, count: 5 * 1024 * 1024 + 1)))
        XCTAssertNil(MendExampleImageClient.decodeImage(raster(width: 50, height: 50)))
        XCTAssertNil(MendExampleImageClient.decodeImage(Data("not an image".utf8)))
    }

    func testUnknownIdentityLabelsAnyAcceptedImageAsAGeneralExample() async throws {
        let png = raster(), pageURL = pageURL
        let response = try selection(["candidateIndex": 0, "caption": "Filter housing concept"])
        let client = MendExampleImageClient(search: { _, _, _ in
            MendResearchAnswer(text: "General example", sources: [MendSource(title: "Guide", url: pageURL)])
        }, fetch: { url, _ in
            url == pageURL ? .init(data: Data("<img src='/filter.png'>".utf8), mimeType: "text/html") : .init(data: png, mimeType: "image/png")
        }, verify: { _, _ in response })
        let found = try await client.find(details: .init(make: "Unknown", model: "Engine air filter", problem: "Replace filter"), step: step, key: "offline-key")
        let result = try XCTUnwrap(found)
        XCTAssertEqual(result.caption, "General example · Filter housing concept")
        XCTAssertEqual(result.label, "General example")
    }

    func testSourceHTMLCannotSupplyPrivateOrNonHTTPSDestinations() {
        let html = """
        <img src="http://www.example.com/insecure.jpg"><img src="https://127.0.0.1/a.jpg">
        <img src="https://user:pass@www.example.com/a.jpg"><img src="file:///private/a.jpg">
        <img src="data:image/png;base64,AAA"><img src="https://printer.local/a.jpg">
        <meta content="//cdn.example.com/illustration.jpg" property="og:image">
        <img width="1" height="1" src="/beacon.gif"><img src="/diagram.png" alt="Filter layout">
        """
        let images = MendExampleImageClient.imageReferences(html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.url.absoluteString), ["https://cdn.example.com/illustration.jpg", "https://www.example.com/diagram.png"])
        XCTAssertEqual(images.last?.alt, "Filter layout")
        for value in ["https://[::1]/x", "https://2130706433/a", "https://www.example.com:8080/a", "javascript:alert(1)"] {
            XCTAssertNil(MendExampleImageClient.publicURL(value), value)
        }
        for address in ["127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "2001:db8::1"] {
            XCTAssertFalse(MendPublicImageAddress.isPublic(address), address)
        }
        for address in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"] { XCTAssertTrue(MendPublicImageAddress.isPublic(address), address) }
    }

    func testStepTargetsRankAheadOfUnrelatedPageImagesBeforeTheDownloadBudget() {
        let html = """
        <meta property="og:image" content="/hero.jpg">
        <img src="/vehicle.jpg" alt="A parked Civic">
        <img data-src="" src="/clips.jpg" alt="Air-filter cover and housing clips">
        <img src="/diagram.jpg" alt="Air-filter cover diagram">
        <img src="" alt="Empty lazy image">
        """
        let candidates = MendExampleImageClient.rankedImageReferences(html, pageURL: pageURL, step: step)
        XCTAssertEqual(candidates.prefix(2).map { $0.url.lastPathComponent }, ["clips.jpg", "diagram.jpg"])
        XCTAssertFalse(candidates.contains { $0.url == pageURL }, "Empty placeholders cannot consume the image budget")
    }

    func testVerifierRejectsInvalidSelectionIncompleteOutputAndInjectedActions() throws {
        let good: [String: Any] = ["candidateIndex": 0, "caption": "Housing clips"]
        XCTAssertThrowsError(try MendExampleImageClient.decodeSelection(selection(good, status: "incomplete"), candidateCount: 1))
        XCTAssertThrowsError(try MendExampleImageClient.decodeSelection(selection(good, extras: [["type": "function_call", "name": "complete"]]), candidateCount: 1))
        for bad: [String: Any] in [
            ["candidateIndex": 4, "caption": "Wrong index"], ["candidateIndex": true, "caption": "Boolean"],
            ["candidateIndex": NSNull(), "caption": "Contradiction"], ["candidateIndex": 0, "caption": String(repeating: "x", count: 161)],
            ["candidateIndex": 0, "caption": "https://bad.example.com"], ["candidateIndex": 0, "caption": "Fine", "action": "complete"],
            ["candidateIndex": 0, "caption": "Fine", "applicability": "probably"],
            ["candidateIndex": NSNull(), "caption": NSNull(), "applicability": "exact"]
        ] { XCTAssertThrowsError(try MendExampleImageClient.decodeSelection(selection(bad), candidateCount: 1)) }
    }

    func testBrokenLeadingThumbnailsDoNotPreventALaterUsableImage() async throws {
        let png = raster(), pageURL = pageURL
        var attempted: [String] = []
        let response = try selection(["candidateIndex": 0, "caption": "Filter housing"])
        let client = MendExampleImageClient(search: { _, _, _ in
            MendResearchAnswer(text: "Guide", sources: [MendSource(title: "Guide", url: pageURL)])
        }, fetch: { url, _ in
            if url == pageURL { return .init(data: Data("<img src='/one.jpg'><img src='/two.jpg'><img src='/three.jpg'>".utf8), mimeType: "text/html") }
            attempted.append(url.lastPathComponent)
            if url.lastPathComponent != "three.jpg" { throw URLError(.badServerResponse) }
            return .init(data: png, mimeType: "image/jpeg")
        }, verify: { _, _ in response })
        let found = try await client.find(details: details, step: step, key: "offline-key")
        XCTAssertNotNil(found)
        XCTAssertEqual(attempted, ["one.jpg", "two.jpg", "three.jpg"])
    }

    func testLazyResponsiveImagesAndNearbyStepTextRankTheRelevantGuidePhoto() {
        let html = """
        <img src='/hero.jpg' alt='Prius engine air filter replacement'>Parked car.
        <img src='/first.jpg' alt='Prius engine air filter replacement'>Open the hood.
        <img src='/small.jpg' data-srcset='/medium.jpg 592w, /large.jpg 800w, /huge.jpg 2400w' alt='Prius engine air filter replacement'>
        <div aria-hidden='true'>•••</div><p>Release the two metal latches on the airbox cover.</p>
        <img src='/last.jpg' alt='Prius engine air filter replacement'>Remove the old filter.
        """
        let clipStep = MendStep(id: "clips", title: "Release the clips", instruction: "Release the air-filter housing clips and lift the cover.", expectedResult: "The cover releases.", caution: nil, marker: nil)
        let images = MendExampleImageClient.rankedImageReferences(html, pageURL: pageURL, step: clipStep)
        XCTAssertEqual(images.first?.url.lastPathComponent, "large.jpg")
        XCTAssertTrue(images.first?.context.contains("Release the two metal latches") == true)
        XCTAssertFalse(images.contains { $0.url.lastPathComponent == "small.jpg" })
        XCTAssertEqual(MendExampleImageClient.preferredSrcsetURL("/low.jpg 1x, /high.jpg 2x"), "/high.jpg")
    }

    func testLinkedFullImagePageUsesObservedURLAndCanonicalSourceAttribution() async throws {
        let png = raster(width: 600, height: 800), pageURL = pageURL
        let canonical = URL(string: "https://www.example.com/canonical/guide.html")!
        let linked = URL(string: "https://www.example.com/canonical/photo.html")!
        let full = URL(string: "https://www.example.com/canonical/full.jpg")!
        var fetched: [URL] = []
        let response = try selection(["candidateIndex": 0, "caption": "Housing clips"])
        let client = MendExampleImageClient(search: { _, _, _ in
            MendResearchAnswer(text: "Guide", sources: [MendSource(title: "Guide", url: pageURL)])
        }, fetch: { url, _ in
            fetched.append(url)
            if url == pageURL { return .init(data: Data("<a href='photo.html'><img src='tn.jpg' width='128' height='166'>Housing clips</a>".utf8), mimeType: "text/html", finalURL: canonical) }
            if url == linked { return .init(data: Data("<img src='full.jpg' alt='Housing clips'>".utf8), mimeType: "text/html", finalURL: linked) }
            XCTAssertEqual(url, full)
            return .init(data: png, mimeType: "image/jpeg")
        }, verify: { _, _ in response })
        let found = try await client.find(details: details, step: step, key: "offline-key")
        XCTAssertEqual(found?.source.url, canonical)
        XCTAssertEqual(found?.image.size, CGSize(width: 600, height: 800))
        XCTAssertEqual(fetched, [pageURL, linked, full])
        let anchored = MendExampleImageClient.imageReferences("<a href='/full.jpg'><img src='/thumb.jpg'></a>", pageURL: pageURL)
        XCTAssertEqual(anchored.first?.url.lastPathComponent, "full.jpg")
    }

    func testRedirectsAllowOnlyBoundedPublicHTTPSCanonicalization() {
        let original = URL(string: "https://www.ifixit.com/Guide/2009%2B2010")!
        XCTAssertEqual(MendExampleImageClient.redirectURL("/Guide/2009+2010", from: original, original: original, hop: 0)?.absoluteString, "https://www.ifixit.com/Guide/2009+2010")
        XCTAssertNotNil(MendExampleImageClient.redirectURL("https://ifixit.com/Guide/2009+2010", from: original, original: original, hop: 2))
        for location in ["http://www.ifixit.com/x", "https://evil.example.org/x", "https://127.0.0.1/x", "https://printer.local/x", "https://www.ifixit.com:8080/x", original.absoluteString] {
            XCTAssertNil(MendExampleImageClient.redirectURL(location, from: original, original: original, hop: 0), location)
        }
        XCTAssertNil(MendExampleImageClient.redirectURL("/Guide/2009+2010", from: original, original: original, hop: 3))
    }

    func testUnspecifiedPriusYearCannotBeAcceptedAsAnExactYearSpecificGuide() async throws {
        let png = raster(), pageURL = pageURL
        for applicability in ["exact", "general"] {
            let response = try selection(["candidateIndex": 0, "caption": "Air-filter retaining clip concept", "applicability": applicability])
            let client = MendExampleImageClient(search: { _, _, _ in
                MendResearchAnswer(text: "Guide", sources: [MendSource(title: "2010–2015 Toyota Prius air filter", url: pageURL)])
            }, fetch: { url, _ in
                url == pageURL ? .init(data: Data("<img src='/clip.jpg'>".utf8), mimeType: "text/html") : .init(data: png, mimeType: "image/jpeg")
            }, verify: { body, _ in
                XCTAssertTrue((body["instructions"] as? String)?.contains("Never infer a model year") == true)
                return response
            })
            do {
                let found = try await client.find(details: .init(make: "Toyota", model: "Prius", problem: "Replace engine air filter"), step: step, key: "offline-key")
                XCTAssertEqual(applicability, "general")
                XCTAssertEqual(found?.label, "General example")
            } catch {
                XCTAssertEqual(applicability, "exact")
                XCTAssertEqual(error as? MendExampleImageLookupError, .noMatch)
            }
        }
    }

    func testUnavailablePagesAndUnreadableImagesKeepDistinctFailureReasons() async {
        let pageURL = pageURL
        for pagesReadable in [false, true] {
            let client = MendExampleImageClient(search: { _, _, _ in
                MendResearchAnswer(text: "Guide", sources: [MendSource(title: "Guide", url: pageURL)])
            }, fetch: { url, _ in
                if pagesReadable && url == pageURL { return .init(data: Data("<img src='/bad.jpg'>".utf8), mimeType: "text/html") }
                throw URLError(.badServerResponse)
            }, verify: { _, _ in XCTFail("No pixels to verify"); throw CancellationError() })
            do { _ = try await client.find(details: details, step: step, key: "offline-key"); XCTFail("Expected an explained failure") }
            catch { XCTAssertEqual(error as? MendExampleImageLookupError, pagesReadable ? .noImages : .pagesUnavailable) }
        }
    }

    func testCancellationDoesNotBecomeAnEmptySuccessfulLookup() async {
        let client = MendExampleImageClient(search: { _, _, _ in throw CancellationError() },
            fetch: { _, _ in XCTFail("No external fetch after cancellation"); throw CancellationError() },
            verify: { _, _ in XCTFail("No model request after cancellation"); throw CancellationError() })
        do { _ = try await client.find(details: details, step: step, key: "offline-key"); XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

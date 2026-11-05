import XCTest
@testable import Fixi

final class MendShoppingLinksTests: XCTestCase {
    private func query(_ link: MendShoppingLink) throws -> String {
        let components = try XCTUnwrap(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.amazon.com")
        XCTAssertEqual(components.path, "/s")
        XCTAssertNil(components.fragment)
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.name, "k")
        return try XCTUnwrap(components.queryItems?.first?.value)
    }

    func testReplacementPartsUseKnownConfirmedIdentityButToolsStayGeneric() throws {
        let details = MendProjectDetails(make: "Toyota", model: "2020 Corolla", problem: "Replace engine air filter")
        let links = MendShoppingLinks.make(tools: ["10 mm socket"], parts: ["Engine air filter"], confirmedProject: details)
        XCTAssertEqual(links.map(\.itemIndex), [0, 1])
        XCTAssertEqual(links.map(\.kind), [.tool, .part])
        XCTAssertEqual(try query(links[0]), "10 mm socket")
        XCTAssertEqual(try query(links[1]), "Engine air filter Toyota 2020 Corolla")
    }

    func testUnconfirmedUnknownAndGuessedIdentityIsOmitted() throws {
        let unconfirmed = MendShoppingLinks.make(tools: [], parts: ["Replacement hinge"], confirmedProject: nil)
        XCTAssertEqual(try query(unconfirmed[0]), "Replacement hinge")
        let guessed = MendProjectDetails(make: "Acme", model: "Pro 200", suggestedFields: ["model"])
        XCTAssertEqual(try query(MendShoppingLinks.make(tools: [], parts: ["Replacement hinge"], confirmedProject: guessed)[0]),
                       "Replacement hinge Acme")
        for placeholder in ["Unknown", "Unknown model", "N/A", "Not sure", "I don’t know", "", "  "] {
            let details = MendProjectDetails(make: placeholder, model: placeholder)
            XCTAssertEqual(try query(MendShoppingLinks.make(tools: [], parts: ["Replacement hinge"], confirmedProject: details)[0]),
                           "Replacement hinge", placeholder)
        }
    }

    func testSuppliedSpecificationsRemainInSearchWithoutInventedNumbers() throws {
        let links = MendShoppingLinks.make(tools: ["  Phillips\n screwdriver\t "], parts: ["Two 1/4\" O-rings, EPDM"],
                                          confirmedProject: MendProjectDetails(make: "Unknown", model: "Unknown"))
        XCTAssertEqual(links[0].title, "Phillips screwdriver")
        XCTAssertEqual(try query(links[0]), "Phillips screwdriver")
        XCTAssertEqual(try query(links[1]), "Two 1/4\" O-rings, EPDM")
    }

    func testSearchTextCannotInjectAHostFragmentOrAffiliateParameter() throws {
        let item = "Seal &tag=attacker-20 #fragment ?redirect=https://example.com + washer"
        let links = MendShoppingLinks.make(tools: [], parts: [item], confirmedProject: nil)
        XCTAssertEqual(try query(links[0]), item)
        XCTAssertFalse(links[0].url.absoluteString.contains("&tag="))
    }

    func testExistingIdentityIsNotRepeatedAndEmptyEntriesKeepDisplayIndices() throws {
        let details = MendProjectDetails(make: "Toyota", model: "Corolla")
        let links = MendShoppingLinks.make(tools: ["", "None", "Socket"], parts: ["Toyota Corolla engine air filter"], confirmedProject: details)
        XCTAssertEqual(links.map(\.itemIndex), [2, 3])
        XCTAssertEqual(try query(links[1]), "Toyota Corolla engine air filter")
        XCTAssertTrue(MendShoppingLinks.make(tools: [], parts: [], confirmedProject: details).isEmpty)
    }

    func testMaximumPlanSizeAndBoundedQueries() throws {
        let tools = (0..<12).map { "Tool \($0)" }
        let parts = (0..<12).map { "Part \($0)" }
        let links = MendShoppingLinks.make(tools: tools, parts: parts, confirmedProject: nil)
        XCTAssertEqual(links.count, 24)
        XCTAssertEqual(links.map(\.itemIndex), Array(0..<24))
        let extras = MendShoppingLinks.make(tools: tools + ["Unexpected tool"], parts: parts + ["Unexpected part"], confirmedProject: nil)
        XCTAssertTrue(extras.allSatisfy { $0.itemIndex < 24 })
        XCTAssertFalse(extras.contains { $0.title.hasPrefix("Unexpected") })
        let oversized = MendShoppingLinks.make(tools: [], parts: [String(repeating: "a", count: 500)],
            confirmedProject: MendProjectDetails(make: String(repeating: "b", count: 500), model: String(repeating: "c", count: 500)))
        XCTAssertLessThanOrEqual(try query(oversized[0]).count, 482)
    }
}

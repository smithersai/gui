import XCTest
import SwiftUI
@testable import SmithersGUI

@MainActor
final class TicketsViewSmokeTests: XCTestCase {
    func testTicketsViewRenders() {
        let client = SmithersClient(cwd: "/tmp")
        let view = TicketsView(smithers: client)
        _ = view.body
    }
}

final class TicketLRUCacheTests: XCTestCase {
    func testTicketContentCacheReturnsMostRecentlyOpenedTickets() {
        var cache = TicketContentLRUCache(capacity: 2)
        cache.store(Ticket(id: "one", content: "# One", status: nil, createdAtMs: nil, updatedAtMs: nil))
        cache.store(Ticket(id: "two", content: "# Two", status: nil, createdAtMs: nil, updatedAtMs: nil))

        XCTAssertEqual(cache.idsMostRecentFirst, ["two", "one"])
        XCTAssertEqual(cache.ticket(for: "one")?.content, "# One")
        XCTAssertEqual(cache.idsMostRecentFirst, ["one", "two"])

        cache.store(Ticket(id: "three", content: "# Three", status: nil, createdAtMs: nil, updatedAtMs: nil))
        XCTAssertNil(cache.peek("two"))
        XCTAssertEqual(cache.idsMostRecentFirst, ["three", "one"])
    }

    func testNeovimSessionCacheEvictsLeastRecentlyUsedSession() {
        var cache = TicketNeovimSessionLRUCache(capacity: 2)
        let first = cache.upsert(ticketId: "one", command: "nvim one.md", workingDirectory: "/tmp/tickets")
        let second = cache.upsert(ticketId: "two", command: "nvim two.md", workingDirectory: "/tmp/tickets")

        XCTAssertTrue(first.evicted.isEmpty)
        XCTAssertTrue(second.evicted.isEmpty)
        XCTAssertEqual(cache.ticketIdsMostRecentFirst, ["two", "one"])
        XCTAssertNotNil(cache.session(for: "one"))
        XCTAssertEqual(cache.ticketIdsMostRecentFirst, ["one", "two"])

        let third = cache.upsert(ticketId: "three", command: "nvim three.md", workingDirectory: "/tmp/tickets")
        XCTAssertEqual(third.evicted.map(\.ticketId), ["two"])
        XCTAssertNil(cache.peek("two"))
        XCTAssertEqual(cache.ticketIdsMostRecentFirst, ["three", "one"])
    }

    func testNeovimSessionCacheEvictsReplacedCommandForSameTicket() {
        var cache = TicketNeovimSessionLRUCache(capacity: 2)
        let first = cache.upsert(ticketId: "one", command: "nvim one.md", workingDirectory: "/tmp/tickets")
        let replacement = cache.upsert(ticketId: "one", command: "/opt/homebrew/bin/nvim one.md", workingDirectory: "/tmp/tickets")

        XCTAssertEqual(replacement.evicted.map(\.sessionId), [first.session.sessionId])
        XCTAssertEqual(cache.peek("one")?.sessionId, replacement.session.sessionId)
        XCTAssertEqual(cache.ticketIdsMostRecentFirst, ["one"])
    }
}

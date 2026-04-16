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

@MainActor
final class TicketClientFilesystemTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smithers-gui-ticket-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testListTicketsReadsMarkdownFiles() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let ticketsDir = temp.appendingPathComponent(".smithers/tickets")
        try FileManager.default.createDirectory(at: ticketsDir, withIntermediateDirectories: true)
        try "# One\n\nBody".write(to: ticketsDir.appendingPathComponent("001-first.md"), atomically: true, encoding: .utf8)
        try "# Two\n\nBody".write(to: ticketsDir.appendingPathComponent("002-second.md"), atomically: true, encoding: .utf8)
        try "skip".write(to: ticketsDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let client = SmithersClient(cwd: temp.path)
        let tickets = try await client.listTickets()
        XCTAssertEqual(tickets.map(\.id), ["001-first", "002-second"])
    }

    func testSearchTicketsMatchesIdAndContentCaseInsensitive() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let ticketsDir = temp.appendingPathComponent(".smithers/tickets")
        try FileManager.default.createDirectory(at: ticketsDir, withIntermediateDirectories: true)
        try "# Ticket\n\n## Summary\n\nFix Login".write(to: ticketsDir.appendingPathComponent("eng-login.md"), atomically: true, encoding: .utf8)
        try "# Ticket\n\n## Summary\n\nImprove docs".write(to: ticketsDir.appendingPathComponent("docs-update.md"), atomically: true, encoding: .utf8)

        let client = SmithersClient(cwd: temp.path)
        let idResults = try await client.searchTickets(query: "ENG")
        XCTAssertEqual(idResults.map(\.id), ["eng-login"])

        let contentResults = try await client.searchTickets(query: "login")
        XCTAssertEqual(contentResults.map(\.id), ["eng-login"])
    }

    func testCreateGetUpdateDeleteTicketLifecycle() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let client = SmithersClient(cwd: temp.path)
        let markdown = "# My Ticket\n\n## Goal\n\nPreserve **markdown**."

        let created = try await client.createTicket(id: "feat-markdown", content: markdown)
        XCTAssertEqual(created.id, "feat-markdown")
        XCTAssertEqual(created.content, markdown)

        let fetched = try await client.getTicket("feat-markdown")
        XCTAssertEqual(fetched.content, markdown)

        let updatedMarkdown = "# My Ticket\n\n## Goal\n\nUpdated body."
        let updated = try await client.updateTicket("feat-markdown", content: updatedMarkdown)
        XCTAssertEqual(updated.id, "feat-markdown")
        XCTAssertEqual(updated.content, updatedMarkdown)

        try await client.deleteTicket("feat-markdown")
        do {
            _ = try await client.getTicket("feat-markdown")
            XCTFail("Expected not found after delete")
        } catch {
            guard case SmithersError.notFound = error else {
                return XCTFail("Expected SmithersError.notFound, got: \(error)")
            }
        }
    }

    func testSearchTicketsRejectsEmptyQuery() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let client = SmithersClient(cwd: temp.path)
        do {
            _ = try await client.searchTickets(query: "")
            XCTFail("Expected empty query to fail")
        } catch {
            guard case SmithersError.api(let message) = error else {
                return XCTFail("Expected SmithersError.api, got: \(error)")
            }
            XCTAssertEqual(message, "query must not be empty")
        }
    }

    func testLocalTicketFilePathReturnsValidatedMarkdownPath() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let client = SmithersClient(cwd: temp.path)
        _ = try await client.createTicket(id: "feat-nvim", content: "# Nvim")

        let path = try client.localTicketFilePath(for: "feat-nvim")
        XCTAssertEqual(
            path,
            temp.appendingPathComponent(".smithers/tickets/feat-nvim.md").path
        )

        XCTAssertThrowsError(try client.localTicketFilePath(for: "../escape", requireExisting: false))
    }

    func testNeovimDetectorFindsExecutableOnInjectedPath() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let bin = temp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let nvim = bin.appendingPathComponent("nvim")
        try "#!/bin/sh\n".write(to: nvim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nvim.path)

        XCTAssertEqual(
            NeovimDetector.executablePath(environment: ["PATH": bin.path]),
            nvim.path
        )
        XCTAssertTrue(NeovimDetector.isAvailable(environment: ["PATH": bin.path]))
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

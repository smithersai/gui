import SwiftUI

struct TicketsView: View {
    @ObservedObject var smithers: SmithersClient

    @State private var tickets: [Ticket] = []
    @State private var selectedId: String?
    @State private var searchText: String = ""
    @State private var detailContent: String = ""
    @State private var originalContent: String = ""
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var error: String?
    @State private var showCreateForm = false
    @State private var newTicketId: String = ""
    @State private var newTicketContent: String = ""
    @State private var showUnsavedAlert = false
    @State private var pendingSelectionId: String?
    @State private var showDeleteAlert = false
    @State private var neovimPath: String? = NeovimDetector.executablePath()
    @State private var ticketContentCache = TicketContentLRUCache(capacity: 32)
    @State private var neovimSessionCache = TicketNeovimSessionLRUCache(capacity: 6)
    @State private var ticketPrefetchTasks: [String: Task<Void, Never>] = [:]
    @AppStorage(AppPreferenceKeys.vimModeEnabled) private var vimModeEnabled = false

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTicket: Ticket? {
        guard let selectedId else { return nil }
        return tickets.first { $0.id == selectedId }
    }

    private var hasUnsavedChanges: Bool {
        detailContent != originalContent
    }

    private var neovimAvailable: Bool {
        neovimPath != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorBanner(error)
            }

            HStack(spacing: 0) {
                ticketList
                    .frame(width: 340)
                Divider().background(Theme.border)
                detailPane
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("tickets.root")
        .task(id: normalizedQuery) {
            await loadTickets()
        }
        .onAppear {
            refreshNeovimPath()
        }
        .onDisappear {
            cancelTicketPrefetches()
            closeCachedNeovimSessions()
        }
        .onChange(of: vimModeEnabled) { _, _ in
            refreshNeovimPath()
            if vimModeEnabled, let selectedId {
                _ = prepareNeovimSession(ticketId: selectedId)
            } else {
                closeCachedNeovimSessions()
            }
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Discard", role: .destructive) {
                if let pendingSelectionId {
                    applySelection(ticketId: pendingSelectionId)
                }
                pendingSelectionId = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSelectionId = nil
            }
        } message: {
            Text("You have unsaved ticket changes. Discard them?")
        }
        .alert("Delete Ticket", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedTicket() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the selected ticket file.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Tickets")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Text("\(tickets.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .themedPill(cornerRadius: 8)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                TextField("Search tickets...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("tickets.search")
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            Button(action: { showCreateForm.toggle() }) {
                Image(systemName: showCreateForm ? "xmark" : "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.accent)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tickets.createButton")

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: { Task { await loadTickets() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tickets.refreshButton")
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    private var ticketList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showCreateForm {
                    createForm
                }

                if tickets.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "ticket")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No tickets found")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ForEach(tickets) { ticket in
                        Button(action: { selectTicket(ticket) }) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ticket.id)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                let snippet = ticketSnippet(displayContent(for: ticket), maxLength: 92)
                                if !snippet.isEmpty {
                                    Text(snippet)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themedSidebarRowBackground(isSelected: selectedId == ticket.id)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            handleTicketHover(ticket, hovering: hovering)
                        }
                        .accessibilityIdentifier("tickets.row.\(ticket.id)")
                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .refreshable { await loadTickets() }
        .background(Theme.surface2)
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW TICKET")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)

            TextField("ticket-id (e.g. feat-login-flow)", text: $newTicketId)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("tickets.create.id")

            TextEditor(text: $newTicketContent)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 80)
                .padding(6)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("tickets.create.content")

            HStack(spacing: 8) {
                Button(action: { Task { await createTicket() } }) {
                    HStack(spacing: 4) {
                        if isCreating {
                            ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                        }
                        Text("Create")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(newTicketId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                .accessibilityIdentifier("tickets.create.submit")

                Button("Cancel") {
                    showCreateForm = false
                    newTicketId = ""
                    newTicketContent = ""
                }
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("tickets.create.cancel")
            }
        }
        .padding(14)
        .background(Theme.base.opacity(0.45))
        .border(Theme.border, edges: [.bottom])
        .accessibilityIdentifier("tickets.create.form")
    }

    private var detailPane: some View {
        Group {
            if let ticket = selectedTicket {
                let usingNeovim = neovimSession(for: ticket) != nil

                VStack(spacing: 0) {
                    HStack {
                        Text(ticket.id)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)

                        if hasUnsavedChanges && !usingNeovim {
                            Text("Modified")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.warning.opacity(0.14))
                                .cornerRadius(4)
                        }

                        Spacer()

                        if usingNeovim {
                            Text("Neovim")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.success)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.success.opacity(0.14))
                                .cornerRadius(4)

                            Button(action: { Task { await loadTickets() } }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Reload")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .themedPill(cornerRadius: 6)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading || isDeleting)
                            .accessibilityIdentifier("tickets.detail.nvimReload")
                        }

                        if hasUnsavedChanges && !usingNeovim {
                            Button(action: { Task { await saveSelectedTicket() } }) {
                                HStack(spacing: 4) {
                                    if isSaving {
                                        ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                                    }
                                    Text("Save")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Theme.accent)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving || isDeleting)
                            .accessibilityIdentifier("tickets.detail.save")
                        }

                        Button(action: { showDeleteAlert = true }) {
                            HStack(spacing: 4) {
                                if isDeleting {
                                    ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                                }
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .themedPill(cornerRadius: 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting || isSaving)
                        .accessibilityIdentifier("tickets.detail.delete")
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .border(Theme.border, edges: [.bottom])

                    ticketEditor(for: ticket)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "ticket")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a ticket")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("tickets.detail.placeholder")
            }
        }
        .background(Theme.surface1)
    }

    @ViewBuilder
    private func ticketEditor(for ticket: Ticket) -> some View {
        if let session = neovimSession(for: ticket) {
            TerminalView(
                sessionId: session.sessionId,
                command: session.command,
                workingDirectory: session.workingDirectory,
                onClose: {
                    Task { @MainActor in
                        await loadTickets()
                    }
                }
            )
            .id(session.sessionId)
            .accessibilityIdentifier("tickets.detail.nvimTerminal")
        } else {
            VStack(spacing: 0) {
                if let message = neovimFallbackMessage(for: ticket) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                        Text(message)
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundColor(Theme.warning)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.warning.opacity(0.1))
                    .border(Theme.border, edges: [.bottom])
                    .accessibilityIdentifier("tickets.detail.nvimFallback")
                }

                MarkdownTextEditor(text: $detailContent)
                    .accessibilityIdentifier("tickets.detail.editor")
            }
        }
    }

    private func neovimSession(for ticket: Ticket) -> TicketNeovimSession? {
        guard vimModeEnabled, neovimAvailable, !hasUnsavedChanges else {
            return nil
        }
        return neovimSessionCache.peek(ticket.id)
    }

    private func neovimCommand(for ticket: Ticket) -> String? {
        guard vimModeEnabled,
              neovimAvailable,
              !hasUnsavedChanges,
              let neovimPath,
              let ticketPath = try? smithers.localTicketFilePath(for: ticket.id)
        else {
            return nil
        }

        return "\(ticketShellQuote(neovimPath)) \(ticketShellQuote(ticketPath))"
    }

    private func neovimWorkingDirectory(for ticket: Ticket) -> String? {
        guard let ticketPath = try? smithers.localTicketFilePath(for: ticket.id) else {
            return nil
        }
        return (ticketPath as NSString).deletingLastPathComponent
    }

    private func neovimFallbackMessage(for ticket: Ticket) -> String? {
        guard vimModeEnabled else { return nil }
        if !neovimAvailable {
            return "Neovim is not available. Open Settings to refresh detection."
        }
        if hasUnsavedChanges {
            return "Save or discard unsaved changes before opening this ticket in Neovim."
        }
        if (try? smithers.localTicketFilePath(for: ticket.id)) == nil {
            return "Neovim mode requires this ticket to be backed by a local .smithers/tickets file."
        }
        if neovimSessionCache.peek(ticket.id) == nil {
            return "Preparing Neovim for this ticket."
        }
        return nil
    }

    private func refreshNeovimPath() {
        let detectedPath = NeovimDetector.executablePath()
        neovimPath = detectedPath
        if detectedPath == nil {
            vimModeEnabled = false
            closeCachedNeovimSessions()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { error = nil }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
        }
        .foregroundColor(Theme.danger)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.1))
        .border(Theme.border, edges: [.bottom])
        .accessibilityIdentifier("tickets.error")
    }

    @MainActor
    private func loadTickets() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let loadedTickets = if normalizedQuery.isEmpty {
                try await smithers.listTickets()
            } else {
                try await smithers.searchTickets(query: normalizedQuery)
            }

            tickets = mergeLoadedTicketsWithCache(loadedTickets)

            if let selectedId, tickets.contains(where: { $0.id == selectedId }) {
                if !hasUnsavedChanges {
                    applySelection(ticketId: selectedId)
                }
            } else if let first = tickets.first, !hasUnsavedChanges {
                applySelection(ticketId: first.id)
            } else if !hasUnsavedChanges {
                selectedId = nil
                detailContent = ""
                originalContent = ""
            }
        } catch {
            self.error = error.localizedDescription
            tickets = []
            selectedId = nil
            detailContent = ""
            originalContent = ""
        }
    }

    @MainActor
    private func createTicket() async {
        let ticketId = newTicketId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticketId.isEmpty else { return }

        isCreating = true
        error = nil
        defer { isCreating = false }

        do {
            let content = newTicketContent.isEmpty ? nil : newTicketContent
            let created = try await smithers.createTicket(id: ticketId, content: content)
            storeTicketInCache(created)
            showCreateForm = false
            newTicketId = ""
            newTicketContent = ""

            await loadTickets()
            if tickets.contains(where: { $0.id == created.id }) {
                applySelection(ticketId: created.id)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func saveSelectedTicket() async {
        guard let ticket = selectedTicket else { return }

        let capturedId = ticket.id
        let contentToSave = detailContent
        isSaving = true
        error = nil
        defer { isSaving = false }

        do {
            let updated = try await smithers.updateTicket(capturedId, content: contentToSave)
            // Only apply if the same ticket is still selected.
            guard selectedId == capturedId else { return }
            if let index = tickets.firstIndex(where: { $0.id == capturedId }) {
                let normalized = Ticket(
                    id: updated.id,
                    content: updated.content ?? contentToSave,
                    status: updated.status,
                    createdAtMs: updated.createdAtMs,
                    updatedAtMs: updated.updatedAtMs
                )
                tickets[index] = normalized
                storeTicketInCache(normalized)
            }
            originalContent = contentToSave
        } catch {
            guard selectedId == capturedId else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func deleteSelectedTicket() async {
        guard let ticket = selectedTicket else { return }

        isDeleting = true
        error = nil
        defer { isDeleting = false }

        do {
            try await smithers.deleteTicket(ticket.id)
            ticketContentCache.remove(ticket.id)
            removeCachedNeovimSession(ticket.id)
            await loadTickets()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func selectTicket(_ ticket: Ticket) {
        guard ticket.id != selectedId else { return }
        if hasUnsavedChanges {
            pendingSelectionId = ticket.id
            showUnsavedAlert = true
            return
        }
        applySelection(ticketId: ticket.id)
    }

    private func applySelection(ticketId: String) {
        selectedId = ticketId
        let content = cachedContent(for: ticketId) ?? ""
        detailContent = content
        originalContent = content
        _ = prepareNeovimSession(ticketId: ticketId)
        scheduleTicketPrefetch(ticketId: ticketId, delayNanoseconds: 0, prewarmNeovim: false)
    }

    private func displayContent(for ticket: Ticket) -> String {
        ticket.content ?? ticketContentCache.peek(ticket.id)?.content ?? ""
    }

    private func cachedContent(for ticketId: String) -> String? {
        if let cached = ticketContentCache.ticket(for: ticketId),
           let content = cached.content {
            return content
        }

        guard let ticket = tickets.first(where: { $0.id == ticketId }) else {
            return nil
        }
        storeTicketInCache(ticket)
        return ticket.content
    }

    private func mergeLoadedTicketsWithCache(_ loadedTickets: [Ticket]) -> [Ticket] {
        loadedTickets.map { ticket in
            if ticket.content != nil {
                storeTicketInCache(ticket)
                return ticket
            }
            return ticketContentCache.peek(ticket.id) ?? ticket
        }
    }

    private func mergeTicketIntoList(_ ticket: Ticket) {
        if let index = tickets.firstIndex(where: { $0.id == ticket.id }) {
            tickets[index] = ticket
        }
    }

    private func storeTicketInCache(_ ticket: Ticket) {
        guard ticket.content != nil else { return }
        ticketContentCache.store(ticket)
    }

    private func handleTicketHover(_ ticket: Ticket, hovering: Bool) {
        if hovering {
            scheduleTicketPrefetch(ticketId: ticket.id, delayNanoseconds: 120_000_000, prewarmNeovim: true)
        } else if selectedId != ticket.id {
            cancelTicketPrefetch(ticket.id)
        }
    }

    private func scheduleTicketPrefetch(
        ticketId: String,
        delayNanoseconds: UInt64,
        prewarmNeovim: Bool
    ) {
        ticketPrefetchTasks[ticketId]?.cancel()
        ticketPrefetchTasks[ticketId] = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await prefetchTicket(ticketId: ticketId, prewarmNeovim: prewarmNeovim)
            ticketPrefetchTasks[ticketId] = nil
        }
    }

    private func cancelTicketPrefetch(_ ticketId: String) {
        ticketPrefetchTasks[ticketId]?.cancel()
        ticketPrefetchTasks[ticketId] = nil
    }

    private func cancelTicketPrefetches() {
        for task in ticketPrefetchTasks.values {
            task.cancel()
        }
        ticketPrefetchTasks.removeAll()
    }

    @MainActor
    private func prefetchTicket(ticketId: String, prewarmNeovim: Bool) async {
        var prefetchedTicket: Ticket?
        if let cached = ticketContentCache.ticket(for: ticketId),
           cached.content != nil {
            prefetchedTicket = cached
        } else if let ticket = tickets.first(where: { $0.id == ticketId }),
                  ticket.content != nil {
            storeTicketInCache(ticket)
            prefetchedTicket = ticket
        } else {
            do {
                let fetched = try await smithers.getTicket(ticketId)
                guard !Task.isCancelled else { return }
                guard selectedId == ticketId || tickets.contains(where: { $0.id == ticketId }) else { return }
                storeTicketInCache(fetched)
                mergeTicketIntoList(fetched)
                prefetchedTicket = fetched
            } catch {
                return
            }
        }

        if selectedId == ticketId,
           !hasUnsavedChanges,
           let content = prefetchedTicket?.content {
            detailContent = content
            originalContent = content
        }

        if prewarmNeovim {
            _ = prepareNeovimSession(ticketId: ticketId, prewarm: true)
        }
    }

    @discardableResult
    private func prepareNeovimSession(ticketId: String, prewarm: Bool = false) -> TicketNeovimSession? {
        guard vimModeEnabled,
              neovimAvailable,
              !hasUnsavedChanges,
              let ticket = tickets.first(where: { $0.id == ticketId }) ?? ticketContentCache.peek(ticketId),
              let command = neovimCommand(for: ticket),
              let workingDirectory = neovimWorkingDirectory(for: ticket)
        else {
            return nil
        }

        if let selectedId, selectedId != ticketId {
            _ = neovimSessionCache.session(for: selectedId)
        }

        let result = neovimSessionCache.upsert(
            ticketId: ticketId,
            command: command,
            workingDirectory: workingDirectory
        )
        closeNeovimSessions(result.evicted)
        if prewarm {
            prewarmNeovimSession(result.session)
        }
        return result.session
    }

    private func prewarmNeovimSession(_ session: TicketNeovimSession) {
        guard !UITestSupport.isEnabled,
              let app = GhosttyApp.shared.app
        else {
            return
        }

        _ = TerminalSurfaceRegistry.shared.view(
            for: session.sessionId,
            app: app,
            command: session.command,
            workingDirectory: session.workingDirectory
        )
    }

    private func removeCachedNeovimSession(_ ticketId: String) {
        if let removed = neovimSessionCache.remove(ticketId) {
            closeNeovimSessions([removed])
        }
    }

    private func closeCachedNeovimSessions() {
        closeNeovimSessions(neovimSessionCache.removeAll())
    }

    private func closeNeovimSessions(_ sessions: [TicketNeovimSession]) {
        for session in sessions {
            TerminalSurfaceRegistry.shared.deregister(sessionId: session.sessionId)
        }
    }
}

struct TicketContentLRUCache {
    private(set) var capacity: Int
    private var ticketsById: [String: Ticket] = [:]
    private var recentIds: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var idsMostRecentFirst: [String] {
        recentIds
    }

    func peek(_ ticketId: String) -> Ticket? {
        ticketsById[ticketId]
    }

    mutating func ticket(for ticketId: String) -> Ticket? {
        guard let ticket = ticketsById[ticketId] else { return nil }
        touch(ticketId)
        return ticket
    }

    mutating func store(_ ticket: Ticket) {
        ticketsById[ticket.id] = ticket
        touch(ticket.id)
        evictOverflow()
    }

    @discardableResult
    mutating func remove(_ ticketId: String) -> Ticket? {
        recentIds.removeAll { $0 == ticketId }
        return ticketsById.removeValue(forKey: ticketId)
    }

    private mutating func touch(_ ticketId: String) {
        recentIds.removeAll { $0 == ticketId }
        recentIds.insert(ticketId, at: 0)
    }

    private mutating func evictOverflow() {
        while recentIds.count > capacity {
            let evictedId = recentIds.removeLast()
            ticketsById.removeValue(forKey: evictedId)
        }
    }
}

struct TicketNeovimSession: Hashable {
    let ticketId: String
    let sessionId: String
    let command: String
    let workingDirectory: String
}

struct TicketNeovimSessionLRUCache {
    struct UpsertResult {
        let session: TicketNeovimSession
        let evicted: [TicketNeovimSession]
    }

    private(set) var capacity: Int
    private var sessionsByTicketId: [String: TicketNeovimSession] = [:]
    private var recentTicketIds: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var ticketIdsMostRecentFirst: [String] {
        recentTicketIds
    }

    func peek(_ ticketId: String) -> TicketNeovimSession? {
        sessionsByTicketId[ticketId]
    }

    mutating func session(for ticketId: String) -> TicketNeovimSession? {
        guard let session = sessionsByTicketId[ticketId] else { return nil }
        touch(ticketId)
        return session
    }

    mutating func upsert(ticketId: String, command: String, workingDirectory: String) -> UpsertResult {
        var evicted: [TicketNeovimSession] = []
        let session = TicketNeovimSession(
            ticketId: ticketId,
            sessionId: Self.sessionId(ticketId: ticketId, command: command, workingDirectory: workingDirectory),
            command: command,
            workingDirectory: workingDirectory
        )

        if let existing = sessionsByTicketId[ticketId], existing.sessionId != session.sessionId {
            evicted.append(existing)
        }

        sessionsByTicketId[ticketId] = session
        touch(ticketId)
        evicted.append(contentsOf: evictOverflow())
        return UpsertResult(session: session, evicted: evicted)
    }

    @discardableResult
    mutating func remove(_ ticketId: String) -> TicketNeovimSession? {
        recentTicketIds.removeAll { $0 == ticketId }
        return sessionsByTicketId.removeValue(forKey: ticketId)
    }

    mutating func removeAll() -> [TicketNeovimSession] {
        let sessions = recentTicketIds.compactMap { sessionsByTicketId[$0] }
        recentTicketIds.removeAll()
        sessionsByTicketId.removeAll()
        return sessions
    }

    private mutating func touch(_ ticketId: String) {
        recentTicketIds.removeAll { $0 == ticketId }
        recentTicketIds.insert(ticketId, at: 0)
    }

    private mutating func evictOverflow() -> [TicketNeovimSession] {
        var evicted: [TicketNeovimSession] = []
        while recentTicketIds.count > capacity {
            let evictedId = recentTicketIds.removeLast()
            if let session = sessionsByTicketId.removeValue(forKey: evictedId) {
                evicted.append(session)
            }
        }
        return evicted
    }

    private static func sessionId(ticketId: String, command: String, workingDirectory: String) -> String {
        "ticket-nvim-\(stableHash(ticketId))-\(stableHash(command))-\(stableHash(workingDirectory))"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private func ticketSnippet(_ content: String, maxLength: Int) -> String {
    let effectiveMax = max(4, maxLength)
    let lines = content.components(separatedBy: .newlines)
    var inSummary = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "## summary" || lowered == "## description" {
            inSummary = true
            continue
        }
        if inSummary, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
            return truncateSnippet(trimmed, maxLength: effectiveMax)
        }
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") || metadataLine(trimmed) {
            continue
        }
        return truncateSnippet(trimmed, maxLength: effectiveMax)
    }

    return ""
}

private func truncateSnippet(_ text: String, maxLength: Int) -> String {
    guard text.count > maxLength else { return text }
    let clipped = text.prefix(max(1, maxLength - 3))
    return "\(clipped)..."
}

private func metadataLine(_ line: String) -> Bool {
    guard line.hasPrefix("- ") else { return false }
    let rest = line.dropFirst(2)
    guard let separator = rest.firstIndex(of: ":") else { return false }
    let key = rest[..<separator]
    let keyFields = key.split(separator: " ", omittingEmptySubsequences: true)
    return !key.contains(" ") || keyFields.count <= 2
}

private func ticketShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

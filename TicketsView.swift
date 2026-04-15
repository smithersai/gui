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
                                let snippet = ticketSnippet(ticket.content ?? "", maxLength: 92)
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
                VStack(spacing: 0) {
                    HStack {
                        Text(ticket.id)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)

                        if hasUnsavedChanges {
                            Text("Modified")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.warning.opacity(0.14))
                                .cornerRadius(4)
                        }

                        Spacer()

                        if hasUnsavedChanges {
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

                    MarkdownTextEditor(text: $detailContent)
                        .accessibilityIdentifier("tickets.detail.editor")
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

            tickets = loadedTickets

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
        let content = tickets.first(where: { $0.id == ticketId })?.content ?? ""
        detailContent = content
        originalContent = content
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

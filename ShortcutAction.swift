import Foundation

enum ShortcutAction: String, CaseIterable, Identifiable, Hashable {
    case commandPalette
    case commandPaletteCommandMode
    case commandPaletteAskAI
    case newChat
    case newTerminal
    case reopenClosedTab
    case closeCurrentTab
    case nextSidebarTab
    case prevSidebarTab
    case selectWorkspaceByNumber
    case toggleDeveloperDebug

    case toggleSidebar
    case splitRight
    case splitDown
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case toggleSplitZoom
    case nextSurface
    case prevSurface
    case selectSurfaceByNumber
    case renameWorkspace
    case renameSurface
    case jumpToUnread
    case triggerFlash
    case showNotifications
    case toggleFullScreen
    case focusBrowserAddressBar
    case browserBack
    case browserForward
    case browserReload
    case find
    case findNext
    case findPrevious
    case hideFind
    case useSelectionForFind

    // Existing shortcuts from the universal command palette pass. They remain
    // in the table so Settings is the only source of truth for app shortcuts.
    case openBrowser
    case globalSearch
    case refreshCurrentView
    case cancelCurrentOperation
    case showShortcutCheatSheet
    case linearNavigationPrefix
    case tmuxPrefix

    var id: String { rawValue }

    static var dispatchOrder: [ShortcutAction] {
        var ordered = allCases

        // Some defaults intentionally share a key with a narrower app action.
        // Try the contextual action first and let ContentView fall back when it
        // is not available in the current view.
        ordered.move(.splitDown, before: .toggleDeveloperDebug)
        ordered.move(.browserReload, before: .refreshCurrentView)

        return ordered
    }

    var label: String {
        switch self {
        case .commandPalette:
            return String(localized: "shortcut.commandPalette.label", defaultValue: "Open Launcher")
        case .commandPaletteCommandMode:
            return String(localized: "shortcut.commandPaletteCommandMode.label", defaultValue: "Command Palette")
        case .commandPaletteAskAI:
            return String(localized: "shortcut.commandPaletteAskAI.label", defaultValue: "Ask AI")
        case .newChat:
            return String(localized: "shortcut.newChat.label", defaultValue: "New Chat")
        case .newTerminal:
            return String(localized: "shortcut.newTerminal.label", defaultValue: "New Terminal Tab")
        case .reopenClosedTab:
            return String(localized: "shortcut.reopenClosedTab.label", defaultValue: "Reopen Closed Tab")
        case .closeCurrentTab:
            return String(localized: "shortcut.closeCurrentTab.label", defaultValue: "Close Current Tab")
        case .nextSidebarTab:
            return String(localized: "shortcut.nextSidebarTab.label", defaultValue: "Next Sidebar Tab")
        case .prevSidebarTab:
            return String(localized: "shortcut.prevSidebarTab.label", defaultValue: "Previous Sidebar Tab")
        case .selectWorkspaceByNumber:
            return String(localized: "shortcut.selectWorkspaceByNumber.label", defaultValue: "Select Workspace 1…9")
        case .toggleDeveloperDebug:
            return String(localized: "shortcut.toggleDeveloperDebug.label", defaultValue: "Toggle Developer Debug")
        case .toggleSidebar:
            return String(localized: "shortcut.toggleSidebar.label", defaultValue: "Toggle Sidebar")
        case .splitRight:
            return String(localized: "shortcut.splitRight.label", defaultValue: "Split Right")
        case .splitDown:
            return String(localized: "shortcut.splitDown.label", defaultValue: "Split Down")
        case .focusLeft:
            return String(localized: "shortcut.focusLeft.label", defaultValue: "Focus Left")
        case .focusRight:
            return String(localized: "shortcut.focusRight.label", defaultValue: "Focus Right")
        case .focusUp:
            return String(localized: "shortcut.focusUp.label", defaultValue: "Focus Up")
        case .focusDown:
            return String(localized: "shortcut.focusDown.label", defaultValue: "Focus Down")
        case .toggleSplitZoom:
            return String(localized: "shortcut.toggleSplitZoom.label", defaultValue: "Toggle Split Zoom")
        case .nextSurface:
            return String(localized: "shortcut.nextSurface.label", defaultValue: "Next Surface")
        case .prevSurface:
            return String(localized: "shortcut.prevSurface.label", defaultValue: "Previous Surface")
        case .selectSurfaceByNumber:
            return String(localized: "shortcut.selectSurfaceByNumber.label", defaultValue: "Select Surface 1…9")
        case .renameWorkspace:
            return String(localized: "shortcut.renameWorkspace.label", defaultValue: "Rename Workspace")
        case .renameSurface:
            return String(localized: "shortcut.renameSurface.label", defaultValue: "Rename Surface")
        case .jumpToUnread:
            return String(localized: "shortcut.jumpToUnread.label", defaultValue: "Jump to Latest Unread")
        case .triggerFlash:
            return String(localized: "shortcut.triggerFlash.label", defaultValue: "Flash Focused Pane")
        case .showNotifications:
            return String(localized: "shortcut.showNotifications.label", defaultValue: "Show Notifications")
        case .toggleFullScreen:
            return String(localized: "shortcut.toggleFullScreen.label", defaultValue: "Toggle Full Screen")
        case .focusBrowserAddressBar:
            return String(localized: "shortcut.focusBrowserAddressBar.label", defaultValue: "Focus Browser Address Bar")
        case .browserBack:
            return String(localized: "shortcut.browserBack.label", defaultValue: "Browser Back")
        case .browserForward:
            return String(localized: "shortcut.browserForward.label", defaultValue: "Browser Forward")
        case .browserReload:
            return String(localized: "shortcut.browserReload.label", defaultValue: "Browser Reload")
        case .find:
            return String(localized: "shortcut.find.label", defaultValue: "Find")
        case .findNext:
            return String(localized: "shortcut.findNext.label", defaultValue: "Find Next")
        case .findPrevious:
            return String(localized: "shortcut.findPrevious.label", defaultValue: "Find Previous")
        case .hideFind:
            return String(localized: "shortcut.hideFind.label", defaultValue: "Hide Find")
        case .useSelectionForFind:
            return String(localized: "shortcut.useSelectionForFind.label", defaultValue: "Use Selection for Find")
        case .openBrowser:
            return String(localized: "shortcut.openBrowser.label", defaultValue: "Open Browser Surface")
        case .globalSearch:
            return String(localized: "shortcut.globalSearch.label", defaultValue: "Global Search")
        case .refreshCurrentView:
            return String(localized: "shortcut.refreshCurrentView.label", defaultValue: "Refresh Current View")
        case .cancelCurrentOperation:
            return String(localized: "shortcut.cancelCurrentOperation.label", defaultValue: "Cancel Current Operation")
        case .showShortcutCheatSheet:
            return String(localized: "shortcut.showShortcutCheatSheet.label", defaultValue: "Shortcut Cheat Sheet")
        case .linearNavigationPrefix:
            return String(localized: "shortcut.linearNavigationPrefix.label", defaultValue: "Navigation Chord Prefix")
        case .tmuxPrefix:
            return String(localized: "shortcut.tmuxPrefix.label", defaultValue: "Tmux-Style Chord Prefix")
        }
    }

    var defaultsKey: String {
        "shortcut.\(rawValue)"
    }

    var defaultShortcut: StoredShortcut {
        switch self {
        case .commandPalette:
            return StoredShortcut(key: "p", command: true)
        case .commandPaletteCommandMode:
            return StoredShortcut(key: "p", command: true, shift: true)
        case .commandPaletteAskAI:
            return StoredShortcut(key: "k", command: true)
        case .newChat:
            return StoredShortcut(key: "n", command: true)
        case .newTerminal:
            return StoredShortcut(key: "t", command: true)
        case .reopenClosedTab:
            return StoredShortcut(key: "t", command: true, shift: true)
        case .closeCurrentTab:
            return StoredShortcut(key: "w", command: true)
        case .nextSidebarTab:
            return StoredShortcut(key: "]", command: true, shift: true)
        case .prevSidebarTab:
            return StoredShortcut(key: "[", command: true, shift: true)
        case .selectWorkspaceByNumber:
            return StoredShortcut(key: "1", command: true)
        case .toggleDeveloperDebug:
            return StoredShortcut(key: "d", command: true, shift: true)
        case .toggleSidebar:
            return StoredShortcut(key: "b", command: true)
        case .splitRight:
            return StoredShortcut(key: "d", command: true)
        case .splitDown:
            return StoredShortcut(key: "d", command: true, shift: true)
        case .focusLeft:
            return StoredShortcut(key: "←", command: true, option: true)
        case .focusRight:
            return StoredShortcut(key: "→", command: true, option: true)
        case .focusUp:
            return StoredShortcut(key: "↑", command: true, option: true)
        case .focusDown:
            return StoredShortcut(key: "↓", command: true, option: true)
        case .toggleSplitZoom:
            return StoredShortcut(key: "\r", command: true, shift: true)
        case .nextSurface:
            return StoredShortcut(key: "\t", control: true)
        case .prevSurface:
            return StoredShortcut(key: "\t", shift: true, control: true)
        case .selectSurfaceByNumber:
            return StoredShortcut(key: "1", control: true)
        case .renameWorkspace:
            return StoredShortcut(key: "r", command: true, shift: true)
        case .renameSurface:
            return StoredShortcut(key: "r", command: true, option: true)
        case .jumpToUnread:
            return StoredShortcut(key: "u", command: true, shift: true)
        case .triggerFlash:
            return StoredShortcut(key: "h", command: true, shift: true)
        case .showNotifications:
            return StoredShortcut(key: "i", command: true)
        case .toggleFullScreen:
            return StoredShortcut(key: "f", command: true, control: true)
        case .focusBrowserAddressBar:
            return StoredShortcut(key: "l", command: true)
        case .browserBack:
            return StoredShortcut(key: "[", command: true)
        case .browserForward:
            return StoredShortcut(key: "]", command: true)
        case .browserReload:
            return StoredShortcut(key: "r", command: true)
        case .find:
            return StoredShortcut(key: "f", command: true)
        case .findNext:
            return StoredShortcut(key: "g", command: true)
        case .findPrevious:
            return StoredShortcut(key: "g", command: true, option: true)
        case .hideFind:
            return StoredShortcut(key: "f", command: true, option: true)
        case .useSelectionForFind:
            return StoredShortcut(key: "e", command: true)
        case .openBrowser:
            return StoredShortcut(key: "l", command: true, shift: true)
        case .globalSearch:
            return StoredShortcut(key: "f", command: true, shift: true)
        case .refreshCurrentView:
            return StoredShortcut(key: "r", command: true)
        case .cancelCurrentOperation:
            return StoredShortcut(key: ".", command: true)
        case .showShortcutCheatSheet:
            return StoredShortcut(key: "/", command: true)
        case .linearNavigationPrefix:
            return StoredShortcut(key: "g")
        case .tmuxPrefix:
            return StoredShortcut(key: "b", control: true)
        }
    }

    var isNumbered: Bool {
        switch self {
        case .selectWorkspaceByNumber, .selectSurfaceByNumber:
            return true
        default:
            return false
        }
    }

    var isPrefixOnly: Bool {
        switch self {
        case .linearNavigationPrefix, .tmuxPrefix:
            return true
        default:
            return false
        }
    }

    func displayedShortcutString(for shortcut: StoredShortcut) -> String {
        isNumbered ? shortcut.numberedDisplayString : shortcut.displayString
    }

    func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
        guard isNumbered else { return shortcut }
        let digitSource = shortcut.secondStroke ?? shortcut.firstStroke
        guard let digit = Int(digitSource.key), (1...9).contains(digit) else {
            return nil
        }

        var normalized = shortcut
        if shortcut.hasChord {
            normalized.chordKey = "1"
        } else {
            normalized.key = "1"
        }
        return normalized
    }
}

private extension Array where Element == ShortcutAction {
    mutating func move(_ action: ShortcutAction, before target: ShortcutAction) {
        guard let sourceIndex = firstIndex(of: action),
              let targetIndex = firstIndex(of: target),
              sourceIndex > targetIndex
        else {
            return
        }

        let value = remove(at: sourceIndex)
        insert(value, at: targetIndex)
    }
}

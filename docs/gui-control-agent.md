# Smithers GUI Control Agent

## Goal

Smithers GUI should be controllable by a Smithers-run agent that can solve product and development problems end to end. The agent must be able to inspect the current app, decide what to do, and act through the same surfaces a user can use: navigation, buttons, chat, terminals, browsers, workflow runs, approvals, and external agent harnesses.

The app should keep the controlling conversation visible while the agent works. The UI pattern is a thin right-side rail that expands into a chat sidebar. The rail stays present across all app routes. When expanded, it shows the control-agent chat without replacing the current screen.

## Mental Model

There are three different agent paths in the app:

1. Built-in Smithers chat target
   - Lives inside the GUI chat route.
   - Uses `AgentService` and the embedded Codex FFI bridge.
   - Good for normal chat, but it is not the full app-control agent by itself.

2. External agent harnesses
   - Discovered by `SmithersClient.listAgents()`.
   - Launched as terminal/tmux sessions.
   - Examples: Claude Code, Codex, Gemini, Amp, Forge.

3. Smithers workflow agents
   - Run under Smithers orchestration.
   - Can be observed through `smithers chat`, event streams, SQL, timelines, and run inspect.
   - Can be hijacked into a resumable external harness when supported.

The GUI control agent should sit above these paths. It can choose the right tool for a task: use app controls directly, inspect terminal panes through tmux, launch Codex or another harness for implementation, run Smithers workflows for longer jobs, approve/deny gates, or use screenshots when structured state is insufficient.

## Requirements

- The control chat must remain visible while the app changes screens.
- The agent must be able to see the app:
  - structured app state for fast reasoning,
  - terminal pane text through tmux,
  - browser state through the web view registry,
  - Smithers/JJHub state through CLIs or `SmithersClient`,
  - screenshot fallback for visual ambiguity.
- The agent must be able to control the app:
  - navigate to any route,
  - activate buttons and commands,
  - type into chat/composer fields,
  - launch terminal tabs and external harnesses,
  - send text to tmux panes,
  - run Smithers workflows/prompts,
  - inspect and act on approvals,
  - open browser surfaces and navigate URLs.
- The control layer should prefer typed app actions over coordinate clicks. Coordinate clicks are a fallback when a screenshot is the only viable route.
- The agent should have a clear operating goal: solve the user's problem using the strongest available tool, not merely answer questions.

## Agent Goal Prompt

Use this as the baseline goal for the Smithers GUI control agent:

```text
You are the Smithers GUI control agent. Your job is to solve the user's problem end to end.

You can inspect and control the Smithers GUI. Prefer structured tools when available: app state snapshots, route navigation, Smithers and JJHub CLIs, tmux pane capture, terminal input, workflow launch, approvals, and run inspection. Use screenshots when the structured state is incomplete or when visual confirmation matters.

You may launch specialized agent harnesses such as Codex, Claude Code, Gemini, Amp, or Forge when they are the right tool for implementation, review, research, or validation. You may run Smithers workflows for durable multi-step automation. Keep the user informed through the visible right-side control chat.

Act like an operator, not a passive assistant. Build a plan, execute it, inspect results, recover from errors, and continue until the user's goal is handled or a real blocker is reached.
```

## App Bridge

Add a first-class `GUIControlBridge` inside the macOS app. It should expose two groups of capabilities: observation and action.

Observation tools:

- `app.snapshot`
  - current route,
  - selected chat/session/run/terminal,
  - visible right sidebar state,
  - open sessions,
  - open terminal tabs,
  - terminal workspace layout,
  - browser surfaces,
  - pending approvals,
  - active runs.
- `app.screenshot`
  - returns a PNG for the main window or active content area.
- `terminal.capture`
  - captures a tmux pane by surface id.
- `browser.snapshot`
  - reports URL/title/loading state and optional DOM summary for a browser surface.
- `smithers.inspect`
  - wraps Smithers client/CLI state for runs, approvals, workflows, prompts, memory, SQL.
- `jjhub.inspect`
  - wraps JJHub state for issues, landings, changes, workflows, workspaces.

Action tools:

- `app.navigate(route)`
- `app.activate(accessibilityId)`
- `app.click(x, y)`
- `app.type(text)`
- `app.key(key, modifiers)`
- `chat.send(sessionId, text)`
- `terminal.open(command, cwd, title)`
- `terminal.send(surfaceId, text, enter)`
- `browser.open(url)`
- `workflow.run(path, inputs)`
- `prompt.run(promptId, inputs)`
- `approval.approve(runId, nodeId, iteration, note)`
- `approval.deny(runId, nodeId, iteration, note)`
- `agent.launch(agentId, cwd)`
- `agent.hijack(runId)`

Typed actions should be implemented with app state and existing services first. Accessibility-based activation and coordinate clicking should only be needed for generic fallback behavior.

## Existing Attachment Points

- Persistent route shell: `ContentView` already owns the main `NavigationSplitView` and a trailing developer debug panel. Add the control rail/sidebar here so it survives route changes.
- App chat path: `ChatView`, `SessionStore`, and `AgentService` own built-in GUI chat.
- Agent discovery: `SmithersClient.listAgents()` owns external harness detection.
- Terminal control:
  - `SessionStore.addTerminalTab(...)` launches terminal workspaces.
  - `TerminalWorkspace` stores surfaces and layout.
  - `TmuxController.capturePane(...)` reads terminal contents.
  - `TmuxController.sendText(...)` sends input.
- Browser control:
  - `BrowserSurfaceRegistry` owns `WKWebView` instances by surface id.
  - `TerminalWorkspace` tracks browser surface URL/title.
- Smithers run chat:
  - `LiveRunView` streams run chat and supports hijack.
  - `SmithersClient.hijackRun(...)` decodes resumable launch details.
- Navigation:
  - `NavDestination` already models app routes and terminal command launches.
- UI selectors:
  - Most views already have `accessibilityIdentifier(...)` values. These should become the stable selector vocabulary for fallback activation.

## Right Sidebar UX

Collapsed state:

- 24-32 px trailing rail.
- Cursor-like handle.
- Shows unread/running state.
- Never hides the active app content completely.

Expanded state:

- 320-420 px sidebar.
- Header with current agent/run status.
- Scrollable chat transcript.
- Composer for direct user instructions.
- Compact controls for pause/stop, snapshot, screenshot, and handoff.

The chat is an operator log. It should show what the control agent is doing, including tool calls, terminal launches, workflows started, approvals requested, and blockers.

## Control Strategy

The agent should choose tools in this order:

1. Use structured app state and typed actions.
2. Use Smithers/JJHub CLIs or client methods.
3. Use tmux capture/send for terminal panes.
4. Use browser registry/DOM state for web surfaces.
5. Use screenshot plus coordinate or accessibility fallback.
6. Launch a specialized harness or workflow when the task needs implementation, research, validation, or durable execution.

This keeps the agent fast and reliable while preserving true visual control when it needs it.

## Implementation Phases

1. Sidebar shell
   - Add the persistent right rail/sidebar to `ContentView`.
   - Keep it visible across all routes.
   - Add a local transcript/composer for control-agent messages.

2. Observation bridge
   - Add structured app snapshot models.
   - Include route, sessions, terminal workspaces, browser surfaces, active runs, and approvals.
   - Add terminal capture by tmux surface id.
   - Add screenshot capture for the main window.

3. Typed action bridge
   - Add navigation, chat send, terminal open, terminal send, browser open, workflow run, prompt run, approval approve/deny, and agent launch actions.

4. Smithers agent connection
   - Start a Smithers workflow/run for the control agent.
   - Stream its chat into the sidebar.
   - Feed bridge tool results back to the run.
   - Support cancellation and hijack.

5. Fallback visual control
   - Add screenshot-based click/type/key actions.
   - Require explicit permission or a visible safety affordance before broad coordinate control.

6. Hardening
   - Add selector coverage tests for important buttons.
   - Add tmux capture/send tests.
   - Add snapshot schema tests.
   - Add UI tests proving the sidebar remains visible while navigating and launching terminals.

## Safety Boundaries

- Keep destructive actions explicit: approve/deny, land, delete, revert, cancel, and shell commands with broad effects should be visible in the sidebar transcript.
- Prefer app-owned typed actions over raw GUI automation.
- Coordinate clicks should include the screenshot context that justified them.
- The control agent should never hide its own transcript while it is acting.


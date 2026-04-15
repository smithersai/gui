# Smithers GUI — Agent Instructions

You are working inside the Smithers GUI macOS app repository. This app provides a native interface for the Smithers workflow orchestrator and JJHub code collaboration platform.

## Smithers CLI

The `smithers` CLI (package: `smithers-orchestrator`) manages durable AI workflow execution.

### Quick Reference

```
smithers up         Start a workflow execution (-d for background)
smithers ps         List active, paused, and recently completed runs
smithers logs       Tail the event log of a run
smithers inspect    Show detailed run state: steps, agents, approvals, outputs
smithers chat       Show agent chat output for a run
smithers approve    Approve a paused approval gate
smithers deny       Deny a paused approval gate
smithers cancel     Halt agents and terminate a run
smithers hijack     Hand off a resumable agent session
smithers revert     Revert workspace to a previous task attempt's state
smithers graph      Render the workflow graph without executing
smithers node       Show enriched node details for debugging
smithers memory     View cross-run memory facts and semantic recall
smithers scores     View scorer results for a run
smithers timeline   View execution timeline and forks
smithers diff       Compare two snapshots (time travel diff)
smithers fork       Branch a run from a snapshot checkpoint
smithers replay     Fork from checkpoint and resume execution
smithers cron       Manage background schedule triggers
smithers events     Query run event history
smithers workflow   Discover local workflows from .smithers/workflows
smithers why        Explain why a run is blocked or paused
smithers tui        Open the interactive dashboard
smithers down       Cancel all active runs
```

### Global Options

- `--format <toon|json|yaml|md|jsonl>` — output format
- `--filter-output <keys>` — filter by key paths
- `--verbose` — full output envelope
- `--llms` / `--llms-full` — print LLM-readable manifest

### Smithers Framework

Smithers is a Bun/TypeScript framework for building resumable AI workflows as JSX trees.

- Package: `smithers-orchestrator` (requires Bun >= 1.3)
- Primary API: `createSmithers(...)` with Zod schemas
- Persistence: SQLite
- Core components: `<Workflow>`, `<Task>`, `<Sequence>`, `<Parallel>`, `<Branch>`, `<Loop>`, `<Approval>`, `<MergeQueue>`, `<Worktree>`
- Docs: https://smithers.sh

## JJHub CLI

The `jjhub` CLI manages JJHub — a jj-native code collaboration platform.

### Quick Reference

```
jjhub auth          Manage authentication (login, logout, token)
jjhub repo          Manage repositories
jjhub issue         Manage issues
jjhub land          Manage landing requests
jjhub change        View changes
jjhub bookmark      Manage bookmarks (branches)
jjhub run           View and manage workflow runs
jjhub workflow      Manage workflows
jjhub workspace     Manage cloud workspaces
jjhub agent         Manage AI agent workflows
jjhub search        Search repos, issues, and code
jjhub admin         Administrative commands
jjhub org           Manage organizations
jjhub label         Manage labels
jjhub secret        Manage secrets
jjhub variable      Manage variables
jjhub webhook       Manage webhooks
jjhub notification  Manage notifications
jjhub status        Show working copy status
```

### Global Options

- `--json[=<fields>]` — JSON output (optionally projected)
- `--toon[=<fields>]` — TOON format output
- `--no-color` — disable color

Use `jjhub <command> --help` for detailed subcommand usage.

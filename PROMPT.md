# Smithers Workflow: Parallel Ticket Processing

Build me a Smithers workflow that processes tickets in parallel waves with a review loop.

_Read first_ - [Complete smithers docs](https://smithers.sh/llms-full.txt)

## Pipeline

1. **Triage** — agent reads all tickets, builds a dependency graph, and groups them into waves that can run in parallel.
2. **Wave execution** — for each wave, process every ticket concurrently:
   - Each ticket gets its own worktree + branch
   - **Implement** the ticket
   - Enter a **review & refinement loop** until the reviewer says _"looks good to me"_
3. **Merge** — after each wave, an agent merges every branch back into `main` one-by-one before the next wave starts.

## Review Loop Rules

- **Implementer cannot read docs or browse.** If it needs information, it _requests_ docs.
- **Researcher** fulfills those requests and writes the docs into the workspace `wiki/` folder.
- **Reviewer** can research freely — docs, references, anything that improves the review.
- Loop only exits on explicit reviewer approval.

## Agent Assignments

Use my Claude and Codex subscriptions.

| Role        | Model              |
| ----------- | ------------------ |
| Triage      | Claude Opus        |
| Implementer | Claude Sonnet      |
| Researcher  | Claude Haiku       |
| Reviewer    | GPT-5.5 Extra High |

---

Also: set up a **Claude Code cron job** that periodically checks this workflow is running healthy. If something's wrong, use the `say` command to tell me what the problem is. If everything's fine, stay silent.

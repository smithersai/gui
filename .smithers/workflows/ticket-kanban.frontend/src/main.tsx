import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type TicketBoardStatus = "todo" | "in-progress" | "in-review" | "needs-attention" | "done";

type TicketCard = {
  id: string;
  slug: string;
  title: string;
  summary: string;
  filePath: string;
  status: TicketBoardStatus;
  branch: string;
  stepStates: {
    implement: string;
    validate: string;
    reviews: string[];
    result: string;
  };
  detail: string;
};

type BoardPayload = {
  workflow: {
    id: string;
    name: string;
    framework: string;
  };
  selectedRun: {
    runId: string;
    status: string;
    started: string | null;
    elapsed: string | null;
  } | null;
  recentRuns: Array<{
    runId: string;
    status: string;
    started: string | null;
    selected: boolean;
  }>;
  columns: Array<{
    id: TicketBoardStatus;
    label: string;
    count: number;
  }>;
  tickets: TicketCard[];
  generatedAt: string;
};

const ACTIVE_STATUSES = new Set(["running", "waiting-approval", "waiting-event", "waiting-timer", "stale"]);

function App() {
  const [board, setBoard] = useState<BoardPayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [launching, setLaunching] = useState(false);
  const [cancelling, setCancelling] = useState(false);

  useEffect(() => {
    void loadBoard();
  }, []);

  useEffect(() => {
    const selectedRun = board?.selectedRun;
    if (!selectedRun || !ACTIVE_STATUSES.has(selectedRun.status)) {
      return;
    }

    const timer = window.setInterval(() => {
      void loadBoard(selectedRun.runId, false);
    }, 3000);

    return () => window.clearInterval(timer);
  }, [board?.selectedRun?.runId, board?.selectedRun?.status]);

  async function loadBoard(runId?: string, showSpinner = true) {
    if (showSpinner) {
      setLoading(true);
    }
    setError(null);

    try {
      const url = runId ? `/api/board?runId=${encodeURIComponent(runId)}` : "/api/board";
      const response = await fetch(url, { cache: "no-store" });
      if (!response.ok) {
        throw new Error(`Board request failed with ${response.status}`);
      }
      const payload = await response.json() as BoardPayload;
      setBoard(payload);
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught);
      setError(message);
    } finally {
      if (showSpinner) {
        setLoading(false);
      }
    }
  }

  async function launchRun() {
    setLaunching(true);
    setError(null);

    try {
      const response = await fetch("/api/run", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({}),
      });
      if (!response.ok) {
        throw new Error(`Launch failed with ${response.status}`);
      }
      const result = await response.json() as { runId?: string };
      await loadBoard(result.runId);
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught);
      setError(message);
    } finally {
      setLaunching(false);
    }
  }

  async function cancelRun(runId: string) {
    setCancelling(true);
    setError(null);

    try {
      const response = await fetch(`/api/runs/${encodeURIComponent(runId)}/cancel`, {
        method: "POST",
      });
      if (!response.ok) {
        throw new Error(`Cancel failed with ${response.status}`);
      }
      await loadBoard(runId, false);
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught);
      setError(message);
    } finally {
      setCancelling(false);
    }
  }

  if (loading && !board) {
    return (
      <main className="shell loading-shell">
        <section className="loading-card">
          <div className="loading-line" />
          <p>Loading Ticket Kanban...</p>
        </section>
      </main>
    );
  }

  if (!board) {
    return (
      <main className="shell loading-shell">
        <section className="loading-card">
          <p>{error ?? "Unable to load the board."}</p>
          <button className="outline-button" onClick={() => void loadBoard()}>
            Retry
          </button>
        </section>
      </main>
    );
  }

  const selectedRun = board.selectedRun;

  return (
    <main className="shell">
      <div className="background-grid" />
      <header className="hero">
        <div className="hero-copy">
          <p className="eyebrow">Workflow Frontend POC</p>
          <h1>{board.workflow.name}</h1>
          <p className="hero-text">
            This React app is defined next to the workflow and served over HTTP.
            The macOS app only embeds it.
          </p>
        </div>

        <div className="hero-actions">
          <button
            className="primary-button"
            disabled={launching}
            onClick={() => void launchRun()}
          >
            {launching ? "Launching..." : "Run Kanban"}
          </button>
          <button
            className="outline-button"
            onClick={() => void loadBoard(selectedRun?.runId)}
          >
            Refresh
          </button>
          {selectedRun && ACTIVE_STATUSES.has(selectedRun.status) ? (
            <button
              className="danger-button"
              disabled={cancelling}
              onClick={() => void cancelRun(selectedRun.runId)}
            >
              {cancelling ? "Cancelling..." : "Cancel Run"}
            </button>
          ) : null}
        </div>
      </header>

      <section className="run-strip">
        <div className="run-strip-header">
          <div>
            <p className="section-label">Recent Runs</p>
            <p className="section-caption">
              Select a run to project its workflow state onto the board.
            </p>
          </div>
          <p className="timestamp">
            Updated {new Date(board.generatedAt).toLocaleTimeString()}
          </p>
        </div>

        <div className="run-pills">
          {board.recentRuns.length === 0 ? (
            <div className="empty-pill">No runs yet.</div>
          ) : (
            board.recentRuns.map((run) => (
              <button
                key={run.runId}
                className={`run-pill ${run.selected ? "selected" : ""}`}
                onClick={() => void loadBoard(run.runId)}
              >
                <span className={`status-dot status-${run.status}`} />
                <span className="run-pill-id">{shortId(run.runId)}</span>
                <span className="run-pill-status">{run.status}</span>
                {run.started ? <span className="run-pill-started">{run.started}</span> : null}
              </button>
            ))
          )}
        </div>
      </section>

      {error ? <section className="error-banner">{error}</section> : null}

      <section className="metrics-row">
        {board.columns.map((column) => (
          <article key={column.id} className={`metric-card metric-${column.id}`}>
            <p>{column.label}</p>
            <strong>{column.count}</strong>
          </article>
        ))}
        <article className="metric-card metric-run">
          <p>Selected Run</p>
          <strong>{selectedRun ? shortId(selectedRun.runId) : "None"}</strong>
          <span>{selectedRun ? `${selectedRun.status} ${selectedRun.elapsed ?? ""}`.trim() : "No run selected"}</span>
        </article>
      </section>

      <section className="board">
        {board.columns.map((column) => (
          <BoardColumn
            key={column.id}
            column={column}
            tickets={board.tickets.filter((ticket) => ticket.status === column.id)}
          />
        ))}
      </section>
    </main>
  );
}

function BoardColumn(props: {
  column: BoardPayload["columns"][number];
  tickets: TicketCard[];
}) {
  return (
    <section className={`board-column column-${props.column.id}`}>
      <header className="column-header">
        <div>
          <p className="section-label">{props.column.label}</p>
          <p className="section-caption">{props.column.count} ticket{props.column.count === 1 ? "" : "s"}</p>
        </div>
      </header>

      <div className="column-cards">
        {props.tickets.length === 0 ? (
          <div className="empty-column">Nothing here.</div>
        ) : (
          props.tickets.map((ticket) => <TicketPanel key={ticket.id} ticket={ticket} />)
        )}
      </div>
    </section>
  );
}

function TicketPanel(props: { ticket: TicketCard }) {
  const { ticket } = props;
  return (
    <article className="ticket-card">
      <div className="ticket-card-top">
        <div>
          <p className="ticket-id">{ticket.id.replace(/\.md$/, "")}</p>
          <h2>{ticket.title}</h2>
        </div>
        <span className={`ticket-status ticket-status-${ticket.status}`}>{ticket.status.replace("-", " ")}</span>
      </div>

      <p className="ticket-summary">{ticket.summary}</p>

      <dl className="ticket-meta">
        <div>
          <dt>Branch</dt>
          <dd>{ticket.branch}</dd>
        </div>
        <div>
          <dt>File</dt>
          <dd>{ticket.filePath}</dd>
        </div>
      </dl>

      <div className="badge-row">
        <StateBadge label="Implement" value={ticket.stepStates.implement} />
        <StateBadge label="Validate" value={ticket.stepStates.validate} />
        <StateBadge
          label="Review"
          value={ticket.stepStates.reviews.length > 0 ? ticket.stepStates.reviews.join(", ") : "pending"}
        />
        <StateBadge label="Result" value={ticket.stepStates.result} />
      </div>

      <p className="ticket-detail">{ticket.detail}</p>
    </article>
  );
}

function StateBadge(props: { label: string; value: string }) {
  return (
    <span className={`state-badge state-${props.value.split(",")[0].trim()}`}>
      <strong>{props.label}</strong>
      <span>{props.value}</span>
    </span>
  );
}

function shortId(runId: string): string {
  return runId.replace(/^run-/, "");
}

const container = document.getElementById("root");
if (!container) {
  throw new Error("missing #root");
}

createRoot(container).render(<App />);

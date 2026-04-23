#!/usr/bin/env python3
"""Stand-in for the plue api during local smoke-runs of the E2E harness.

Ticket: ios-e2e-harness. The real E2E target is a live plue stack via
`ios/scripts/run-e2e.sh`. This script exists so a developer can verify
the iOS-side XCUITest wiring without cloning plue or coordinating the
cross-repo docker build — useful when the plue side is temporarily
broken (migration drift, bun.lock drift, etc.).

Responds to:
  GET /api/user/workspaces — returns either an empty list or a single
                             row depending on the `--seeded` flag.
  GET /api/health          — 200 OK.

Not a substitute for the real backend in CI; CI runs against the real
thing.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def handler_factory(seeded: bool, workspace_title: str):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            import sys
            print("[mock-plue]", fmt % args, file=sys.stderr, flush=True)

        def do_GET(self):  # noqa: N802 (BaseHTTPRequestHandler API)
            if self.path == "/api/health":
                self._send_json(200, {"status": "ok"})
                return
            if self.path.startswith("/api/user/workspaces"):
                # Accept any bearer — we assume the test has stamped
                # the right one. Authorization header check:
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "):
                    self._send_json(401, {"error": "missing bearer"})
                    return
                if seeded:
                    self._send_json(200, {
                        "workspaces": [
                            {
                                "workspace_id": "e2e00000-0000-0000-0000-000000000001",
                                "repo_owner": "e2e_user",
                                "repo_name": "e2e-repo",
                                "title": workspace_title,
                                "name": workspace_title,
                                "state": "running",
                                "status": "running",
                                "last_accessed_at": "2026-04-22T12:00:00Z",
                                "last_activity_at": "2026-04-22T12:00:00Z",
                                "created_at": "2026-04-22T10:00:00Z",
                            }
                        ]
                    })
                else:
                    self._send_json(200, {"workspaces": []})
                return
            self._send_json(404, {"error": "not found", "path": self.path})

        def _send_json(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4000)
    parser.add_argument("--seeded", action="store_true",
                        help="return a seeded workspace row instead of empty list")
    parser.add_argument("--workspace-title", default="e2e-workspace")
    args = parser.parse_args()
    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port),
        handler_factory(args.seeded, args.workspace_title),
    )
    print(f"[mock-plue] listening on http://127.0.0.1:{args.port} (seeded={args.seeded})")
    server.serve_forever()


if __name__ == "__main__":
    main()

# 0177 Dependency + License Audit

Audit date: 2026-04-24

Scope covered:

- `gui`: root `Package.swift`, root and Xcode `Package.resolved`, `Shared/Package.swift`, `ghostty/` submodule license, checked-in/browser vendored assets, checked-in/built frameworks visible in the checkout.
- `plue`: root `go.mod` direct dependencies, checked-in vendored/native code, module-vendored C code surfaced by direct Go dependencies, `oss/` folded-in source status.

Generated caches and duplicate worktrees were not counted as product dependencies: `.build/`, `build/`, `node_modules/`, `.smithers/node_modules/`, `.gomodcache/`, `target/`, `.worktrees/`, `.claude/worktrees/`, `.jjconflict-*`.

## Summary

Risk counts across the inventory rows below:

- OK: 44
- Concerning: 1
- Blocker: 1

GPL/AGPL list:

- `gui/vendor/cmux` at `35167aa7f70b0e5314f74ba147312327f87dd8ec`: GPL-3.0-or-later or commercial license. This is a blocker if the source, derived code, or packaged assets ship without a compatible GPL/commercial path.
- `plue` direct dep `github.com/ethereum/go-ethereum v1.14.13`: repository contains GPL-3.0 for `cmd` binaries and LGPL-3.0 for library code. `plue` imports non-`cmd` library packages, so this is tracked as LGPL/GPL-family concern, not an immediate GPL blocker.
- AGPL: none found.

Primary findings:

- Blocker: `gui/vendor/cmux/LICENSE` is GPL-3.0-or-later with a commercial-license alternative. The root `Package.swift` excludes `vendor/`, but the source tree is still vendored into the repo and should not be shipped, copied from, or linked without resolving this.
- Concerning: `plue` imports `github.com/ethereum/go-ethereum` library packages from production auth code. The repo states library code is LGPL-3.0 and command code is GPL-3.0. Go static distribution can make LGPL compliance non-trivial, so legal review or replacement is recommended before distributing proprietary binaries.
- `plue/oss` is a tracked folded-in tree, not a submodule. It carries `oss/LICENSE` as MIT. The `plue` repo itself has no root `LICENSE` file, so product-level licensing should be clarified separately.

## GUI Inventory

| Area | Name + version | License | Use case | Risk | Notes |
| --- | --- | --- | --- | --- | --- |
| SwiftPM | `ViewInspector 0.10.3` | MIT | SwiftUI view testing via `SmithersGUITests` | OK | Pinned in root `Package.resolved` and Xcode workspace resolved file. `Shared/Package.swift` has no external package deps. |
| Submodule | `ghostty` at `158b97607c8404e5f8a0d0589b56b83462aacdce` | MIT | Terminal renderer/backend integration | OK | License present at `ghostty/LICENSE`. Parent repo shows the submodule modified, but the checked-out license is MIT. |
| Vendored framework | `ghostty/macos/GhosttyKit.xcframework` | MIT via Ghostty | Static `libghostty-fat.a` linked by `CGhosttyKit`/macOS target | OK | Binary framework has headers and static archive; license should be included in app notices when shipped. |
| Vendored framework | `ghostty/zig-out/lib/ghostty-vt.xcframework` | MIT via Ghostty | VT parser/static library for Ghostty examples/iOS experiments | OK | Generated/check-in status should be kept intentional, but license is covered by Ghostty MIT. |
| Ghostty SwiftPM/build framework | `Sparkle 2.9.0` | MIT | Auto-update framework in Ghostty macOS build outputs | OK | Pinned in `ghostty/macos/.../Package.resolved`; `Sparkle.framework` only found under Ghostty build outputs. |
| Vendored browser asset | `marked 15.0.12` | MIT | Local Markdown shell rendering | OK | Declared in `Resources/MarkdownShell/vendor/THIRD_PARTY.txt`. |
| Vendored browser asset | `mermaid 11.14.0` | MIT | Local Markdown diagrams | OK | Declared in `Resources/MarkdownShell/vendor/THIRD_PARTY.txt`. |
| Vendored browser asset | `highlight.js 11.11.1` | BSD-3-Clause | Local Markdown code highlighting | OK | Declared in `Resources/MarkdownShell/vendor/THIRD_PARTY.txt`. |
| Vendored source tree | `cmux` at `35167aa7f70b0e5314f74ba147312327f87dd8ec` | GPL-3.0-or-later or commercial | Full vendored macOS terminal/browser app source under `vendor/cmux` | Blocker | `vendor/cmux/THIRD_PARTY_LICENSES.md` lists permissive deps, but the cmux project license itself is GPL/commercial. |

## Plue Go Direct Dependencies

Source: root `/Users/williamcory/plue/go.mod`; direct deps only.

| Name + version | License | Use case | Risk | Notes |
| --- | --- | --- | --- | --- |
| `cloud.google.com/go/storage v1.49.0` | Apache-2.0 | GCS blob storage, snapshots, agent logs | OK | Direct production import. |
| `github.com/GoogleCloudPlatform/opentelemetry-operations-go/exporter/trace v1.24.0` | Apache-2.0 | Google Cloud Trace exporter | OK | Direct observability import. |
| `github.com/coder/websocket v1.8.14` | ISC | Workspace terminal WebSocket routes and PoC tests | OK | Permissive. |
| `github.com/creack/pty v1.1.24` | MIT | PTY allocation for runners/terminal tests | OK | Permissive. |
| `github.com/ethereum/go-ethereum v1.14.13` | LGPL-3.0 library, GPL-3.0 `cmd` binaries | Ethereum key auth/signature handling | Concerning | Production imports are `accounts`, `common`, `hexutil`, `crypto`, outside `cmd`; still needs LGPL compliance review for distributed Go binaries. |
| `github.com/firecracker-microvm/firecracker-go-sdk v1.0.0` | Apache-2.0 | Sandbox VM/jailer management | OK | Includes NOTICE. |
| `github.com/gliderlabs/ssh v0.3.8` | BSD-3-Clause | SSH server/terminal access | OK | Permissive. |
| `github.com/go-chi/chi/v5 v5.2.1` | MIT | HTTP router and middleware | OK | Permissive. |
| `github.com/go-chi/cors v1.2.2` | MIT | CORS middleware | OK | Permissive. |
| `github.com/google/uuid v1.6.0` | BSD-3-Clause | UUID generation | OK | Permissive. |
| `github.com/jackc/pgx/v5 v5.7.4` | MIT | PostgreSQL driver and pgtype support | OK | Permissive. |
| `github.com/mdlayher/vsock v1.2.1` | MIT | Guest-agent vsock transport | OK | Permissive. |
| `github.com/pion/webrtc/v4 v4.2.9` | MIT | WebRTC runner/streaming transport | OK | Permissive. |
| `github.com/pmezard/go-difflib v1.0.0` | BSD-3-Clause | Diff rendering/helpers | OK | Permissive. |
| `github.com/prometheus/client_golang v1.23.2` | Apache-2.0 | Metrics collectors/export | OK | Includes NOTICE. |
| `github.com/prometheus/client_model v0.6.2` | Apache-2.0 | Metrics DTO/test model support | OK | Includes NOTICE. |
| `github.com/prometheus/common v0.66.1` | Apache-2.0 | Prometheus shared helpers | OK | Includes NOTICE. |
| `github.com/robfig/cron/v3 v3.0.1` | MIT | Cron/scheduled workflow support | OK | Permissive. |
| `github.com/sendgrid/sendgrid-go v3.16.1+incompatible` | MIT | Email transport | OK | Permissive. |
| `github.com/sirupsen/logrus v1.8.1` | MIT | Legacy/structured logging support | OK | Permissive. |
| `github.com/spf13/viper v1.20.0` | MIT | Configuration loading | OK | Permissive. |
| `github.com/stretchr/testify v1.11.1` | MIT | Tests/assertions | OK | Test dependency. |
| `github.com/stripe/stripe-go/v83 v83.2.1` | MIT | Billing, checkout, webhooks | OK | Permissive. |
| `github.com/workos/workos-go/v6 v6.5.0` | MIT | WorkOS user/auth management | OK | Permissive. |
| `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.55.0` | Apache-2.0 | HTTP tracing instrumentation | OK | Permissive. |
| `go.opentelemetry.io/otel v1.30.0` | Apache-2.0 | OpenTelemetry API | OK | Permissive. |
| `go.opentelemetry.io/otel/sdk v1.30.0` | Apache-2.0 | OpenTelemetry SDK/export pipeline | OK | Permissive. |
| `go.opentelemetry.io/otel/trace v1.30.0` | Apache-2.0 | Trace API | OK | Permissive. |
| `golang.org/x/crypto v0.48.0` | BSD-3-Clause | SSH and crypto helpers | OK | Permissive. |
| `google.golang.org/api v0.215.0` | BSD-3-Clause | Google API clients | OK | Permissive. |
| `gopkg.in/yaml.v3 v3.0.1` | MIT and Apache-2.0 | YAML config/infra parsing | OK | Dual-license notice present. |

## Plue Vendored / Folded-In Inventory

| Area | Name + version | License | Use case | Risk | Notes |
| --- | --- | --- | --- | --- | --- |
| Checked-in C libs | None found | N/A | N/A | OK | `rg --files` found no checked-in `.c`, `.h`, `.cc`, `.cpp`, `.a`, `.so`, or `.dylib` outside generated/cache dirs. |
| Module-vendored C via direct dep | `go-ethereum crypto/secp256k1/libsecp256k1` | MIT | secp256k1 crypto under go-ethereum | OK | Present inside Go module cache, not checked into `plue`. Package-level `crypto/secp256k1/LICENSE` is BSD-3-Clause. |
| Module-vendored C via transitive dep | `github.com/ethereum/c-kzg-4844 v1.0.0` | Apache-2.0 | Go-ethereum transitive KZG/C bindings | OK | Present in module cache, not checked into `plue`. |
| Folded-in source | `oss/` | MIT | Folded-in JJHub OSS app/packages/docs tree | OK | `oss` is a normal tracked tree, not a submodule. `oss/LICENSE` is MIT; only two tracked files currently modified under `oss/`. |
| Vendored browser asset | `marked 15.0.4` | MIT | `bin/export-html` Markdown export | OK | Header in `bin/export-html/vendor/marked.min.js` declares MIT. |
| Vendored browser asset | `highlight.js 11.9.0` | BSD-3-Clause | `bin/export-html` code highlighting | OK | Header in `bin/export-html/vendor/highlight.min.js` declares BSD-3-Clause. |

## Follow-Up

1. Remove `gui/vendor/cmux`, replace it with a non-GPL source, or document a commercial license before any release packaging.
2. Confirm whether `plue` can replace `go-ethereum` crypto/signature usage with a permissive smaller library. If not, document LGPL-3.0 compliance obligations for distributed binaries.
3. Add or confirm a root product license for `plue`; currently only `oss/LICENSE` exists in the checkout.

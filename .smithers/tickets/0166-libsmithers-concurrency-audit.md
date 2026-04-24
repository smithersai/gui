# 0166 - libsmithers-core concurrency audit

Date: 2026-04-24

Scope audited:

- `libsmithers/src/core/session.zig`
- `libsmithers/src/core/transport.zig`
- `libsmithers/src/core/electric/*`
- `libsmithers/src/core/wspty/*`
- `libsmithers/src/core/cache.zig` as the cache/store implementation
- `libsmithers/src/core/ffi.zig`, `include/smithers.h`, and `Shared/Sources/SmithersRuntime/SmithersRuntime.swift` for cross-language lifetime checks

Note: this checkout does not contain `libsmithers/src/core/stores/` or `libsmithers/src/core/sinks/`. The sink glue is currently embedded in `libsmithers/src/core/transport.zig:1098`.

Severity counts:

- Critical: 2
- High: 7
- Medium: 3
- Low: 0

## Findings

### Critical

#### C-1: `SubscriptionWorker` / `PtyWorker` are published before their thread handles are initialized

Files:

- `libsmithers/src/core/transport.zig:609`
- `libsmithers/src/core/transport.zig:613`
- `libsmithers/src/core/transport.zig:725`
- `libsmithers/src/core/transport.zig:729`
- `libsmithers/src/core/transport.zig:632`
- `libsmithers/src/core/transport.zig:634`
- `libsmithers/src/core/transport.zig:832`
- `libsmithers/src/core/transport.zig:839`

`subscribeImpl` appends the worker to `self.subscriptions` under the transport mutex, unlocks, and only then assigns `worker.thread`. `attachPtyImpl` does the same for `self.pty_workers`. A concurrent `unsubscribe`, `ptyDetach`, or `destroy` can remove that worker, observe `thread == null`, and free it while the creator is still about to write `worker.thread` or while the spawned thread is about to enter with the worker pointer.

Impact: plain data race on `worker.thread` and use-after-free of the worker and its parent pointers during normal disconnect/unsubscribe races.

#### C-2: Swift `RuntimePTY` handles can outlive their owning Zig `Session`

Files:

- `libsmithers/src/core/ffi.zig:240`
- `libsmithers/src/core/ffi.zig:245`
- `libsmithers/src/core/ffi.zig:254`
- `libsmithers/src/core/ffi.zig:264`
- `libsmithers/src/core/ffi.zig:270`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:152`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:163`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:224`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:226`

`smithers_core_attach_pty` returns a boxed `{ session: *Session, handle: u64 }`. Swift `RuntimePTY` stores only that raw box; it does not retain `RuntimeSession`. If the session deinitializes first, `smithers_core_disconnect` frees the Zig session, but later `RuntimePTY.write`, `resize`, or `deinit` calls dereference `h.session`.

Impact: cross-language use-after-free. The same path also leaks/dangles `PtyBox` allocations if the session is disconnected while PTY wrappers remain alive.

### High

#### H-1: PTY write/resize borrow a worker pointer without lifetime protection

Files:

- `libsmithers/src/core/transport.zig:742`
- `libsmithers/src/core/transport.zig:748`
- `libsmithers/src/core/transport.zig:757`
- `libsmithers/src/core/transport.zig:763`
- `libsmithers/src/core/transport.zig:773`
- `libsmithers/src/core/transport.zig:793`
- `libsmithers/src/core/transport.zig:826`
- `libsmithers/src/core/transport.zig:839`

`ptyWriteImpl` and `ptyResizeImpl` find a `PtyWorker` while holding `self.mutex`, then unlock before locking `worker.write_mutex`. A concurrent detach or destroy can remove and free the worker in that gap. The writer then locks or dereferences freed memory.

Impact: use-after-free in a common UI race: terminal write/resize concurrent with detach, session disconnect, or app shutdown.

#### H-2: WebSocket client writes are not fully serialized

Files:

- `libsmithers/src/core/wspty/client.zig:165`
- `libsmithers/src/core/wspty/client.zig:173`
- `libsmithers/src/core/wspty/client.zig:253`
- `libsmithers/src/core/wspty/client.zig:257`
- `libsmithers/src/core/transport.zig:748`
- `libsmithers/src/core/transport.zig:788`

RealTransport serializes host-originated PTY writes/resizes/closes with `PtyWorker.write_mutex`, but `wspty.Client.readEvent` can auto-pong from the reader thread by calling `writeFrame` directly. `writeFrame` mutates `Client.prng` and writes to the same stream, so ping handling races with host writes or shutdown close frames.

Impact: data race inside the `wspty.Client`, corrupted interleaved frames, or stream write failures under ping traffic.

#### H-3: Shutdown and unsubscribe can block indefinitely on uninterruptible I/O

Files:

- `libsmithers/src/core/electric/http.zig:77`
- `libsmithers/src/core/electric/http.zig:85`
- `libsmithers/src/core/electric/http.zig:130`
- `libsmithers/src/core/electric/http.zig:137`
- `libsmithers/src/core/wspty/client.zig:124`
- `libsmithers/src/core/wspty/client.zig:298`
- `libsmithers/src/core/transport.zig:632`
- `libsmithers/src/core/transport.zig:822`
- `libsmithers/src/core/transport.zig:832`
- `libsmithers/src/core/transport.zig:837`
- `libsmithers/src/core/transport.zig:911`
- `libsmithers/src/core/transport.zig:1020`

The cancel flags are checked only around calls to `pollOnce` / `readEvent`; the HTTP client and WebSocket client use blocking connect/read/write loops with no deadline or socket interruption. `destroy`, `unsubscribe`, and `ptyDetach` then join these threads synchronously.

Impact: app shutdown, Swift deinit, unsubscribe, or PTY detach can hang forever on a stalled network peer. The Electric client comment at `libsmithers/src/core/electric/client.zig:10` says in-flight long-polls are interruptible, but the current implementation does not interrupt the socket read.

#### H-4: Credentials callback is concurrently invoked through shared mutable Swift buffers

Files:

- `libsmithers/src/core/core.zig:136`
- `libsmithers/src/core/core.zig:138`
- `libsmithers/src/core/ffi.zig:52`
- `libsmithers/src/core/ffi.zig:59`
- `libsmithers/src/core/session.zig:122`
- `libsmithers/src/core/session.zig:128`
- `libsmithers/src/core/transport.zig:869`
- `libsmithers/src/core/transport.zig:915`
- `libsmithers/src/core/transport.zig:948`
- `libsmithers/src/core/transport.zig:994`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:406`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:422`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:431`
- `include/smithers.h:437`
- `include/smithers.h:450`

Every subscription worker, write worker, and PTY attach can call `Core.fetchCredentials()` concurrently. The Swift trampoline mutates `ProviderBox.bearerCStr` and `refreshCStr` without a lock and returns pointers into those buffers. The header contract says the core copies credentials synchronously inside the callback, but `trampolineCreds` returns borrowed slices and the production duplicate happens later in `coreCredsRefreshTrampoline`.

Impact: concurrent token refreshes can reallocate or overwrite the backing C string while another worker is still reading/copying it, causing invalid reads, token mixups, or auth flapping.

#### H-5: `Cache.wipe` bypasses the cache mutex

Files:

- `libsmithers/src/core/cache.zig:87`
- `libsmithers/src/core/cache.zig:90`
- `libsmithers/src/core/cache.zig:270`
- `libsmithers/src/core/cache.zig:281`
- `libsmithers/src/core/session.zig:358`

Most cache operations lock `Cache.mutex`, but `wipe` calls `exec` directly, and `exec` does not lock. `wipeCache` is exposed through FFI and can run while the background pump is applying shape deltas or UI code is querying the cache.

Impact: concurrent SQLite use on the same connection and inconsistent sign-out semantics; rows may be read or reinserted while the wipe is running.

#### H-6: Write worker tracking is unsafe under allocation failure, and `shutting_down` is unused

Files:

- `libsmithers/src/core/transport.zig:509`
- `libsmithers/src/core/transport.zig:513`
- `libsmithers/src/core/transport.zig:674`
- `libsmithers/src/core/transport.zig:676`
- `libsmithers/src/core/transport.zig:678`
- `libsmithers/src/core/transport.zig:813`
- `libsmithers/src/core/transport.zig:939`
- `libsmithers/src/core/transport.zig:1014`

`writeImpl` spawns the write thread before appending the join handle to `write_threads`. If that append fails, the thread is detached. The comment says `shutting_down` saves the race, but no worker ever loads `shutting_down`. A detached write worker can keep using `self`, `self.allocator`, `self.creds`, and `enqueueDelta` after `destroy` frees the transport.

Impact: use-after-free under memory pressure. Even on the successful path, completed write thread handles are retained until session destroy, so high write volume grows `write_threads` without reaping.

#### H-7: Destroy paths drop worker/session handles on `toOwnedSlice` OOM and continue freeing parents

Files:

- `libsmithers/src/core/transport.zig:817`
- `libsmithers/src/core/transport.zig:819`
- `libsmithers/src/core/transport.zig:844`
- `libsmithers/src/core/transport.zig:857`
- `libsmithers/src/core/core.zig:123`
- `libsmithers/src/core/core.zig:127`
- `libsmithers/src/core/core.zig:131`

`RealTransport.destroyImpl` converts worker arrays to owned slices and catches allocation failure by substituting an empty static slice. If allocation fails, it joins/frees no workers but still deinitializes the arrays and destroys `self`. `Core.destroy` has the same pattern for sessions.

Impact: in low-memory shutdown, live worker threads or sessions can be abandoned while their parent `RealTransport` / `Core` is freed.

### Medium

#### M-1: Delta queues and network buffers have no bounded backpressure

Files:

- `libsmithers/src/core/transport.zig:501`
- `libsmithers/src/core/transport.zig:574`
- `libsmithers/src/core/transport.zig:577`
- `libsmithers/src/core/transport.zig:798`
- `libsmithers/src/core/electric/http.zig:82`
- `libsmithers/src/core/electric/http.zig:88`
- `libsmithers/src/core/electric/http.zig:134`
- `libsmithers/src/core/electric/http.zig:140`
- `libsmithers/src/core/cache.zig:227`
- `libsmithers/src/core/cache.zig:251`
- `libsmithers/src/core/wspty/client.zig:195`
- `libsmithers/src/core/wspty/client.zig:220`
- `libsmithers/src/core/wspty/client.zig:247`

`RealTransport.pending` is an unbounded `ArrayList`; the HTTP client reads full responses into memory; cache queries can return unbounded JSON arrays; and WebSocket fragmentation checks each frame against `max_message_size` but does not cap cumulative `reassembly` growth across many fragments.

Impact: a large Electric snapshot, high-volume PTY output, stalled event pump, or malicious peer can drive unbounded memory growth. OOM paths mostly drop events, which prevents a crash but can silently lose state.

#### M-2: Partial allocation failures leak already-owned slices

Files:

- `libsmithers/src/core/transport.zig:96`
- `libsmithers/src/core/transport.zig:124`
- `libsmithers/src/core/transport.zig:531`
- `libsmithers/src/core/transport.zig:536`
- `libsmithers/src/core/transport.zig:1112`
- `libsmithers/src/core/transport.zig:1142`
- `libsmithers/src/core/session.zig:173`
- `libsmithers/src/core/session.zig:179`
- `libsmithers/src/core/session.zig:307`
- `libsmithers/src/core/session.zig:313`

Several composite initializers perform multiple `dupe` operations without installing `errdefer` for fields already allocated. Examples include `dupDelta`, sink callbacks, `RealTransport.create` config storage, `Session.create` config storage, and `Session.subscribe` appending a subscription after duplicating `shape_name`.

Impact: OOM during setup or drain leaks memory, making pressure worse and increasing the chance of the higher-severity OOM shutdown races.

#### M-3: Public FFI methods lack a closed/refcount gate against concurrent disconnect or core free

Files:

- `libsmithers/src/core/ffi.zig:108`
- `libsmithers/src/core/ffi.zig:144`
- `libsmithers/src/core/ffi.zig:158`
- `libsmithers/src/core/ffi.zig:210`
- `libsmithers/src/core/ffi.zig:274`
- `libsmithers/src/core/ffi.zig:282`
- `libsmithers/src/core/session.zig:256`
- `libsmithers/src/core/session.zig:279`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:107`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:113`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:211`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:224`
- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:317`

The C ABI accepts raw session/core pointers on every call. There is no atomic closed flag, refcount, or operation gate that prevents `smithers_core_disconnect` / `smithers_core_free` from racing with another thread calling subscribe, write, cache query, wipe, tick, or PTY operations. Swift also returns `RuntimeSession` without making the session retain the `SmithersRuntime` that owns its `Core`.

Impact: use-after-free is possible when Swift tasks or callbacks race object deinit with public runtime calls. The PTY-specific case is captured in C-2; this is the broader lifecycle contract issue.

## Ownership summary

- `Session`: intended to be shared by host FFI calls and the background pump. Subscription arrays, PTY attachment arrays, callback pointers, and pending echo state are mostly under `Session.mutex`; the pump is serialized with `tick_mutex`. There is no lifecycle gate once `destroy` begins.
- `RealTransport`: intended to be shared by subscription/write/PTY worker threads plus the session pump. `pending` and worker arrays are mutex-protected, but worker lifetime publication and PTY pointer borrowing are unsafe.
- `electric.Client`: effectively single-thread-owned by one subscription worker, but cancellation does not interrupt blocking network reads.
- `wspty.Client`: shared between the PTY reader thread and host write/resize/close calls. Host writes are partially serialized by `PtyWorker.write_mutex`; reader auto-pong bypasses it.
- `Cache`: intended to serialize SQLite through `Cache.mutex`; `wipe` is the notable exception.

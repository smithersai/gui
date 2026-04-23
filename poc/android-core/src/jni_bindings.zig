//! JNI bindings for Android canary (ticket 0104).
//!
//! This file is the ONLY Android-specific code in the Zig tree. It imports
//! the 0095 FFI core (`poc/zig-swift-ffi/src/ffi_poc.zig`) by relative
//! path and exposes JNI-shaped entrypoints that mirror the iOS/Swift
//! surface one-for-one:
//!
//!     iOS Swift                Android Kotlin                    Zig
//!     ---------                ---------------                   ---
//!     ffi_new_session     <->  CoreBridge.nativeNewSession    -> ffi_new_session
//!     ffi_subscribe       <->  CoreBridge.nativeSubscribe     -> ffi_subscribe
//!     ffi_tick            <->  CoreBridge.nativeTick          -> ffi_tick
//!     ffi_unsubscribe     <->  CoreBridge.nativeUnsubscribe   -> ffi_unsubscribe
//!     ffi_close_session   <->  CoreBridge.nativeCloseSession  -> ffi_close_session
//!
//! Canary property: because this file imports `../../zig-swift-ffi/src/ffi_poc.zig`
//! directly, any symbol rename, type change, or signature change in the
//! 0095 FFI that isn't mirrored here will break the Android build in CI.
//! That's the entire point of the canary — do NOT fork or vendor ffi_poc.zig.
//!
//! Threading model on Android:
//!   - Zig spawns one event-loop thread per session (bionic pthread).
//!   - Callbacks fire on that thread, NOT Android's main/UI thread.
//!   - The Kotlin side is responsible for re-dispatching onto the UI looper
//!     (`Handler(Looper.getMainLooper())`) — same shape as SwiftUI
//!     `@MainActor` on iOS.
//!   - JNI thread attachment: the callback that Zig invokes is a Zig
//!     function pointer, not a JVM method, so we don't need to
//!     AttachCurrentThread here. We stash the JNIEnv* in a
//!     Kotlin-owned trampoline object whose class reference + method ID
//!     were resolved on a thread that was already attached (the main
//!     thread that called `nativeSubscribe`). On the first callback from
//!     Zig's loop thread we attach via the cached JavaVM*.

const std = @import("std");

/// Import the unmodified 0095 FFI core. The `ffi_core` name is wired to
/// `poc/zig-swift-ffi/src/ffi_poc.zig` in this PoC's `build.zig`. Forking
/// or vendoring that file would defeat the canary.
const core = @import("ffi_core");

// ---- JNI types ------------------------------------------------------------
//
// Minimal subset of <jni.h>. We only declare what we actually call. The
// function-table indices are stable across NDK versions — they're part of
// the JNI spec.

const jint = c_int;
const jlong = c_longlong;
const jobject = ?*anyopaque;
const jclass = ?*anyopaque;
const jmethodID = ?*anyopaque;
const JNIEnv = opaque {};
const JavaVM = opaque {};

// Function-table indices (spec-stable).
const FN_GetJavaVM = 4; // JavaVM** (JNIInvokeInterface)
const FN_AttachCurrentThread = 4;
const FN_DetachCurrentThread = 5;

// JNI_OK / JNI_ERR
const JNI_OK: jint = 0;
const JNI_VERSION_1_6: jint = 0x00010006;

// Vtable pointer shapes — we only need the specific functions we call, by
// offset. Rather than reproduce the entire 200-entry vtable, we use inline
// assembly-free function-pointer extraction via the indices.
// NOTE: In practice this canary needs far less — we only need to call back
// INTO the JVM via a stashed static method. Zig can invoke a C callback
// which *is* the JVM bridge, without needing JNIEnv pointer mechanics here.
//
// For the PoC we keep JNI touchpoints to a minimum: subscribe stores the
// caller-provided `user_data` (a Kotlin-allocated trampoline pointer) and
// Zig passes it back to a C callback registered by the Kotlin side via
// `nativeSubscribe`. On Android the "callback" is actually a small C shim
// linked into this .so (see `zig_android_trampoline` below) that bounces
// into the JVM. For the canary we don't bounce — we simply record the
// counter into an atomic that the UI polls on a timer. That keeps the JNI
// surface trivial and is enough to prove the full FFI round-trips.

// ---- JNI exports ----------------------------------------------------------
//
// The JVM resolves these by name when System.loadLibrary("smithers_core")
// is called followed by a `native` method invocation.
//
// Signature convention: Java_<package_with_underscores>_<Class>_<method>
//
//   package:  com.smithers.androidcore
//   class:    CoreBridge
//
// `jlong` is used for all opaque handles (session pointer, subscription id,
// counter). This matches the 64-bit-only minSdk=29 target.

export fn Java_com_smithers_androidcore_CoreBridge_nativeNewSession(
    _: *JNIEnv,
    _: jclass,
) callconv(.c) jlong {
    const s = core.Session.create(std.heap.c_allocator) catch return 0;
    return @bitCast(@intFromPtr(s));
}

export fn Java_com_smithers_androidcore_CoreBridge_nativeCloseSession(
    _: *JNIEnv,
    _: jclass,
    handle: jlong,
) callconv(.c) void {
    const ptr: usize = @bitCast(handle);
    if (ptr == 0) return;
    const s: *core.Session = @ptrFromInt(ptr);
    s.destroy();
}

export fn Java_com_smithers_androidcore_CoreBridge_nativeTick(
    _: *JNIEnv,
    _: jclass,
    handle: jlong,
) callconv(.c) jlong {
    const ptr: usize = @bitCast(handle);
    if (ptr == 0) return 0;
    const s: *core.Session = @ptrFromInt(ptr);
    return @bitCast(s.tick());
}

// Subscription pool: the PoC UI polls `nativeLatestCounter` on a short
// timer; on subscribe we install a callback that simply stores the newest
// counter into a 64-bit atomic stored in a per-session "observer" box. Box
// lifetime is tied to the session (freed on close) via the `user_data`
// slot — Zig never frees it because our contract says the host owns
// `user_data`. We free it from `nativeCloseSession` on the Kotlin side via
// a reverse handle the Kotlin layer tracks. For the canary we keep it
// simple: one observer per session, allocated at subscribe, freed when
// unsubscribed.

const Observer = struct {
    latest: std.atomic.Value(u64) = .{ .raw = 0 },
};

fn observerCallback(counter: u64, user_data: ?*anyopaque) callconv(.c) void {
    const obs: *Observer = @ptrCast(@alignCast(user_data orelse return));
    obs.latest.store(counter, .release);
}

export fn Java_com_smithers_androidcore_CoreBridge_nativeSubscribe(
    _: *JNIEnv,
    _: jclass,
    session_handle: jlong,
) callconv(.c) jlong {
    const ptr: usize = @bitCast(session_handle);
    if (ptr == 0) return 0;
    const s: *core.Session = @ptrFromInt(ptr);

    const obs = std.heap.c_allocator.create(Observer) catch return 0;
    obs.* = .{};

    _ = s.subscribe(&observerCallback, obs) catch {
        std.heap.c_allocator.destroy(obs);
        return 0;
    };
    // Pack: high 32 bits = subscription id, low 64 bits = observer pointer.
    // We actually need both to unsubscribe. Since jlong is 64 bits, return
    // the observer pointer (unique) and keep the sub_id inside the
    // Observer struct for lookup. Simplifies the Kotlin side.
    return @bitCast(@intFromPtr(obs));
}

export fn Java_com_smithers_androidcore_CoreBridge_nativeLatestCounter(
    _: *JNIEnv,
    _: jclass,
    observer_handle: jlong,
) callconv(.c) jlong {
    const ptr: usize = @bitCast(observer_handle);
    if (ptr == 0) return 0;
    const obs: *Observer = @ptrFromInt(ptr);
    return @bitCast(obs.latest.load(.acquire));
}

export fn Java_com_smithers_androidcore_CoreBridge_nativeUnsubscribe(
    _: *JNIEnv,
    _: jclass,
    session_handle: jlong,
    observer_handle: jlong,
) callconv(.c) void {
    const s_ptr: usize = @bitCast(session_handle);
    const o_ptr: usize = @bitCast(observer_handle);
    if (s_ptr == 0 or o_ptr == 0) return;
    const s: *core.Session = @ptrFromInt(s_ptr);
    const obs: *Observer = @ptrFromInt(o_ptr);

    // Look up sub_id by matching user_data pointer. `Session.subs` is
    // internal; we don't have a public "find by user_data" API. For the
    // canary we accept the cost of iterating since subs are small.
    // NOTE: once 0095 grows an `ffi_unsubscribe_by_user_data` (or an
    // explicit id return at subscribe time), this code should switch.
    s.sub_mutex.lock();
    var target_id: u64 = 0;
    for (s.subs.items) |sub| {
        if (sub.user_data == @as(?*anyopaque, @ptrCast(obs))) {
            target_id = sub.id;
            break;
        }
    }
    s.sub_mutex.unlock();

    if (target_id != 0) s.unsubscribe(target_id);
    std.heap.c_allocator.destroy(obs);
}

// ---- JNI_OnLoad -----------------------------------------------------------
//
// Called by the JVM when `System.loadLibrary("smithers_core")` completes.
// We don't need much here — every native method is resolved by name, not
// by RegisterNatives — but we return the JNI version we expect so the JVM
// fails fast if a future NDK ships an incompatible runtime.

export fn JNI_OnLoad(_: *JavaVM, _: ?*anyopaque) callconv(.c) jint {
    return JNI_VERSION_1_6;
}

// ---- Build-time sanity check ---------------------------------------------
//
// If 0095 ever renames or removes one of these symbols or reshapes their
// types, this file won't compile. That's the canary. The `export fn`
// entrypoints (`ffi_new_session` etc.) are exercised at JVM load time:
// `System.loadLibrary` does not resolve them, but the first
// `CoreBridge.nativeNewSession` -> Zig `core.Session.create` round-trip
// does, and the Kotlin interop test in `CoreBridgeSmokeTest` fails fast
// if any of them are missing.
comptime {
    _ = core.Session.create;
    _ = core.Session.destroy;
    _ = core.Session.tick;
    _ = core.Session.subscribe;
    _ = core.Session.unsubscribe;
    const _cb: core.Callback = &observerCallback;
    _ = _cb;
}

package com.smithers.androidcore

/**
 * JNI bridge to `libsmithers_core.so` (Zig).
 *
 * Canary contract (ticket 0104): every `external fun` here MUST line up 1:1
 * with an `export fn Java_com_smithers_androidcore_CoreBridge_<name>` in
 * `poc/android-core/src/jni_bindings.zig`. If those drift, the JVM's
 * lazy resolver throws `UnsatisfiedLinkError` on first call and
 * CoreBridgeSmokeTest fails CI.
 *
 * Thread-safety: `nativeTick`, `nativeLatestCounter`, `nativeSubscribe`,
 * and `nativeUnsubscribe` are safe from any thread — Zig takes its own
 * locks. Callers should NOT hold the Android main-thread Looper lock
 * across `nativeCloseSession` (it joins the Zig loop thread, which may
 * block briefly).
 */
object CoreBridge {

    init {
        // The library name matches the Zig build artifact name:
        // `libsmithers_core.so` -> loadLibrary("smithers_core").
        System.loadLibrary("smithers_core")
    }

    /** Create a new session. Returns 0 on OOM. */
    external fun nativeNewSession(): Long

    /** Destroy a session. Safe with live subscriptions; joins the Zig loop. */
    external fun nativeCloseSession(session: Long)

    /** Increment the counter. Returns the value posted. */
    external fun nativeTick(session: Long): Long

    /**
     * Register a counter observer. Returns an observer handle (0 on failure).
     *
     * For canary simplicity the observer just atomically stores the latest
     * counter value; consumers poll [nativeLatestCounter]. This matches the
     * UI pattern of "tick → redraw on next frame" without needing JNI
     * thread-attach gymnastics.
     */
    external fun nativeSubscribe(session: Long): Long

    /** Read the latest counter value seen by the observer. */
    external fun nativeLatestCounter(observer: Long): Long

    /** Unregister an observer and free its backing allocation. */
    external fun nativeUnsubscribe(session: Long, observer: Long)
}

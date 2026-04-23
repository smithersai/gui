package com.smithers.androidcore

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Canary UI (ticket 0104).
 *
 * One counter display + one "Tick" button. The point is to prove the
 * FFI round-trip works end-to-end: Kotlin button press -> JNI ->
 * Zig `Session.tick()` -> Zig event-loop thread -> observer callback
 * -> Kotlin polls atomic -> TextView update.
 */
class MainActivity : Activity() {

    private var session: Long = 0L
    private var observer: Long = 0L
    private var uiHandler: Handler? = null
    private val poller = Runnable { updateDisplay() }

    private lateinit var counterView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Inflate a minimal view tree in code to avoid an extra XML file.
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 96, 48, 48)
        }

        counterView = TextView(this).apply {
            textSize = 48f
            text = "counter: 0"
        }
        root.addView(counterView)

        val tickButton = Button(this).apply {
            text = "Tick"
            setOnClickListener { onTickPressed() }
        }
        root.addView(tickButton)

        val closeButton = Button(this).apply {
            text = "Close session"
            setOnClickListener { onClosePressed() }
        }
        root.addView(closeButton)

        setContentView(root)

        uiHandler = Handler(Looper.getMainLooper())

        // Establish the session up front so the first Tick press is
        // measuring just the ffi_tick round-trip, not session creation.
        session = CoreBridge.nativeNewSession()
        if (session == 0L) {
            counterView.text = "FFI error: nativeNewSession returned 0"
            return
        }
        observer = CoreBridge.nativeSubscribe(session)
        schedulePoll()
    }

    override fun onDestroy() {
        super.onDestroy()
        uiHandler?.removeCallbacks(poller)
        if (session != 0L) {
            if (observer != 0L) {
                CoreBridge.nativeUnsubscribe(session, observer)
                observer = 0L
            }
            CoreBridge.nativeCloseSession(session)
            session = 0L
        }
    }

    private fun onTickPressed() {
        if (session == 0L) return
        val posted = CoreBridge.nativeTick(session)
        // Best-effort immediate render; the poller will catch up if the
        // loop thread hasn't delivered yet.
        counterView.text = "counter: $posted"
    }

    private fun onClosePressed() {
        if (session == 0L) return
        if (observer != 0L) {
            CoreBridge.nativeUnsubscribe(session, observer)
            observer = 0L
        }
        CoreBridge.nativeCloseSession(session)
        session = 0L
        counterView.text = "session closed"
    }

    private fun updateDisplay() {
        if (observer != 0L) {
            val latest = CoreBridge.nativeLatestCounter(observer)
            counterView.text = "counter: $latest"
        }
        schedulePoll()
    }

    private fun schedulePoll() {
        // 16ms ~= one frame at 60Hz. Cheap and hits the FFI often enough
        // to make any synchronization bug visible in a canary run.
        uiHandler?.postDelayed(poller, 16L)
    }
}

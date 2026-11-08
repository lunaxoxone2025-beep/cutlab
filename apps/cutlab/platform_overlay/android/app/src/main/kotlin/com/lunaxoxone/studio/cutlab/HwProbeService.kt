package com.lunaxoxone.studio.cutlab

import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import java.util.concurrent.Executors

/** JNI entry of the media engine used by [HwProbeService]. */
object HwProbeNative {
    val loaded: Boolean = try {
        System.loadLibrary("cutlab_core")
        true
    } catch (e: Throwable) {
        false
    }

    /** Runs cutlab_hw_self_test on [uri] ("fd:N" or a path); returns JSON. */
    @JvmStatic
    external fun nativeSelfTest(uri: String): String
}

/**
 * Tries the hardware (MediaCodec) decoder on a video in its own process
 * (android:process=":hwprobe"). Phone video decoders are vendor code: if one
 * crashes, only this process ends and the editor keeps running in software
 * decoding. The result is cached per kind of video by MainActivity.
 */
class HwProbeService : Service() {
    companion object {
        const val MSG_TEST = 1
        const val KEY_URI = "uri"
        const val KEY_RESULT = "result"
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { msg ->
        handle(msg)
        true
    })

    override fun onBind(intent: Intent): IBinder = messenger.binder

    private fun handle(msg: Message) {
        if (msg.what != MSG_TEST) return
        val reply = msg.replyTo ?: return
        val uri = msg.data?.getString(KEY_URI) ?: return
        worker.execute {
            val json = try {
                runTest(uri)
            } catch (e: Throwable) {
                "{\"ok\":false,\"error\":" + jsonString(e.toString()) + "}"
            }
            val out = Message.obtain(null, MSG_TEST)
            out.data = Bundle().apply { putString(KEY_RESULT, json) }
            try {
                reply.send(out)
            } catch (e: RemoteException) {
                // The editor went away; nothing to report to.
            }
        }
    }

    private fun runTest(uri: String): String {
        if (!HwProbeNative.loaded) return "{\"ok\":false,\"error\":\"media engine not available\"}"
        val parsed = Uri.parse(uri)
        if (parsed.scheme == "content" || parsed.scheme == "file") {
            val pfd = contentResolver.openFileDescriptor(parsed, "r")
                ?: return "{\"ok\":false,\"error\":\"cannot open the video\"}"
            pfd.use { return HwProbeNative.nativeSelfTest("fd:" + it.fd) }
        }
        return HwProbeNative.nativeSelfTest(uri)
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }
}

/** JSON string literal for [s]. */
fun jsonString(s: String): String {
    val b = StringBuilder("\"")
    for (c in s) {
        when {
            c == '"' -> b.append("\\\"")
            c == '\\' -> b.append("\\\\")
            c == '\n' -> b.append("\\n")
            c < ' ' -> b.append(' ')
            else -> b.append(c)
        }
    }
    return b.append('"').toString()
}

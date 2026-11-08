package com.lunaxoxone.studio.cutlab

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.PowerManager
import android.os.RemoteException
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.ExecutorService

/**
 * Android side of video export (channel "cutlab/media"):
 *  - exportTarget:   a file in the app's own Movies folder to render into
 *  - publishExport:  moves the finished video into the gallery (Movies/CUTLAB)
 *  - openExported:   opens it in a video player
 *  - startBackgroundWork / updateBackgroundWork / stopBackgroundWork:
 *                    the foreground service that keeps the export running
 *  - deviceCondition: temperature status and battery
 *  - checkEncoders:  which hardware encoders work, tested in the ":hwprobe"
 *                    process (a crashing vendor encoder ends only that process)
 */
class ExportSupport(
    private val activity: Activity,
    private val io: ExecutorService,
    private val prefs: SharedPreferences,
    private val appVersion: () -> String,
) {
    private val main = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "exportTarget" -> {
                val name = call.argument<String>("name") ?: "CUTLAB.mp4"
                background(result) {
                    val dir = File(activity.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: activity.filesDir, "exports").apply { mkdirs() }
                    File(dir, name).absolutePath
                }
            }
            "publishExport" -> {
                val path = call.argument<String>("path")!!
                val name = call.argument<String>("name") ?: File(path).name
                val mime = call.argument<String>("mime") ?: "video/mp4"
                background(result) { publish(File(path), name, mime) }
            }
            "openExported" -> {
                val uri = call.argument<String>("uri")!!
                val mime = call.argument<String>("mime") ?: "video/*"
                try {
                    val target = if (uri.startsWith("/")) Uri.fromFile(File(uri)) else Uri.parse(uri)
                    activity.startActivity(
                        Intent(Intent.ACTION_VIEW).setDataAndType(target, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "startBackgroundWork" -> {
                askNotificationPermission()
                try {
                    ExportService.start(activity, call.argument<String>("text") ?: "Exporting video")
                    result.success(true)
                } catch (e: Exception) {
                    // Some devices refuse foreground services in odd states: the export still runs while the app is open.
                    result.success(false)
                }
            }
            "updateBackgroundWork" -> {
                try {
                    ExportService.update(activity, call.argument<String>("text") ?: "", call.argument<Int>("progress") ?: -1)
                } catch (e: Exception) {
                }
                result.success(null)
            }
            "stopBackgroundWork" -> {
                ExportService.stop(activity)
                result.success(null)
            }
            "deviceCondition" -> result.success(deviceCondition())
            "checkEncoders" -> {
                val force = call.argument<Boolean>("force") ?: false
                checkEncoders(force) { json -> result.success(json) }
            }
            else -> return false
        }
        return true
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("cutlab", e.message ?: e.toString(), null) }
            }
        }
    }

    /** Copies the finished file into Movies/CUTLAB (Android 10+) and removes the app's copy. */
    private fun publish(file: File, name: String, mime: String): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 29) {
            // Older Android: shared folders need a storage permission CUTLAB does not ask for.
            return mapOf("uri" to file.absolutePath, "location" to file.absolutePath, "gallery" to false)
        }
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, mime)
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/CUTLAB")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: throw IllegalStateException("the gallery refused the video")
        try {
            resolver.openOutputStream(uri, "w")?.use { out -> FileInputStream(file).use { it.copyTo(out, 1 shl 20) } }
                ?: throw IllegalStateException("cannot write to the gallery")
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        file.delete()
        return mapOf("uri" to uri.toString(), "location" to "Movies/CUTLAB/$name", "gallery" to true)
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7302)
        }
    }

    private fun deviceCondition(): Map<String, Any?> {
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        // 0 none, 1 light, 2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown; -1 unknown.
        val thermal = if (Build.VERSION.SDK_INT >= 29) pm.currentThermalStatus else -1
        val battery = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf(
            "thermal" to thermal,
            "battery" to if (level >= 0 && scale > 0) level * 100 / scale else -1,
            "charging" to charging,
            "powerSave" to pm.isPowerSaveMode,
        )
    }

    /** Encoder list with hardware encoders test-encoded in the ":hwprobe" process; cached per app version. */
    private fun checkEncoders(force: Boolean, done: (String) -> Unit) {
        val key = "${appVersion()}|encoders"
        val cached = prefs.getString(key, null)
        if (cached != null && !force) {
            done(cached)
            return
        }
        var finished = false
        var connection: ServiceConnection? = null
        lateinit var timeout: Runnable
        fun finish(json: String, keep: Boolean) {
            if (finished) return
            finished = true
            main.removeCallbacks(timeout)
            connection?.let { c -> try { activity.unbindService(c) } catch (e: Exception) { } }
            if (keep) prefs.edit().putString(key, json).apply()
            done(json)
        }
        val failed = { why: String -> "{\"error\":" + jsonString(why) + "}" }
        timeout = Runnable { finish(failed("the encoder test did not finish in time"), true) }
        val replies = Messenger(Handler(Looper.getMainLooper()) { msg ->
            finish(msg.data?.getString(HwProbeService.KEY_RESULT) ?: failed("no result"), true)
            true
        })
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (binder == null) {
                    finish(failed("the test process did not start"), false)
                    return
                }
                try {
                    binder.linkToDeath({ main.post { finish(failed("a hardware encoder crashed during its test"), true) } }, 0)
                    val msg = Message.obtain(null, HwProbeService.MSG_ENCODERS)
                    msg.data = Bundle()
                    msg.replyTo = replies
                    Messenger(binder).send(msg)
                } catch (e: RemoteException) {
                    finish(failed("a hardware encoder crashed during its test"), true)
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                finish(failed("a hardware encoder crashed during its test"), true)
            }
        }
        connection = conn
        val bound = try {
            activity.bindService(Intent(activity, HwProbeService::class.java), conn, Context.BIND_AUTO_CREATE)
        } catch (e: Exception) {
            false
        }
        if (!bound) {
            connection = null
            finished = true
            done(failed("the hardware test process is not available"))
            return
        }
        main.postDelayed(timeout, 45000)
    }
}

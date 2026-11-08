package com.lunaxoxone.studio.cutlab

import android.annotation.TargetApi
import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodecList
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.concurrent.Executors

/**
 * Native media access for CUTLAB on Android (channel "cutlab/media").
 *
 * Media is opened through the Storage Access Framework and kept as a
 * persistable content:// URI, so large recordings are never copied.
 */
class MainActivity : FlutterActivity() {
    companion object {
        /** True when the native media engine (FFmpeg) is packaged and loaded. */
        val engineLoaded: Boolean = try {
            // Loading through Java runs JNI_OnLoad, which hands the Java VM to
            // FFmpeg for MediaCodec hardware decoding. Dart then opens the same library.
            System.loadLibrary("cutlab_core")
            true
        } catch (e: Throwable) {
            false
        }
    }

    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val pending = HashMap<Int, (Intent?) -> Unit>()
    private var nextRequest = 7100

    private val hwPrefs by lazy { getSharedPreferences("cutlab_hw", Context.MODE_PRIVATE) }
    private val exportSupport by lazy { ExportSupport(this, io, hwPrefs) { appVersion() } }
    private val diagPrefs by lazy { getSharedPreferences("cutlab_diag", Context.MODE_PRIVATE) }

    /** Crash reports (native, Java) and the Dart error log live here. */
    private fun diagnosticsDir(): File = File(filesDir, "diagnostics").apply { mkdirs() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engineLoaded // force the companion initializer before Dart touches the engine
        installJavaCrashHandler()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cutlab/media").setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("cutlab", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickMedia" -> {
                val multiple = call.argument<Boolean>("multiple") ?: true
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "audio/*", "image/*"))
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
                launch(intent) { data ->
                    val uris = collectUris(data)
                    background(result) {
                        uris.map { uri ->
                            persist(uri)
                            describe(uri)
                        }
                    }
                }
            }
            "pickDocument" -> {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                launch(intent) { data ->
                    val uri = data?.data
                    if (uri == null) {
                        result.success(null)
                    } else {
                        background(result) {
                            val text = contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
                                ?: throw IllegalStateException("cannot read file")
                            mapOf("name" to displayName(uri), "text" to text)
                        }
                    }
                }
            }
            "saveDocument" -> {
                val name = call.argument<String>("name") ?: "project.cutlab"
                val text = call.argument<String>("text") ?: ""
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                launch(intent) { data ->
                    val uri = data?.data
                    if (uri == null) {
                        result.success(false)
                    } else {
                        background(result) {
                            contentResolver.openOutputStream(uri, "wt")?.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                                ?: throw IllegalStateException("cannot write file")
                            true
                        }
                    }
                }
            }
            "exists" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                background(result) {
                    try {
                        contentResolver.openFileDescriptor(uri, "r")?.use { true } ?: false
                    } catch (e: Exception) {
                        false
                    }
                }
            }
            "openFd" -> {
                // A descriptor the native engine reads directly (no copy). The
                // engine duplicates it; Dart closes this one with "closeFd".
                val uri = Uri.parse(call.argument<String>("uri")!!)
                background(result) {
                    contentResolver.openFileDescriptor(uri, "r")?.detachFd() ?: throw IllegalStateException("cannot open $uri")
                }
            }
            "closeFd" -> {
                val fd = call.argument<Int>("fd") ?: -1
                if (fd >= 0) {
                    try { android.os.ParcelFileDescriptor.adoptFd(fd).close() } catch (e: Exception) { }
                }
                result.success(null)
            }
            "deviceInfo" -> background(result) { deviceInfo() }
            "checkHardware" -> {
                val uri = call.argument<String>("uri") ?: ""
                val key = call.argument<String>("key") ?: "unknown"
                checkHardware(uri, key) { ok, detail -> result.success(mapOf("ok" to ok, "detail" to detail)) }
            }
            "resetHardwareChecks" -> {
                hwPrefs.edit().clear().apply()
                result.success(null)
            }
            "thumbnail" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                val kind = call.argument<String>("kind") ?: "video"
                val max = call.argument<Int>("maxSize") ?: 256
                background(result) { thumbnail(uri, kind, max) }
            }
            else -> if (!exportSupport.handle(call, result)) result.notImplemented()
        }
    }

    // ------------------------------------------------------- diagnostics

    private fun installJavaCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is CutlabCrashHandler) return
        Thread.setDefaultUncaughtExceptionHandler(CutlabCrashHandler(diagnosticsDir(), deviceSummary(), previous))
    }

    private fun deviceSummary(): String =
        "${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE}), Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), " +
            "ABIs ${Build.SUPPORTED_ABIS.joinToString()}, ${Runtime.getRuntime().availableProcessors()} CPUs"

    private fun appVersion(): String = try {
        @Suppress("DEPRECATION")
        val info = packageManager.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        "${info.versionName} ($code)"
    } catch (e: Exception) {
        "?"
    }

    private fun deviceInfo(): Map<String, Any?> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mem)
        val m = HashMap<String, Any?>()
        m["platform"] = "android"
        m["summary"] = deviceSummary()
        m["manufacturer"] = Build.MANUFACTURER
        m["model"] = Build.MODEL
        m["device"] = Build.DEVICE
        m["hardware"] = Build.HARDWARE
        if (Build.VERSION.SDK_INT >= 31) m["soc"] = "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
        m["android"] = Build.VERSION.RELEASE
        m["sdk"] = Build.VERSION.SDK_INT
        m["abis"] = Build.SUPPORTED_ABIS.joinToString()
        m["cpus"] = Runtime.getRuntime().availableProcessors()
        m["totalMemMB"] = mem.totalMem / (1024 * 1024)
        m["availMemMB"] = mem.availMem / (1024 * 1024)
        m["lowMemory"] = mem.lowMemory
        m["memoryClassMB"] = am.memoryClass
        m["largeMemoryClassMB"] = am.largeMemoryClass
        m["appVersion"] = appVersion()
        m["diagnosticsDir"] = diagnosticsDir().absolutePath
        m["decoders"] = videoDecoders()
        m["hardwareChecks"] = hwPrefs.all.map { "${it.key}: ${it.value}" }.sorted()
        m["exits"] = exitReports(am)
        return m
    }

    /** Video decoders on this phone: name, type, HW/SW, max size, colour formats. */
    private fun videoDecoders(): List<String> {
        val wanted = setOf("video/avc", "video/hevc", "video/x-vnd.on2.vp9", "video/av01")
        val out = ArrayList<String>()
        try {
            for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
                if (info.isEncoder) continue
                for (type in info.supportedTypes) {
                    if (type !in wanted) continue
                    try {
                        val caps = info.getCapabilitiesForType(type)
                        val vc = caps.videoCapabilities
                        val kind = if (Build.VERSION.SDK_INT >= 29) {
                            if (info.isHardwareAccelerated) "HW" else "SW"
                        } else if (info.name.startsWith("OMX.google.") || info.name.startsWith("c2.android.")) "SW" else "HW?"
                        val colors = caps.colorFormats.joinToString(",") { "0x" + Integer.toHexString(it) }
                        out.add("${info.name} $type $kind max ${vc?.supportedWidths?.upper}x${vc?.supportedHeights?.upper} colors $colors")
                    } catch (e: Exception) {
                        out.add("${info.name} $type (capabilities unavailable: ${e.message})")
                    }
                }
            }
        } catch (e: Exception) {
            out.add("decoder list unavailable: ${e.message}")
        }
        return out
    }

    /**
     * Abnormal ends of CUTLAB recorded by Android (11+): crashes, native
     * crashes, out-of-memory kills, ANRs. Each is reported once; on the first
     * run the last 7 days are included, so a crash from an older version
     * shows up after updating.
     */
    @TargetApi(30)
    private fun exitReports(am: ActivityManager): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < 30) return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        try {
            val since = diagPrefs.getLong("lastExitMs", System.currentTimeMillis() - 7L * 24 * 3600 * 1000)
            var newest = since
            for (e in am.getHistoricalProcessExitReasons(packageName, 0, 16)) {
                if (e.timestamp <= since) continue
                newest = maxOf(newest, e.timestamp)
                val abnormal = when (e.reason) {
                    ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_ANR,
                    ApplicationExitInfo.REASON_INITIALIZATION_FAILURE, ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> true
                    ApplicationExitInfo.REASON_LOW_MEMORY, ApplicationExitInfo.REASON_SIGNALED ->
                        e.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE
                    else -> false
                }
                if (!abnormal) continue
                val m = HashMap<String, Any?>()
                m["timeMs"] = e.timestamp
                m["reason"] = exitReasonName(e.reason)
                m["description"] = e.description
                m["process"] = e.processName
                m["importance"] = e.importance
                m["pssKB"] = e.pss
                m["rssKB"] = e.rss
                m["status"] = e.status
                m["trace"] = traceText(e)
                out.add(m)
            }
            diagPrefs.edit().putLong("lastExitMs", newest).apply()
        } catch (e: Exception) {
            out.add(mapOf("reason" to "unavailable", "description" to e.toString()))
        }
        return out
    }

    @TargetApi(30)
    private fun exitReasonName(r: Int): String = when (r) {
        ApplicationExitInfo.REASON_CRASH -> "Java crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
        ApplicationExitInfo.REASON_ANR -> "not responding (ANR)"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "killed: low memory"
        ApplicationExitInfo.REASON_SIGNALED -> "killed by signal"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "killed: excessive resource use"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
        else -> "reason $r"
    }

    /**
     * Readable text of the system crash record. Native crash records
     * (tombstones) are binary on Android 12+; their readable strings (signal,
     * abort message, libraries, function names) are enough to find the cause.
     */
    @TargetApi(30)
    private fun traceText(e: ApplicationExitInfo): String? {
        return try {
            val bytes = e.traceInputStream?.use { s -> s.readBytes() } ?: return null
            if (e.reason == ApplicationExitInfo.REASON_ANR) return String(bytes, Charsets.UTF_8).take(20000)
            val lines = LinkedHashSet<String>()
            val cur = StringBuilder()
            for (b in bytes) {
                val c = b.toInt() and 0xff
                if (c in 0x20..0x7e) {
                    cur.append(c.toChar())
                } else {
                    if (cur.length >= 5) lines.add(cur.toString())
                    cur.setLength(0)
                }
                if (lines.size >= 400) break
            }
            if (cur.length >= 5) lines.add(cur.toString())
            lines.joinToString("\n").take(30000)
        } catch (t: Throwable) {
            "trace unavailable: $t"
        }
    }

    // ------------------------------------------- hardware decoding checks

    /**
     * Whether MediaCodec decoding works for this kind of video ([key]): asks
     * the cache, else decodes [uri] in the ":hwprobe" process. A crash or a
     * hang there means "use software decoding".
     */
    private fun checkHardware(uri: String, key: String, done: (Boolean, String) -> Unit) {
        val prefKey = "${appVersion()}|$key"
        val cached = hwPrefs.getString(prefKey, null)
        if (cached != null) {
            done(cached.startsWith("ok"), cached.substringAfter(':').trim())
            return
        }
        var finished = false
        var connection: ServiceConnection? = null
        lateinit var timeout: Runnable
        fun finish(ok: Boolean, detail: String) {
            if (finished) return
            finished = true
            main.removeCallbacks(timeout)
            connection?.let { c -> try { unbindService(c) } catch (e: Exception) { } }
            hwPrefs.edit().putString(prefKey, (if (ok) "ok: " else "no: ") + detail).apply()
            done(ok, detail)
        }
        timeout = Runnable { finish(false, "the hardware decoder test did not finish in time") }
        val replies = Messenger(Handler(Looper.getMainLooper()) { msg ->
            val json = msg.data?.getString(HwProbeService.KEY_RESULT) ?: "{}"
            try {
                val o = JSONObject(json)
                if (o.optBoolean("ok")) {
                    finish(true, "${o.optString("decoder")} passed its test (${o.optInt("frames")} frames)")
                } else {
                    val why = o.optString("fallback").ifEmpty { o.optString("error") }
                        .ifEmpty { "${o.optString("decoder")} was not used" }
                    finish(false, why)
                }
            } catch (e: Exception) {
                finish(false, "unreadable test result")
            }
            true
        })
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (binder == null) {
                    finish(false, "the test process did not start")
                    return
                }
                try {
                    binder.linkToDeath({ main.post { finish(false, "the hardware decoder crashed during its test") } }, 0)
                    val msg = Message.obtain(null, HwProbeService.MSG_TEST)
                    msg.data = Bundle().apply { putString(HwProbeService.KEY_URI, uri) }
                    msg.replyTo = replies
                    Messenger(binder).send(msg)
                } catch (e: RemoteException) {
                    finish(false, "the hardware decoder crashed during its test")
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                finish(false, "the hardware decoder crashed during its test")
            }
        }
        connection = conn
        val bound = try {
            bindService(Intent(this, HwProbeService::class.java), conn, Context.BIND_AUTO_CREATE)
        } catch (e: Exception) {
            false
        }
        if (!bound) {
            connection = null
            finished = true
            done(false, "the hardware test process is not available")
            return
        }
        main.postDelayed(timeout, 20000)
    }

    // ---------------------------------------------------------------- helpers

    private fun launch(intent: Intent, onResult: (Intent?) -> Unit) {
        val code = nextRequest++
        pending[code] = onResult
        startActivityForResult(intent, code)
    }

    @Deprecated("Uses the platform activity result API on purpose (no AndroidX dependency).")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val callback = pending.remove(requestCode)
        if (callback != null) {
            callback(if (resultCode == Activity.RESULT_OK) data else null)
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
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

    private fun collectUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val clip = data.clipData
        if (clip != null) return (0 until clip.itemCount).map { clip.getItemAt(it).uri }
        return listOfNotNull(data.data)
    }

    private fun persist(uri: Uri) {
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            // Some providers do not offer persistable grants; access lasts for this session.
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) return c.getString(0)
        }
        return uri.lastPathSegment ?: "media"
    }

    private fun describe(uri: Uri): Map<String, Any?> {
        val mime = contentResolver.getType(uri) ?: ""
        var name = uri.lastPathSegment ?: "media"
        var size: Long? = null
        var modified: Long? = null
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                val s = c.getColumnIndex(OpenableColumns.SIZE)
                if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                val m = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                if (m >= 0 && !c.isNull(m)) modified = c.getLong(m)
            }
        }
        val kind = when {
            mime.startsWith("video/") -> "video"
            mime.startsWith("audio/") -> "audio"
            mime.startsWith("image/") -> "image"
            else -> guessKind(name)
        }
        val info = HashMap<String, Any?>()
        info["uri"] = uri.toString()
        info["name"] = name
        info["mime"] = mime
        info["kind"] = kind
        info["sizeBytes"] = size
        info["modifiedMs"] = modified
        info["probed"] = false
        when (kind) {
            "video", "audio" -> probeAv(uri, info)
            "image" -> probeImage(uri, info)
        }
        return info
    }

    private fun guessKind(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "mp4", "mov", "mkv", "webm", "m4v", "3gp", "avi" -> "video"
            "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus" -> "audio"
            else -> "image"
        }
    }

    private fun probeAv(uri: Uri, info: HashMap<String, Any?>) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(this, uri)
            val duration = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            info["durationMs"] = duration
            info["hasAudio"] = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            if (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes") {
                var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                if (rot == 90 || rot == 270) {
                    val t = w; w = h; h = t
                }
                info["width"] = w
                info["height"] = h
                if (Build.VERSION.SDK_INT >= 28) {
                    val frames = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toLongOrNull()
                    if (frames != null && duration != null && duration > 0) info["frameCount"] = frames
                }
            }
            info["probed"] = duration != null
        } catch (e: Exception) {
            info["probeError"] = e.message
        } finally {
            try { r.release() } catch (e: Exception) { }
        }
    }

    private fun probeImage(uri: Uri, info: HashMap<String, Any?>) {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
        if (opts.outWidth > 0) {
            info["width"] = opts.outWidth
            info["height"] = opts.outHeight
            info["probed"] = true
        }
    }

    private fun thumbnail(uri: Uri, kind: String, max: Int): ByteArray? {
        val bitmap: Bitmap? = when (kind) {
            "video" -> {
                val r = MediaMetadataRetriever()
                try {
                    r.setDataSource(this, uri)
                    val duration = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                    val at = (minOf(1000L, duration / 3)) * 1000L // microseconds
                    if (Build.VERSION.SDK_INT >= 27) {
                        r.getScaledFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, max, max)
                    } else {
                        r.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    }
                } finally {
                    try { r.release() } catch (e: Exception) { }
                }
            }
            "image" -> {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1
                while (bounds.outWidth / (sample * 2) >= max && bounds.outHeight / (sample * 2) >= max) sample *= 2
                val opts = BitmapFactory.Options().apply { inSampleSize = sample }
                contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
            }
            else -> null
        }
        if (bitmap == null) return null
        val scale = minOf(1f, max.toFloat() / maxOf(bitmap.width, bitmap.height))
        val scaled = if (scale < 1f) {
            Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt().coerceAtLeast(1), (bitmap.height * scale).toInt().coerceAtLeast(1), true)
        } else bitmap
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
        if (scaled !== bitmap) scaled.recycle()
        bitmap.recycle()
        return out.toByteArray()
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }
}

/** Writes uncaught Java/Kotlin exceptions to diagnostics/java-crash.txt, then lets the system handle them. */
class CutlabCrashHandler(
    private val dir: File,
    private val device: String,
    private val previous: Thread.UncaughtExceptionHandler?,
) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(t: Thread, e: Throwable) {
        try {
            val sw = StringWriter()
            e.printStackTrace(PrintWriter(sw))
            val rt = Runtime.getRuntime()
            File(dir, "java-crash.txt").writeText(
                "CUTLAB Java crash report\n" +
                    "time (unix): ${System.currentTimeMillis() / 1000}\n" +
                    "thread: ${t.name}\n" +
                    "device: $device\n" +
                    "java heap: ${(rt.totalMemory() - rt.freeMemory()) / 1048576} MB used of ${rt.maxMemory() / 1048576} MB\n\n" +
                    sw.toString(),
            )
        } catch (ignored: Throwable) {
        }
        previous?.uncaughtException(t, e)
    }
}

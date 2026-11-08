package com.lunaxoxone.studio.cutlab

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Native media access for CUTLAB on Android (channel "cutlab/media").
 *
 * Media is opened through the Storage Access Framework and kept as a
 * persistable content:// URI, so large recordings are never copied.
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val pending = HashMap<Int, (Intent?) -> Unit>()
    private var nextRequest = 7100

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
            "thumbnail" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                val kind = call.argument<String>("kind") ?: "video"
                val max = call.argument<Int>("maxSize") ?: 256
                background(result) { thumbnail(uri, kind, max) }
            }
            else -> result.notImplemented()
        }
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

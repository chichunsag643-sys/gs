package com.gs.gs_note

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.charset.Charset
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Importing into the app, all on the device:
 *  - the system file picker (Storage Access Framework, so no storage
 *    permission is needed),
 *  - files and text shared from other apps (공유) or opened with this app
 *    (열기),
 *  - decoding Korean "ANSI" (CP949) text files and reading audio length.
 *
 * Picked/shared files are copied into app-private cache and handed to Dart
 * by path. Dart side: lib/import/import_channel.dart.
 */
class Importer(private val activity: Activity, private val channel: MethodChannel) {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var pendingPick: MethodChannel.Result? = null

    /** Shared items waiting for Dart to take them. */
    private var sharedFiles = mutableListOf<Map<String, Any?>>()
    private var sharedText: String? = null
    private var sharedSubject: String? = null

    companion object {
        const val PICK_REQUEST = 4711
        private const val MAX_BYTES = 512L * 1024 * 1024
    }

    private val cacheDir: File
        get() = File(activity.cacheDir, "import").apply { mkdirs() }

    // ---- Picker -------------------------------------------------------------

    fun pick(kind: String, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "파일 선택 중입니다.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            if (kind == "audio") {
                type = "audio/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("audio/*", "video/mp4", "video/3gpp", "application/ogg"),
                )
            } else {
                // .md and backups often have no proper MIME type.
                type = "*/*"
            }
        }
        pendingPick = result
        try {
            activity.startActivityForResult(intent, PICK_REQUEST)
        } catch (e: Exception) {
            pendingPick = null
            result.error("no_picker", "파일 선택기를 열 수 없습니다.", null)
        }
    }

    /** Called from [MainActivity.onActivityResult]. */
    fun onPickResult(resultCode: Int, data: Intent?) {
        val result = pendingPick ?: return
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Any>())
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        io.execute {
            val files = uris.mapNotNull { copy(it, null) }
            main.post { result.success(files) }
        }
    }

    // ---- Share / open-with -------------------------------------------------

    /** Collects what [intent] carries. Returns true if it was a share. */
    fun handleIntent(intent: Intent?): Boolean {
        if (intent == null) return false
        val uris = mutableListOf<Uri>()
        var text: String? = null
        when (intent.action) {
            Intent.ACTION_SEND -> {
                streamExtra(intent)?.let { uris.add(it) }
                if (uris.isEmpty()) text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                uris.addAll(streamListExtra(intent))
                if (uris.isEmpty()) intent.clipData?.let { addClip(it, uris) }
            }
            Intent.ACTION_VIEW -> intent.data?.let { uris.add(it) }
            else -> return false
        }
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val mime = intent.type
        // Only once: a configuration change re-delivers the same intent.
        intent.action = Intent.ACTION_MAIN
        if (uris.isEmpty() && text.isNullOrBlank()) return false
        io.execute {
            val files = uris.mapNotNull { copy(it, mime) }
            main.post {
                synchronized(this) {
                    sharedFiles.addAll(files)
                    if (!text.isNullOrBlank()) {
                        sharedText = text
                        sharedSubject = subject
                    }
                }
                channel.invokeMethod("shared", null)
            }
        }
        return true
    }

    fun takeShared(result: MethodChannel.Result) {
        val out: Map<String, Any?>
        synchronized(this) {
            out = mapOf(
                "files" to sharedFiles.toList(),
                "text" to sharedText,
                "subject" to sharedSubject,
            )
            sharedFiles = mutableListOf()
            sharedText = null
            sharedSubject = null
        }
        result.success(out)
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)) ?: emptyList()

    private fun addClip(clip: ClipData, into: MutableList<Uri>) {
        for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { into.add(it) }
    }

    // ---- Copying -------------------------------------------------------------

    /** Copies [uri] into cache. Returns {path, name, mime} or null. */
    private fun copy(uri: Uri, fallbackMime: String?): Map<String, Any?>? = try {
        val resolver = activity.contentResolver
        var name: String? = null
        var size = -1L
        if (uri.scheme == "content") {
            resolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (n >= 0) name = c.getString(n)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        }
        if (name.isNullOrBlank()) name = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        if (size > MAX_BYTES) throw IllegalStateException("too large")
        val mime = resolver.getType(uri) ?: fallbackMime
        val safe = name!!.replace(Regex("[/\\\\:*?\"<>|]"), "_")
        val dest = File(cacheDir, "${UUID.randomUUID()}-$safe")
        resolver.openInputStream(uri)!!.use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
        }
        mapOf("path" to dest.absolutePath, "name" to name, "mime" to mime)
    } catch (e: Exception) {
        null
    }

    /** Leftover copies from an import that was interrupted. */
    fun clearCache() {
        io.execute {
            cacheDir.listFiles()?.forEach { f ->
                if (System.currentTimeMillis() - f.lastModified() > 24 * 3600 * 1000L) f.delete()
            }
        }
    }

    // ---- Helpers -------------------------------------------------------------

    fun decodeText(bytes: ByteArray, charset: String, result: MethodChannel.Result) {
        try {
            result.success(String(bytes, Charset.forName(charset)))
        } catch (e: Exception) {
            result.error("charset", e.message, null)
        }
    }

    fun audioDuration(path: String, result: MethodChannel.Result) {
        io.execute {
            val ms = try {
                val r = MediaMetadataRetriever()
                try {
                    r.setDataSource(path)
                    r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                } finally {
                    r.release()
                }
            } catch (e: Exception) {
                0L
            }
            main.post { result.success(ms) }
        }
    }
}

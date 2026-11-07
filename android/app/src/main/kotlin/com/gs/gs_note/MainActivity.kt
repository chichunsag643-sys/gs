package com.gs.gs_note

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth (fingerprint lock) requires a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private var transcriber: Transcriber? = null
    private var importer: Importer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gs_note/voice")
        transcriber = Transcriber(applicationContext, channel)
        channel.setMethodCallHandler { call, result ->
            val t = transcriber!!
            when (call.method) {
                "availability" -> t.availability(call.argument<String>("language") ?: "ko-KR", result)
                "transcribe" -> t.transcribe(
                    call.argument<String>("path")!!,
                    call.argument<String>("language") ?: "ko-KR",
                    result,
                )
                "recordingStarted" -> {
                    RecordingService.start(applicationContext)
                    result.success(null)
                }
                "recordingStopped" -> {
                    RecordingService.stop(applicationContext)
                    result.success(null)
                }
                "cancel" -> {
                    t.cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val importChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gs_note/import")
        val imp = Importer(this, importChannel)
        importer = imp
        imp.clearCache()
        importChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> imp.pick(call.argument<String>("kind") ?: "notes", result)
                "takeShared" -> imp.takeShared(result)
                "decodeText" -> imp.decodeText(
                    call.argument<ByteArray>("bytes")!!,
                    call.argument<String>("charset") ?: "x-windows-949",
                    result,
                )
                "audioDuration" -> imp.audioDuration(call.argument<String>("path")!!, result)
                else -> result.notImplemented()
            }
        }
        // The app was started by 공유 / 열기 from another app.
        imp.handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        importer?.handleIntent(intent)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == Importer.PICK_REQUEST) importer?.onPickResult(resultCode, data)
    }

    override fun onDestroy() {
        transcriber?.cancel()
        RecordingService.stop(applicationContext)
        super.onDestroy()
    }
}

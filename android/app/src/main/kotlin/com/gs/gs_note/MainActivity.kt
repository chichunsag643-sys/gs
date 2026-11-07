package com.gs.gs_note

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth (fingerprint lock) requires a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private var transcriber: Transcriber? = null

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
    }

    override fun onDestroy() {
        transcriber?.cancel()
        RecordingService.stop(applicationContext)
        super.onDestroy()
    }
}

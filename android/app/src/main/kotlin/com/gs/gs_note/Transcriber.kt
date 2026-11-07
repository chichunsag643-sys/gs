package com.gs.gs_note

import android.annotation.TargetApi
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Turns a recorded voice memo into text using Android's ON-DEVICE speech
 * recognizer only. Audio never leaves the phone: we use
 * [SpeechRecognizer.createOnDeviceSpeechRecognizer], which has no network
 * fallback, and feed it the decoded recording through a pipe
 * ([RecognizerIntent.EXTRA_AUDIO_SOURCE], Android 13+).
 *
 * Dart side: lib/audio/transcriber.dart.
 */
class Transcriber(private val context: Context, private val channel: MethodChannel) {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var decodeThread: Thread? = null
    private val cancelled = AtomicBoolean(false)
    private var pending: MethodChannel.Result? = null
    private var readSide: ParcelFileDescriptor? = null

    companion object {
        private const val RATE = 16000
    }

    // ---- Availability ------------------------------------------------------

    /**
     * Replies with one of: "ok", "unsupported_os", "no_on_device",
     * "language_missing", "downloading".
     */
    fun availability(language: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.success("unsupported_os")
            return
        }
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            result.success("no_on_device")
            return
        }
        checkLanguage(language) { status -> result.success(status) }
    }

    @TargetApi(33)
    private fun checkLanguage(language: String, done: (String) -> Unit) {
        val sr = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        val intent = recognizeIntent(language)
        val replied = AtomicBoolean(false)
        fun reply(status: String) {
            if (!replied.compareAndSet(false, true)) return
            main.post {
                sr.destroy()
                done(status)
            }
        }
        sr.checkRecognitionSupport(intent, Executors.newSingleThreadExecutor(),
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    val lang = language.substringBefore('-')
                    fun has(list: List<String>) =
                        list.any { it.equals(language, true) || it.substringBefore('-').equals(lang, true) }
                    when {
                        has(support.installedOnDeviceLanguages) -> reply("ok")
                        has(support.pendingOnDeviceLanguages) -> reply("downloading")
                        has(support.supportedOnDeviceLanguages) -> {
                            // Ask the system to fetch the Korean model (Google
                            // downloads it like a keyboard language pack).
                            main.post { sr.triggerModelDownload(intent) }
                            reply("downloading")
                        }
                        else -> reply("language_missing")
                    }
                }

                override fun onError(error: Int) {
                    // Some recognizers don't implement the support check;
                    // let the real attempt decide.
                    reply("ok")
                }
            })
    }

    private fun recognizeIntent(language: String) =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }

    // ---- Transcription -----------------------------------------------------

    fun transcribe(path: String, language: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.error("unsupported_os", "Android 13 이상에서만 받아쓰기를 지원합니다.", null)
            return
        }
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            result.error("no_on_device", "이 기기에는 기기 내 음성 인식기가 없습니다.", null)
            return
        }
        if (pending != null) {
            result.error("busy", "이미 받아쓰기 중입니다.", null)
            return
        }
        cancelled.set(false)
        pending = result
        start(path, language)
    }

    @TargetApi(33)
    private fun start(path: String, language: String) {
        val pipe = ParcelFileDescriptor.createPipe()
        val readSide = pipe[0]
        this.readSide = readSide
        val writeSide = pipe[1]
        val text = StringBuilder()

        val sr = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        recognizer = sr
        sr.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}

            override fun onSegmentResults(segmentResults: Bundle) {
                val seg = best(segmentResults)
                if (seg.isNotBlank()) {
                    if (text.isNotEmpty()) text.append(' ')
                    text.append(seg.trim())
                    channel.invokeMethod("segment", text.toString())
                }
            }

            override fun onEndOfSegmentedSession() = finish(text.toString())

            // Recognizers without segmented sessions report once at the end.
            override fun onResults(results: Bundle?) {
                val seg = results?.let { best(it) } ?: ""
                if (seg.isNotBlank()) {
                    if (text.isNotEmpty()) text.append(' ')
                    text.append(seg.trim())
                }
                finish(text.toString())
            }

            override fun onError(error: Int) {
                when (error) {
                    // Nothing (more) was said: not an error for a memo.
                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> finish(text.toString())
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                    SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                        sr.triggerModelDownload(recognizeIntent(language))
                        fail("language_unavailable", "한국어 음성 인식 데이터를 내려받는 중입니다. 잠시 후 다시 시도하세요.")
                    }
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                        fail("permission", "마이크 권한이 필요합니다.")
                    else -> if (text.isNotEmpty()) finish(text.toString())
                            else fail("error_$error", "받아쓰기에 실패했습니다 (오류 $error).")
                }
            }
        })

        val intent = recognizeIntent(language).apply {
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, readSide)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
            // Keep recognising across pauses until the audio ends.
            putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
        }
        sr.startListening(intent)

        decodeThread = Thread {
            try {
                ParcelFileDescriptor.AutoCloseOutputStream(writeSide).use { out ->
                    decodeToPcm16kMono(path, out)
                }
            } catch (e: Exception) {
                // Pipe closed by cancel/finish, or unreadable file.
                if (!cancelled.get()) main.post {
                    if (text.isEmpty()) fail("decode", "녹음 파일을 읽을 수 없습니다.")
                }
            } finally {
                runCatching { readSide.close() }
            }
        }.apply { start() }
    }

    fun cancel() {
        cancelled.set(true)
        main.post {
            recognizer?.cancel()
            fail("cancelled", "취소했습니다.")
        }
    }

    private fun best(bundle: Bundle): String =
        bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

    private fun finish(text: String) {
        val r = pending ?: return
        cleanup()
        r.success(text)
    }

    private fun fail(code: String, message: String) {
        val r = pending ?: return
        cleanup()
        r.error(code, message, null)
    }

    private fun cleanup() {
        pending = null
        cancelled.set(true)
        recognizer?.destroy()
        recognizer = null
        // Closing our read end makes a blocked pipe write fail, so the
        // decode thread stops instead of waiting forever.
        readSide?.let { runCatching { it.close() } }
        readSide = null
        decodeThread?.interrupt()
        decodeThread = null
    }

    // ---- Decoding ----------------------------------------------------------

    /** Decodes [path] (AAC .m4a) and writes 16 kHz mono 16-bit PCM to [out]. */
    private fun decodeToPcm16kMono(path: String, out: OutputStream) {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        var track = -1
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) { track = i; break }
        }
        require(track >= 0) { "no audio track" }
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()

        var inRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val resampler = Resampler()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        try {
            while (!outputDone && !cancelled.get()) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        inRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                    outIdx >= 0 -> {
                        if (info.size > 0) {
                            val buf = codec.getOutputBuffer(outIdx)!!
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            val shorts = buf.order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                            val frames = shorts.remaining() / channels
                            val mono = ShortArray(frames)
                            for (i in 0 until frames) {
                                var sum = 0
                                for (c in 0 until channels) sum += shorts.get(i * channels + c)
                                mono[i] = (sum / channels).toShort()
                            }
                            out.write(resampler.process(mono, inRate))
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
            out.flush()
        } finally {
            codec.stop()
            codec.release()
            extractor.release()
        }
    }

    /** Streaming linear-interpolation resampler to [RATE] Hz. */
    private class Resampler {
        private var consumed = 0L // input samples seen before the current buffer
        private var next = 0.0 // position of the next output sample, in input samples
        private var last: Short = 0

        fun process(input: ShortArray, inRate: Int): ByteArray {
            if (input.isEmpty()) return ByteArray(0)
            val step = inRate.toDouble() / RATE
            val end = consumed + input.size - 1
            val outSamples = ShortArray(((end - next) / step).toInt().coerceAtLeast(0) + 2)
            var n = 0
            fun at(j: Long): Int = if (j < consumed) last.toInt() else input[(j - consumed).toInt()].toInt()
            while (next <= end) {
                val i = Math.floor(next).toLong()
                val frac = next - i
                val a = at(i)
                val b = if (i + 1 <= end) at(i + 1) else a
                outSamples[n++] = (a + (b - a) * frac).toInt().toShort()
                next += step
            }
            last = input[input.size - 1]
            consumed += input.size
            val bytes = ByteArray(n * 2)
            for (k in 0 until n) {
                val s = outSamples[k].toInt()
                bytes[2 * k] = (s and 0xff).toByte()
                bytes[2 * k + 1] = ((s shr 8) and 0xff).toByte()
            }
            return bytes
        }
    }
}

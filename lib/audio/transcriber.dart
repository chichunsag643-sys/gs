import 'package:flutter/services.dart';

/// Why on-device transcription can't run right now.
enum TranscribeAvailability {
  ok,

  /// Needs Android 13 or newer.
  unsupportedOs,

  /// The phone has no on-device recognizer.
  noOnDevice,

  /// The on-device recognizer has no Korean model.
  languageMissing,

  /// The Korean model is being downloaded by the system.
  downloading;

  String get message => switch (this) {
        ok => '',
        unsupportedOs => '받아쓰기는 Android 13 이상에서 됩니다. 녹음은 그대로 저장됩니다.',
        noOnDevice => '이 기기에는 기기 안에서 처리하는 음성 인식기가 없어 받아쓰기를 할 수 없습니다. 녹음은 그대로 저장됩니다.',
        languageMissing => '이 기기의 음성 인식기가 한국어를 지원하지 않습니다.',
        downloading => '한국어 음성 인식 데이터를 내려받는 중입니다. 잠시 후 다시 시도하세요.',
      };
}

class TranscribeException implements Exception {
  TranscribeException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Speech-to-text for recorded voice memos, using only Android's on-device
/// recognizer (no network). Native side: android/.../Transcriber.kt.
class Transcriber {
  Transcriber({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('gs_note/voice') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  void Function(String textSoFar)? _onSegment;

  static const language = 'ko-KR';

  Future<TranscribeAvailability> availability() async {
    try {
      final s = await _channel
          .invokeMethod<String>('availability', {'language': language});
      return switch (s) {
        'ok' => TranscribeAvailability.ok,
        'unsupported_os' => TranscribeAvailability.unsupportedOs,
        'language_missing' => TranscribeAvailability.languageMissing,
        'downloading' => TranscribeAvailability.downloading,
        _ => TranscribeAvailability.noOnDevice,
      };
    } on MissingPluginException {
      return TranscribeAvailability.noOnDevice;
    }
  }

  /// Transcribes the audio file at [path]. [onSegment] receives the text
  /// recognised so far while it runs.
  Future<String> transcribe(String path,
      {void Function(String textSoFar)? onSegment}) async {
    _onSegment = onSegment;
    try {
      final text = await _channel.invokeMethod<String>(
          'transcribe', {'path': path, 'language': language});
      return (text ?? '').trim();
    } on PlatformException catch (e) {
      throw TranscribeException(e.code, e.message ?? '받아쓰기에 실패했습니다.');
    } on MissingPluginException {
      throw TranscribeException(
          'no_on_device', TranscribeAvailability.noOnDevice.message);
    } finally {
      _onSegment = null;
    }
  }

  /// Shows the "recording" notification that keeps the microphone open
  /// while the screen is off (Android foreground service).
  Future<void> recordingStarted() => _safe('recordingStarted');
  Future<void> recordingStopped() => _safe('recordingStopped');

  Future<void> _safe(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException {
      // Recording still works while the app is in front.
    }
  }

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Not on Android.
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'segment') _onSegment?.call(call.arguments as String);
    return null;
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// A file the user picked or shared to the app, copied into the app's cache.
class PickedFile {
  PickedFile({required this.path, required this.name, this.mime});
  final String path;
  final String name;
  final String? mime;

  static PickedFile fromMap(Map<Object?, Object?> m) => PickedFile(
        path: m['path'] as String,
        name: m['name'] as String,
        mime: m['mime'] as String?,
      );

  Future<void> delete() async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// What another app shared to this one (공유 → 메모), or a file opened with
/// it (열기 → 메모).
class SharedItems {
  SharedItems({this.files = const [], this.text, this.subject});
  final List<PickedFile> files;
  final String? text;
  final String? subject;

  bool get isEmpty => files.isEmpty && (text == null || text!.trim().isEmpty);
}

/// The Android side of importing: the system file picker, files and text
/// shared from other apps, and a few helpers. Native side: MainActivity.kt.
///
/// Files are read through the system picker (no storage permission) and
/// copied into app-private cache; nothing goes over the network.
class ImportChannel {
  ImportChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('gs_note/import') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _shared = StreamController<void>.broadcast();

  /// Fires when something was shared to the app while it is running; call
  /// [takeShared] to get it.
  Stream<void> get sharedArrived => _shared.stream;

  /// Opens the system file picker. [audio] limits it to audio files.
  Future<List<PickedFile>> pick({required bool audio}) async {
    try {
      final list = await _channel
          .invokeListMethod<Object?>('pick', {'kind': audio ? 'audio' : 'notes'});
      return [
        for (final m in list ?? const [])
          PickedFile.fromMap(m as Map<Object?, Object?>),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Files/text shared to the app that have not been handled yet.
  Future<SharedItems> takeShared() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('takeShared');
      if (m == null) return SharedItems();
      return SharedItems(
        files: [
          for (final f in (m['files'] as List<Object?>? ?? const []))
            PickedFile.fromMap(f as Map<Object?, Object?>),
        ],
        text: m['text'] as String?,
        subject: m['subject'] as String?,
      );
    } on MissingPluginException {
      return SharedItems();
    }
  }

  /// Decodes a non-UTF-8 text file with the Korean Windows code page.
  Future<String> decodeLegacy(Uint8List bytes) async {
    final s = await _channel.invokeMethod<String>(
        'decodeText', {'bytes': bytes, 'charset': 'x-windows-949'});
    return s ?? '';
  }

  /// Length of an audio file, or zero if unknown.
  Future<Duration> audioDuration(String path) async {
    try {
      final ms =
          await _channel.invokeMethod<int>('audioDuration', {'path': path});
      return Duration(milliseconds: ms ?? 0);
    } on MissingPluginException {
      return Duration.zero;
    } on PlatformException {
      return Duration.zero;
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'shared') _shared.add(null);
    return null;
  }
}

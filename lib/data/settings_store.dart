import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

/// Per-device settings, stored in the encrypted database's `meta` table.
/// These are never synced: each device decides for itself.
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._db, this._values);

  final Database _db;
  final Map<String, String> _values;

  static const _deviceId = 'device_id';
  static const _deviceName = 'device_name';
  static const _libraryEnabled = 'library_enabled';
  static const _lockEnabled = 'lock_enabled';
  static const _lastHlc = 'last_hlc';
  static const _audioSync = 'audio_sync';
  static const _syncEnabled = 'sync_enabled';
  static const _autoTranscribe = 'auto_transcribe';

  static Future<SettingsStore> load(Database db) async {
    final rows = await db.query('meta');
    final values = {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
    final store = SettingsStore._(db, values);
    if (!values.containsKey(_deviceId)) {
      await store._set(_deviceId, const Uuid().v4());
    }
    return store;
  }

  /// Stable id of this device; used as the HLC node id.
  String get deviceId => _values[_deviceId]!;

  String get deviceName => _values[_deviceName] ?? '내 기기';
  Future<void> setDeviceName(String name) => _set(_deviceName, name);

  /// "서재" (folders). When off, only a flat notepad is shown.
  bool get libraryEnabled => _values[_libraryEnabled] != '0';
  Future<void> setLibraryEnabled(bool v) => _set(_libraryEnabled, v ? '1' : '0');

  /// Fingerprint / device credential lock.
  bool get lockEnabled => _values[_lockEnabled] == '1';
  Future<void> setLockEnabled(bool v) => _set(_lockEnabled, v ? '1' : '0');

  /// Whether this device syncs with its paired devices.
  bool get syncEnabled => _values[_syncEnabled] != '0';
  Future<void> setSyncEnabled(bool v) => _set(_syncEnabled, v ? '1' : '0');

  /// Whether this device keeps voice memo audio recorded on other devices.
  ///
  /// * `text_only` (default): only the transcript and the recording's details
  ///   arrive; the audio stays on the devices that have it.
  /// * `all`: audio files are copied to this device too.
  ///
  /// Recordings made on this device are always kept here.
  String get audioSync =>
      _values[_audioSync] == audioSyncAll ? audioSyncAll : audioSyncTextOnly;
  Future<void> setAudioSync(String v) => _set(_audioSync, v);

  static const audioSyncTextOnly = 'text_only';
  static const audioSyncAll = 'all';

  /// Turn a new recording into text right after it stops.
  bool get autoTranscribe => _values[_autoTranscribe] != '0';
  Future<void> setAutoTranscribe(bool v) =>
      _set(_autoTranscribe, v ? '1' : '0');

  String? get lastHlc => _values[_lastHlc];
  Future<void> setLastHlc(String hlc) => _set(_lastHlc, hlc, notify: false);

  Future<void> _set(String key, String value, {bool notify = true}) async {
    _values[key] = value;
    await _db.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (notify) notifyListeners();
  }
}

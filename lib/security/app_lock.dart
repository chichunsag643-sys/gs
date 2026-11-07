import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import '../data/settings_store.dart';

/// Locks the app behind fingerprint (or the device PIN/pattern as fallback)
/// at launch and whenever it returns from the background.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock(this._settings, {LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication(),
        _locked = _settings.lockEnabled {
    WidgetsBinding.instance.addObserver(this);
  }

  final SettingsStore _settings;
  final LocalAuthentication _auth;
  bool _locked;
  bool _authenticating = false;

  bool get locked => _locked;

  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// Shows the system biometric prompt. Returns true on success.
  Future<bool> authenticate({String reason = '메모를 열려면 인증하세요'}) async {
    if (_authenticating) return false;
    _authenticating = true;
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
      return ok;
    } on LocalAuthException catch (e) {
      debugPrint('auth failed: $e');
      return false;
    } on PlatformException catch (e) {
      debugPrint('auth failed: $e');
      return false;
    } finally {
      _authenticating = false;
    }
  }

  Future<bool> unlock() async {
    final ok = await authenticate();
    if (ok) {
      _locked = false;
      notifyListeners();
    }
    return ok;
  }

  /// Turns the lock on (after a successful check) or off.
  Future<bool> setEnabled(bool enabled) async {
    if (enabled) {
      final ok = await authenticate(reason: '지문 잠금을 켜려면 인증하세요');
      if (!ok) return false;
    }
    await _settings.setLockEnabled(enabled);
    notifyListeners();
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The biometric prompt itself pauses the activity on some devices;
    // ignore lifecycle changes while it is showing.
    if (_authenticating) return;
    if (state == AppLifecycleState.paused && _settings.lockEnabled) {
      _locked = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

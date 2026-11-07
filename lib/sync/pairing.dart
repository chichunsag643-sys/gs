import 'dart:convert';

import 'crypto.dart';

/// What the "add device" QR code carries: how to reach the device showing
/// it, and a one-time key for the join request. The sync group key itself
/// is never in the QR code; it is sent encrypted after the scan.
class PairingInvite {
  const PairingInvite({
    required this.deviceId,
    required this.name,
    required this.addresses,
    required this.port,
    required this.token,
  });

  final String deviceId;
  final String name;
  final List<String> addresses;
  final int port;
  final List<int> token;

  static const _prefix = 'GSNOTE1:';

  String encode() => _prefix +
      base64Url
          .encode(utf8.encode(jsonEncode({
            'id': deviceId,
            'n': name,
            'a': addresses,
            'p': port,
            't': encodeKey(token),
          })))
          .replaceAll('=', '');

  /// Parses a scanned or pasted code. Throws [FormatException] if it is not
  /// one of ours.
  factory PairingInvite.decode(String text) {
    final t = text.trim();
    if (!t.startsWith(_prefix)) {
      throw const FormatException('메모 앱의 기기 추가 코드가 아닙니다.');
    }
    try {
      final json = jsonDecode(utf8.decode(
              base64Url.decode(base64Url.normalize(t.substring(_prefix.length)))))
          as Map<String, Object?>;
      return PairingInvite(
        deviceId: json['id'] as String,
        name: json['n'] as String,
        addresses: [for (final a in json['a'] as List) a as String],
        port: json['p'] as int,
        token: decodeKey(json['t'] as String),
      );
    } catch (_) {
      throw const FormatException('코드를 읽을 수 없습니다.');
    }
  }
}

/// The joinable window on the device showing the QR code.
class PairingSession {
  PairingSession(this.token, Duration lifetime)
      : _expires = DateTime.now().add(lifetime);

  final List<int> token;
  final DateTime _expires;
  bool _closed = false;

  /// Names of devices that joined through this code.
  final joined = <String>[];

  bool get valid => !_closed && DateTime.now().isBefore(_expires);
  void close() => _closed = true;
}

class PairingException implements Exception {
  const PairingException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

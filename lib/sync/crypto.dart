import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Authenticated encryption for everything that leaves the device.
///
/// AES-256-GCM: a frame that was tampered with, or encrypted with another
/// key, fails to decrypt. Each message gets a fresh random 12-byte nonce.
class SyncCipher {
  SyncCipher(List<int> key) : _key = SecretKey(List<int>.unmodifiable(key)) {
    if (key.length != 32) throw ArgumentError('key must be 32 bytes');
  }

  final SecretKey _key;
  static final _algo = AesGcm.with256bits();

  Future<Uint8List> seal(List<int> plain) async {
    final box = await _algo.encrypt(plain,
        secretKey: _key, nonce: _algo.newNonce());
    return box.concatenation();
  }

  /// Throws [SecretBoxAuthenticationError] if the frame is not ours.
  Future<List<int>> open(List<int> sealed) async {
    final box = SecretBox.fromConcatenation(sealed,
        nonceLength: _algo.nonceLength, macLength: _algo.macAlgorithm.macLength);
    return _algo.decrypt(box, secretKey: _key);
  }

  Future<Uint8List> sealJson(Object? value) =>
      seal(utf8.encode(jsonEncode(value)));

  Future<Map<String, Object?>> openJson(List<int> sealed) async =>
      jsonDecode(utf8.decode(await open(sealed))) as Map<String, Object?>;
}

/// 32 random bytes from the OS CSPRNG.
List<int> randomKey() {
  final r = Random.secure();
  return List<int>.generate(32, (_) => r.nextInt(256));
}

String encodeKey(List<int> key) => base64Url.encode(key).replaceAll('=', '');

List<int> decodeKey(String text) =>
    base64Url.decode(base64Url.normalize(text.trim()));

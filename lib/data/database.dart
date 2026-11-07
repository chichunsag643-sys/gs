import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'schema.dart';

/// Opens the on-device SQLCipher database.
///
/// The 256-bit key is generated on first launch and kept in the Android
/// Keystore (iOS/macOS Keychain) via flutter_secure_storage, so the database
/// file is unreadable if copied off the device.
Future<Database> openEncryptedDatabase() async {
  final key = await _loadOrCreateKey();
  final dir = await getDatabasesPath();
  return openDatabase(
    p.join(dir, 'notes.db'),
    password: key,
    version: schemaVersion,
    onCreate: createSchema,
    onUpgrade: upgradeSchema,
  );
}

const _keyName = 'db_key_v1';

Future<String> _loadOrCreateKey() async {
  const storage = FlutterSecureStorage();
  final existing = await storage.read(key: _keyName);
  if (existing != null) return existing;
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  final key = base64Url.encode(bytes);
  await storage.write(key: _keyName, value: key);
  return key;
}

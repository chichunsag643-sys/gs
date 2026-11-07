import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'app_scope.dart';
import 'audio/transcriber.dart';
import 'data/attachment_repository.dart';
import 'data/database.dart';
import 'data/note_repository.dart';
import 'data/settings_store.dart';
import 'security/app_lock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openEncryptedDatabase();
  final settings = await SettingsStore.load(db);
  final repo = await NoteRepository.load(db, settings);
  final support = await getApplicationSupportDirectory();
  final attachments = await AttachmentRepository.load(
      db, settings, repo, Directory(p.join(support.path, 'attachments')));
  final lock = AppLock(settings);
  runApp(AppScope(
    repo: repo,
    settings: settings,
    lock: lock,
    attachments: attachments,
    voice: Transcriber(),
    child: const NoteApp(),
  ));
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_scope.dart';
import '../audio/transcriber.dart';
import '../data/models.dart';
import '../import/delta_builder.dart';
import '../import/import_channel.dart';
import '../import/note_import.dart';

/// Opens a note in the editor (set by the home screen, to avoid an import
/// cycle).
typedef OpenNote = Future<void> Function(BuildContext context, String noteId);

/// The "불러오기" menu: note files, or audio files to transcribe.
Future<void> showImportMenu(BuildContext context,
    {String? folderId, required OpenNote openNote}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('불러오기'),
            subtitle: Text('파일은 이 기기 안에서만 읽고, 어디로도 보내지 않습니다.'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('메모 파일 불러오기'),
            subtitle: const Text(
                'txt, md, html, 구글 Keep(Takeout zip), 에버노트(.enex), 워드(.docx·삼성 노트 내보내기)'),
            onTap: () => Navigator.pop(sheet, 'notes'),
          ),
          ListTile(
            leading: const Icon(Icons.audio_file_outlined),
            title: const Text('음성 파일 받아쓰기'),
            subtitle: const Text('m4a, mp3, wav 등 녹음 파일을 글자로 바꿔 메모로 저장'),
            onTap: () => Navigator.pop(sheet, 'audio'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final channel = AppScope.of(context).importer;
  final files = await channel.pick(audio: choice == 'audio');
  if (files.isEmpty || !context.mounted) return;
  await importFiles(context, files, folderId: folderId, openNote: openNote);
}

/// Handles anything shared to the app (공유 / 열기) from another app.
Future<void> importShared(BuildContext context, SharedItems items,
    {String? folderId, required OpenNote openNote}) async {
  final scope = AppScope.of(context);
  final created = <String>[];
  final text = items.text;
  if (text != null && text.trim().isNotEmpty) {
    final n = NoteImporter.fromSharedText(text, subject: items.subject);
    final note = await scope.repo.importNote(
      title: n.title,
      content: n.content,
      plainText: n.plainText,
      folderId: folderId,
    );
    created.add(note.id);
  }
  if (!context.mounted) return;
  if (items.files.isNotEmpty) {
    await importFiles(context, items.files,
        folderId: folderId, openNote: openNote, alreadyCreated: created);
  } else if (created.length == 1) {
    await openNote(context, created.single);
  }
}

/// Imports picked or shared [files]: audio is transcribed, everything else
/// is read as notes. A single resulting note is opened for editing.
Future<void> importFiles(
  BuildContext context,
  List<PickedFile> files, {
  String? folderId,
  required OpenNote openNote,
  List<String> alreadyCreated = const [],
}) async {
  final audio = [
    for (final f in files)
      if (NoteImporter.isAudio(f.name, f.mime)) f,
  ];
  final docs = [
    for (final f in files)
      if (!audio.contains(f)) f,
  ];
  final created = [...alreadyCreated];
  final skipped = <String>[];
  try {
    if (docs.isNotEmpty) {
      created.addAll(await _importDocuments(context, docs, folderId, skipped));
    }
    if (audio.isNotEmpty && context.mounted) {
      created.addAll(await _importAudio(context, audio, folderId, skipped));
    }
  } finally {
    for (final f in files) {
      await f.delete();
    }
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (skipped.isNotEmpty) {
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(created.isEmpty
            ? '불러오지 못했습니다'
            : '메모 ${created.length}개를 불러왔습니다'),
        content: SingleChildScrollView(
          child: Text('불러오지 못한 파일:\n${skipped.map((s) => '• $s').join('\n')}'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('확인')),
        ],
      ),
    );
  } else if (created.length > 1) {
    messenger.showSnackBar(
        SnackBar(content: Text('메모 ${created.length}개를 불러왔습니다.')));
  }
  if (created.length == 1 && context.mounted) {
    await openNote(context, created.single);
  }
}

Future<List<String>> _importDocuments(BuildContext context,
    List<PickedFile> files, String? folderId, List<String> skipped) async {
  final scope = AppScope.of(context);
  final importer = NoteImporter(legacyDecode: scope.importer.decodeLegacy);
  final result = ImportResult();
  final busy = _showBusy(context, '메모를 읽는 중');
  try {
    for (final f in files) {
      final bytes = await File(f.path).readAsBytes();
      await importer.importFile(f.name, bytes, into: result);
    }
    final ids = <String>[];
    final library = scope.settings.libraryEnabled;
    for (final n in result.notes) {
      if (n.isEmpty) continue;
      var folder = folderId;
      // Keep labels / notebooks become folders when the library is on.
      if (library && folder == null && n.label != null) {
        folder = (await scope.repo.folderNamed(n.label!)).id;
      }
      final note = await scope.repo.importNote(
        title: n.title,
        content: n.content,
        plainText: n.plainText,
        folderId: folder,
        pinned: n.pinned,
        createdAt: n.createdAt,
        updatedAt: n.updatedAt,
      );
      ids.add(note.id);
    }
    skipped.addAll(result.skipped);
    return ids;
  } finally {
    busy.close();
  }
}

/// Transcribes [files] on the device and saves each as a note.
Future<List<String>> _importAudio(BuildContext context, List<PickedFile> files,
    String? folderId, List<String> skipped) async {
  final scope = AppScope.of(context);
  final voice = scope.voice;
  final availability = await voice.availability();
  if (!context.mounted) return const [];
  final canTranscribe = availability == TranscribeAvailability.ok;

  final keepAudio = await showDialog<bool>(
    context: context,
    builder: (d) => _AudioImportDialog(
      count: files.length,
      unavailable: canTranscribe ? null : availability.message,
    ),
  );
  if (keepAudio == null || !context.mounted) return const [];
  if (!canTranscribe && !keepAudio) return const [];

  final ids = <String>[];
  final progress = ValueNotifier<(String, String)>(('', ''));
  var cancelled = false;
  final dialog = canTranscribe
      ? showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (d) => AlertDialog(
            title: const Text('받아쓰는 중'),
            content: ValueListenableBuilder<(String, String)>(
              valueListenable: progress,
              builder: (_, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.$1, style: Theme.of(d).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                      v.$2.isEmpty
                          ? '기기 안에서 글자로 바꾸고 있습니다. 인터넷은 쓰지 않습니다.'
                          : v.$2,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  voice.cancel();
                },
                child: const Text('취소'),
              ),
            ],
          ),
        )
      : null;

  try {
    for (var i = 0; i < files.length && !cancelled; i++) {
      final f = files[i];
      final title = p.basenameWithoutExtension(f.name);
      progress.value = (
        files.length > 1 ? '(${i + 1}/${files.length}) $title' : title,
        ''
      );
      final duration = await scope.importer.audioDuration(f.path);
      final note = await scope.repo.importNote(
        title: title,
        content: '',
        plainText: '',
        folderId: folderId,
      );
      var audioPath = f.path;
      Attachment? attachment;
      if (keepAudio) {
        attachment = await scope.attachments.addRecording(note.id, f.path,
            duration: duration, mime: _audioMime(f));
        audioPath = scope.attachments.audioPath(attachment.id);
      }
      String text = '';
      if (canTranscribe) {
        try {
          text = await voice.transcribe(audioPath,
              onSegment: (t) => progress.value = (progress.value.$1, t));
        } on TranscribeException catch (e) {
          if (e.code == 'cancelled') {
            cancelled = true;
          } else {
            skipped.add('${f.name} (${e.message})');
          }
        }
      }
      if (text.isNotEmpty) {
        final body = DeltaBuilder.plain(text);
        await scope.repo.updateNote(note.id,
            content: body.toContent(), plainText: body.plainText);
        ids.add(note.id);
      } else if (keepAudio) {
        if (canTranscribe && !cancelled) {
          skipped.add('${f.name} (알아들을 수 있는 말이 없음, 음성만 저장)');
        }
        ids.add(note.id);
      } else {
        if (!cancelled && !skipped.any((s) => s.startsWith(f.name))) {
          skipped.add('${f.name} (알아들을 수 있는 말이 없음)');
        }
        await scope.repo.deleteNote(note.id);
      }
    }
  } finally {
    if (dialog != null && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await dialog;
    progress.dispose();
  }
  if (!canTranscribe && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(availability.message)));
  }
  return ids;
}

String _audioMime(PickedFile f) {
  final m = f.mime;
  if (m != null && m.startsWith('audio/')) return m;
  return switch (p.extension(f.name).toLowerCase()) {
    '.mp3' => 'audio/mpeg',
    '.wav' => 'audio/wav',
    '.aac' => 'audio/aac',
    '.ogg' || '.oga' || '.opus' => 'audio/ogg',
    '.flac' => 'audio/flac',
    '.amr' => 'audio/amr',
    '.3gp' || '.3gpp' => 'audio/3gpp',
    '.webm' => 'audio/webm',
    _ => 'audio/mp4',
  };
}

class _AudioImportDialog extends StatefulWidget {
  const _AudioImportDialog({required this.count, this.unavailable});
  final int count;

  /// Why transcription can't run, or null if it can.
  final String? unavailable;

  @override
  State<_AudioImportDialog> createState() => _AudioImportDialogState();
}

class _AudioImportDialogState extends State<_AudioImportDialog> {
  bool _keep = false;

  @override
  Widget build(BuildContext context) {
    final unavailable = widget.unavailable;
    return AlertDialog(
      title: Text(widget.count > 1
          ? '음성 파일 ${widget.count}개 받아쓰기'
          : '음성 파일 받아쓰기'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(unavailable ??
              '기기 안의 음성 인식기로 글자로 바꿔 파일마다 새 메모로 저장합니다. 인터넷은 쓰지 않습니다. 녹음 길이만큼 시간이 걸릴 수 있습니다.'),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: unavailable != null || _keep,
            onChanged: unavailable != null
                ? null
                : (v) => setState(() => _keep = v ?? false),
            title: const Text('원본 음성도 메모에 보관'),
            subtitle: const Text('메모 안에서 다시 들을 수 있습니다.'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소')),
        FilledButton(
          onPressed: () => Navigator.pop(context, unavailable != null || _keep),
          child: Text(unavailable != null ? '음성만 저장' : '받아쓰기'),
        ),
      ],
    );
  }
}

/// A small "working…" dialog. Call [close] when done.
_Busy _showBusy(BuildContext context, String message) {
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 24, height: 24, child: CircularProgressIndicator()),
            const SizedBox(width: 16),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  ).whenComplete(() => open = false);
  return _Busy(() {
    if (open) navigator.pop();
  });
}

class _Busy {
  _Busy(this.close);
  final void Function() close;
}

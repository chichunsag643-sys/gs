import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/models.dart';

Future<String?> promptFolderName(BuildContext context, {String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(initial.isEmpty ? '새 폴더' : '폴더 이름 바꾸기'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '폴더 이름'),
        onSubmitted: (v) =>
            Navigator.pop(dialog, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialog), child: const Text('취소')),
        FilledButton(
          onPressed: () {
            final v = controller.text.trim();
            Navigator.pop(dialog, v.isEmpty ? null : v);
          },
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

Future<void> showFolderActions(BuildContext context, Folder folder) async {
  final repo = AppScope.of(context).repo;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('이름 바꾸기'),
            onTap: () async {
              Navigator.pop(sheet);
              final name = await promptFolderName(context, initial: folder.name);
              if (name != null) await repo.renameFolder(folder.id, name);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('폴더 삭제'),
            subtitle: const Text('안의 메모는 "폴더 없음"으로 옮겨집니다'),
            onTap: () async {
              Navigator.pop(sheet);
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: Text('"${folder.name}" 폴더를 삭제할까요?'),
                  content: const Text('메모는 삭제되지 않습니다.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d, false),
                        child: const Text('취소')),
                    FilledButton(
                        onPressed: () => Navigator.pop(d, true),
                        child: const Text('삭제')),
                  ],
                ),
              );
              if (ok == true) await repo.deleteFolder(folder.id);
            },
          ),
        ],
      ),
    ),
  );
}

/// Lets the user pick a folder (or none) for a note.
Future<void> moveNoteToFolder(BuildContext context, String noteId) async {
  final repo = AppScope.of(context).repo;
  final current = repo.note(noteId)?.folderId;
  // Wrapped so "no folder" (null) is distinguishable from "dismissed".
  final picked = await showModalBottomSheet<({String? id})>(
    context: context,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('폴더 없음'),
            trailing: current == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(sheet, (id: null)),
          ),
          for (final f in repo.folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(f.name),
              trailing: current == f.id ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheet, (id: f.id)),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('새 폴더 만들기'),
            onTap: () async {
              final name = await promptFolderName(sheet);
              if (name == null || !sheet.mounted) return;
              final folder = await repo.createFolder(name);
              if (sheet.mounted) Navigator.pop(sheet, (id: folder.id));
            },
          ),
        ],
      ),
    ),
  );
  if (picked != null) await repo.updateNote(noteId, folderId: picked.id);
}

Future<bool> confirmDeleteNote(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('메모를 삭제할까요?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
        FilledButton(
            onPressed: () => Navigator.pop(d, true), child: const Text('삭제')),
      ],
    ),
  );
  return ok == true;
}

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/models.dart';
import 'folder_dialogs.dart';
import 'note_editor_screen.dart';
import 'settings_screen.dart';

/// Which notes the list shows.
sealed class NoteFilter {
  const NoteFilter();
}

class AllNotes extends NoteFilter {
  const AllNotes();
}

class UnfiledNotes extends NoteFilter {
  const UnfiledNotes();
}

class FolderNotes extends NoteFilter {
  const FolderNotes(this.folderId);
  final String folderId;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  NoteFilter _filter = const AllNotes();
  bool _searching = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.repo, scope.settings]),
      builder: (context, _) {
        final repo = scope.repo;
        final library = scope.settings.libraryEnabled;
        var filter = _filter;
        // Library off, or the selected folder vanished: show everything.
        if (!library ||
            (filter is FolderNotes && repo.folder(filter.folderId) == null)) {
          filter = const AllNotes();
        }
        final notes = switch (filter) {
          AllNotes() => repo.notes(query: _searchController.text),
          UnfiledNotes() =>
            repo.notes(unfiledOnly: true, query: _searchController.text),
          FolderNotes(:final folderId) =>
            repo.notes(folderId: folderId, query: _searchController.text),
        };
        final title = switch (filter) {
          AllNotes() => library ? '모든 메모' : '메모',
          UnfiledNotes() => '폴더 없음',
          FolderNotes(:final folderId) => repo.folder(folderId)!.name,
        };

        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '메모 검색',
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  )
                : Text(title),
            actions: [
              IconButton(
                tooltip: _searching ? '검색 닫기' : '검색',
                icon: Icon(_searching ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _searchController.clear();
                }),
              ),
              IconButton(
                tooltip: '설정',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
          drawer: library
              ? _LibraryDrawer(
                  selected: filter,
                  onSelect: (f) {
                    setState(() => _filter = f);
                    Navigator.of(context).pop();
                  },
                )
              : null,
          body: notes.isEmpty
              ? _EmptyState(searching: _searchController.text.isNotEmpty)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  itemCount: notes.length,
                  itemBuilder: (context, i) => _NoteTile(
                    note: notes[i],
                    folderName: library && filter is AllNotes
                        ? repo.folder(notes[i].folderId ?? '')?.name
                        : null,
                  ),
                ),
          floatingActionButton: FloatingActionButton(
            tooltip: '새 메모',
            onPressed: () async {
              final note = await repo.createNote(
                folderId: filter is FolderNotes ? filter.folderId : null,
              );
              if (!context.mounted) return;
              await openNote(context, note.id);
            },
            child: const Icon(Icons.edit_outlined),
          ),
        );
      },
    );
  }
}

Future<void> openNote(BuildContext context, String id) =>
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: id)),
    );

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searching});
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(searching ? Icons.search_off : Icons.sticky_note_2_outlined,
              size: 56, color: color),
          const SizedBox(height: 12),
          Text(searching ? '검색 결과가 없습니다' : '메모가 없습니다',
              style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note, this.folderName});
  final Note note;
  final String? folderName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = note.plainText.trim().split('\n');
    final title = note.title.trim().isNotEmpty
        ? note.title.trim()
        : (lines.first.trim().isNotEmpty ? lines.first.trim() : '새 메모');
    final preview = note.title.trim().isNotEmpty
        ? note.plainText.trim()
        : lines.skip(1).join(' ').trim();
    final meta = [
      _formatDate(note.updatedAt),
      ?folderName,
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview.isNotEmpty)
              Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(meta,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
        trailing: note.pinned
            ? Icon(Icons.push_pin, size: 18, color: theme.colorScheme.primary)
            : null,
        onTap: () => openNote(context, note.id),
        onLongPress: () => _showNoteActions(context, note),
      ),
    );
  }
}

Future<void> _showNoteActions(BuildContext context, Note note) async {
  final scope = AppScope.of(context);
  final repo = scope.repo;
  final library = scope.settings.libraryEnabled;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(note.pinned ? Icons.push_pin_outlined : Icons.push_pin),
            title: Text(note.pinned ? '고정 해제' : '맨 위에 고정'),
            onTap: () {
              Navigator.pop(sheet);
              repo.updateNote(note.id, pinned: !note.pinned);
            },
          ),
          if (library)
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('폴더로 이동'),
              onTap: () async {
                Navigator.pop(sheet);
                await moveNoteToFolder(context, note.id);
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('삭제'),
            onTap: () async {
              Navigator.pop(sheet);
              if (await confirmDeleteNote(context)) {
                await repo.deleteNote(note.id);
              }
            },
          ),
        ],
      ),
    ),
  );
}

String _formatDate(DateTime d) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${two(d.hour)}:${two(d.minute)}';
  }
  if (d.year == now.year) return '${d.month}월 ${d.day}일';
  return '${d.year}. ${d.month}. ${d.day}.';
}

class _LibraryDrawer extends StatelessWidget {
  const _LibraryDrawer({required this.selected, required this.onSelect});
  final NoteFilter selected;
  final ValueChanged<NoteFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final folders = repo.folders;
    bool isSel(NoteFilter f) => switch ((selected, f)) {
          (AllNotes(), AllNotes()) => true,
          (UnfiledNotes(), UnfiledNotes()) => true,
          (FolderNotes(folderId: final a), FolderNotes(folderId: final b)) =>
            a == b,
          _ => false,
        };

    return NavigationDrawer(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 10),
          child: Text('서재', style: Theme.of(context).textTheme.titleSmall),
        ),
        ListTile(
          leading: const Icon(Icons.notes),
          title: const Text('모든 메모'),
          selected: isSel(const AllNotes()),
          onTap: () => onSelect(const AllNotes()),
        ),
        ListTile(
          leading: const Icon(Icons.inbox_outlined),
          title: const Text('폴더 없음'),
          selected: isSel(const UnfiledNotes()),
          onTap: () => onSelect(const UnfiledNotes()),
        ),
        const Divider(indent: 16, endIndent: 16),
        for (final f in folders)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text('${repo.noteCount(f.id)}'),
            selected: isSel(FolderNotes(f.id)),
            onTap: () => onSelect(FolderNotes(f.id)),
            onLongPress: () => showFolderActions(context, f),
          ),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('새 폴더'),
          onTap: () async {
            final name = await promptFolderName(context);
            if (name != null) await repo.createFolder(name);
          },
        ),
      ],
    );
  }
}

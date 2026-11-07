import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../app_scope.dart';
import '../data/note_repository.dart';
import 'folder_dialogs.dart';
import 'rich_text_toolbar.dart';

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.noteId});
  final String noteId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final NoteRepository _repo;
  late final QuillController _quill;
  late final TextEditingController _title;
  final _editorFocus = FocusNode();
  final _editorScroll = ScrollController();
  StreamSubscription<DocChange>? _docSub;
  Timer? _saveTimer;
  bool _initialized = false;
  bool _deleted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _repo = AppScope.of(context).repo;
    final note = _repo.note(widget.noteId)!;
    _title = TextEditingController(text: note.title)
      ..addListener(_scheduleSave);
    _quill = QuillController(
      document: _loadDocument(note.content),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _docSub = _quill.document.changes.listen((_) => _scheduleSave());
    if (note.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorFocus.requestFocus();
      });
    }
  }

  static Document _loadDocument(String content) {
    if (content.isEmpty) return Document();
    try {
      return Document.fromJson(jsonDecode(content) as List<dynamic>);
    } catch (_) {
      // Corrupt or legacy content: show it as plain text rather than lose it.
      return Document()..insert(0, content);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _save);
  }

  Future<void> _save() async {
    _saveTimer?.cancel();
    if (_deleted) return;
    final plain = _quill.document.toPlainText().trim();
    await _repo.updateNote(
      widget.noteId,
      title: _title.text,
      content: plain.isEmpty ? '' : jsonEncode(_quill.document.toDelta().toJson()),
      plainText: plain,
    );
  }

  /// Saves on leave, and drops the note if it was left empty.
  Future<void> _finish() async {
    await _save();
    final note = _repo.note(widget.noteId);
    if (note != null && note.isEmpty) {
      _deleted = true;
      await _repo.deleteNote(widget.noteId);
    }
  }

  @override
  void dispose() {
    _finish();
    _docSub?.cancel();
    _quill.dispose();
    _title.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.repo, scope.settings]),
      builder: (context, _) {
        final note = _repo.note(widget.noteId);
        final library = scope.settings.libraryEnabled;
        final folder = note?.folderId == null ? null : _repo.folder(note!.folderId!);
        return Scaffold(
          appBar: AppBar(
            title: library
                ? ActionChip(
                    avatar: const Icon(Icons.folder_outlined, size: 18),
                    label: Text(folder?.name ?? '폴더 없음'),
                    onPressed: () => moveNoteToFolder(context, widget.noteId),
                  )
                : null,
            actions: [
              if (note != null)
                IconButton(
                  tooltip: note.pinned ? '고정 해제' : '맨 위에 고정',
                  icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  onPressed: () =>
                      _repo.updateNote(widget.noteId, pinned: !note.pinned),
                ),
              IconButton(
                tooltip: '삭제',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirmDeleteNote(context)) return;
                  _deleted = true;
                  _saveTimer?.cancel();
                  await _repo.deleteNote(widget.noteId);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: TextField(
                    controller: _title,
                    style: Theme.of(context).textTheme.titleLarge,
                    decoration: const InputDecoration(
                      hintText: '제목',
                      border: InputBorder.none,
                    ),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _editorFocus.requestFocus(),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: QuillEditor(
                      controller: _quill,
                      focusNode: _editorFocus,
                      scrollController: _editorScroll,
                      config: const QuillEditorConfig(
                        placeholder: '메모를 입력하세요',
                        padding: EdgeInsets.only(bottom: 24),
                        expands: true,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                RichTextToolbar(controller: _quill),
              ],
            ),
          ),
        );
      },
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../app_scope.dart';
import '../audio/transcriber.dart';
import '../data/attachment_repository.dart';
import '../data/ink.dart';
import '../data/models.dart';
import '../data/note_repository.dart';
import 'folder_dialogs.dart';
import 'ink_canvas.dart';
import 'rich_text_toolbar.dart';
import 'stylus_text_selection.dart';
import 'voice_memo_list.dart';
import 'voice_recorder_sheet.dart';

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen(
      {super.key, required this.noteId, this.startInHandwriting = false});
  final String noteId;

  /// Open on the S Pen handwriting page instead of the text page.
  final bool startInHandwriting;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final NoteRepository _repo;
  late final AttachmentRepository _attachments;
  late final Transcriber _voice;
  late final QuillController _quill;
  late final TextEditingController _title;
  late final InkController _ink;
  final _editorKey = GlobalKey<EditorState>();
  final _editorFocus = FocusNode();
  bool _handwriting = false;
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
    final scope = AppScope.of(context);
    _repo = scope.repo;
    _attachments = scope.attachments;
    _voice = scope.voice;
    final note = _repo.note(widget.noteId)!;
    _title = TextEditingController(text: note.title)
      ..addListener(_scheduleSave);
    _quill = QuillController(
      document: _loadDocument(note.content),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _docSub = _quill.document.changes.listen((_) => _scheduleSave());
    _ink = InkController(InkDrawing.decode(note.ink))
      ..addListener(_onInkChanged);
    // A note that only has handwriting opens on the handwriting page.
    _handwriting = widget.startInHandwriting ||
        (note.ink.isNotEmpty && note.plainText.trim().isEmpty);
    if (note.isEmpty && !_handwriting) {
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

  int _savedInkRevision = 0;

  void _onInkChanged() {
    // Tool/colour changes also notify; only strokes need saving.
    if (_ink.revision == _savedInkRevision) return;
    _savedInkRevision = _ink.revision;
    _scheduleSave();
  }

  void _setHandwriting(bool on) {
    if (on) _editorFocus.unfocus();
    setState(() => _handwriting = on);
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
      ink: _ink.drawing.encode(),
    );
  }

  /// Saves on leave, and drops the note if it was left empty.
  Future<void> _finish() async {
    await _save();
    final note = _repo.note(widget.noteId);
    if (note != null && note.isEmpty && !_attachments.hasAny(widget.noteId)) {
      _deleted = true;
      await _repo.deleteNote(widget.noteId);
    }
  }

  // ---- Voice memos ----------------------------------------------------------

  String? _transcribingId;

  Future<void> _recordVoice() async {
    _editorFocus.unfocus();
    final recorded = await showVoiceRecorder(context);
    if (recorded == null || !mounted) return;
    final attachment = await _attachments.addRecording(
        widget.noteId, recorded.path,
        duration: recorded.duration);
    if (!mounted) return;
    if (AppScope.of(context).settings.autoTranscribe) {
      await _transcribe(attachment);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Turns [a] into text on this device and adds it to the end of the note.
  Future<void> _transcribe(Attachment a) async {
    if (_transcribingId != null || !_attachments.isLocal(a.id)) return;
    final availability = await _voice.availability();
    if (availability != TranscribeAvailability.ok) {
      _snack(availability.message);
      return;
    }
    if (!mounted) return;
    setState(() => _transcribingId = a.id);
    final soFar = ValueNotifier<String>('');
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        title: const Text('받아쓰는 중'),
        content: ValueListenableBuilder<String>(
          valueListenable: soFar,
          builder: (_, text, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(text.isEmpty ? '기기 안에서 글자로 바꾸고 있습니다. 인터넷은 쓰지 않습니다.' : text,
                  maxLines: 8, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _voice.cancel, child: const Text('취소')),
        ],
      ),
    );
    String? text;
    try {
      text = await _voice.transcribe(_attachments.audioPath(a.id),
          onSegment: (t) => soFar.value = t);
    } on TranscribeException catch (e) {
      if (e.code != 'cancelled') _snack(e.message);
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() => _transcribingId = null);
      }
      await dialog;
      soFar.dispose();
    }
    if (text == null || !mounted) return;
    if (text.isEmpty) {
      _snack('녹음에서 알아들을 수 있는 말이 없었습니다.');
      return;
    }
    _appendText('🎙 음성 메모 (${formatDuration(a.duration)})\n$text');
  }

  void _appendText(String text) {
    final doc = _quill.document;
    final end = doc.length - 1; // before the document's final newline
    final insert = doc.toPlainText().trim().isEmpty ? text : '\n$text';
    _quill.replaceText(end, 0, insert,
        TextSelection.collapsed(offset: end + insert.length));
    _scheduleSave();
  }

  @override
  void dispose() {
    _finish();
    _docSub?.cancel();
    _quill.dispose();
    _ink.dispose();
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
              IconButton(
                tooltip: '음성 메모 녹음',
                icon: const Icon(Icons.mic_none),
                onPressed: _transcribingId == null ? _recordVoice : null,
              ),
              IconButton(
                tooltip: _handwriting ? '키보드로 쓰기' : 'S펜 손글씨',
                icon: Icon(
                    _handwriting ? Icons.keyboard_outlined : Icons.draw_outlined),
                onPressed: () => _setHandwriting(!_handwriting),
              ),
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
                  await _attachments.deleteForNote(widget.noteId);
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
                VoiceMemoList(
                  noteId: widget.noteId,
                  transcribingId: _transcribingId,
                  onTranscribe: _transcribe,
                ),
                if (_handwriting) ...[
                  Expanded(child: InkCanvas(controller: _ink)),
                  const Divider(height: 1),
                  InkToolbar(controller: _ink),
                ] else ...[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: StylusTextSelection(
                        editorKey: _editorKey,
                        focusNode: _editorFocus,
                        child: QuillEditor(
                          controller: _quill,
                          focusNode: _editorFocus,
                          scrollController: _editorScroll,
                          config: QuillEditorConfig(
                            editorKey: _editorKey,
                            placeholder: '메모를 입력하세요',
                            padding: const EdgeInsets.only(bottom: 24),
                            expands: true,
                            onTapOutside: keepFocusForPenOnTapOutside,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  RichTextToolbar(controller: _quill),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

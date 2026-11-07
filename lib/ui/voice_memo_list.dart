import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/models.dart';
import 'voice_recorder_sheet.dart';

/// The recordings attached to a note, shown above the text in the editor.
class VoiceMemoList extends StatefulWidget {
  const VoiceMemoList({
    super.key,
    required this.noteId,
    required this.onTranscribe,
    this.transcribingId,
  });

  final String noteId;
  final void Function(Attachment) onTranscribe;

  /// Recording currently being transcribed, if any.
  final String? transcribingId;

  @override
  State<VoiceMemoList> createState() => _VoiceMemoListState();
}

class _VoiceMemoListState extends State<VoiceMemoList> {
  // Created on first play, so opening a note doesn't start the audio engine.
  AudioPlayer? _audio;
  final _subs = <StreamSubscription<Object?>>[];
  String? _playingId;
  bool _playing = false;
  Duration _position = Duration.zero;

  AudioPlayer get _player => _audio ??= _createPlayer();

  AudioPlayer _createPlayer() {
    final player = AudioPlayer();
    _subs
      ..add(player.onPositionChanged.listen((d) {
        if (mounted) setState(() => _position = d);
      }))
      ..add(player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _playing = s == PlayerState.playing);
      }))
      ..add(player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _playing = false;
            _position = Duration.zero;
            _playingId = null;
          });
        }
      }));
    return player;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _audio?.dispose();
    super.dispose();
  }

  Future<void> _toggle(Attachment a, String path) async {
    if (_playingId == a.id) {
      _playing ? await _player.pause() : await _player.resume();
      return;
    }
    await _player.stop();
    setState(() {
      _playingId = a.id;
      _position = Duration.zero;
    });
    await _player.play(DeviceFileSource(path, mimeType: a.mime));
  }

  Future<void> _delete(Attachment a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('음성 메모 삭제'),
        content: const Text('녹음을 모든 기기에서 삭제합니다. 받아쓴 글자는 메모에 남습니다.'),
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
    if (ok != true || !mounted) return;
    if (_playingId == a.id) {
      await _audio?.stop();
      _playingId = null;
    }
    if (!mounted) return;
    await AppScope.of(context).attachments.delete(a.id);
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).attachments;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final items = repo.forNote(widget.noteId);
        if (items.isEmpty) return const SizedBox.shrink();
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final (i, a) in items.indexed)
                _tile(context, a, i + 1, repo.isLocal(a.id),
                    repo.audioPath(a.id)),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(BuildContext context, Attachment a, int number, bool local,
      String path) {
    final theme = Theme.of(context);
    final active = _playingId == a.id;
    final transcribing = widget.transcribingId == a.id;
    final total = a.duration;
    final progress = active && total.inMilliseconds > 0
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final subtitle = !local
        ? '다른 기기에 저장된 음성 · 글자만 동기화'
        : transcribing
            ? '받아쓰는 중…'
            : active
                ? '${formatDuration(_position)} / ${formatDuration(total)}'
                : formatDuration(total);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: IconButton(
              tooltip: active && _playing ? '일시정지' : '재생',
              icon: Icon(!local
                  ? Icons.cloud_off_outlined
                  : active && _playing
                      ? Icons.pause_circle
                      : Icons.play_circle),
              iconSize: 32,
              color: theme.colorScheme.primary,
              onPressed: local ? () => _toggle(a, path) : null,
            ),
            title: Text('음성 메모 $number'),
            subtitle: Text(subtitle),
            trailing: PopupMenuButton<String>(
              tooltip: '음성 메모 메뉴',
              onSelected: (v) {
                if (v == 'transcribe') widget.onTranscribe(a);
                if (v == 'delete') _delete(a);
              },
              itemBuilder: (_) => [
                if (local)
                  PopupMenuItem(
                    value: 'transcribe',
                    enabled: widget.transcribingId == null,
                    child: const Text('받아쓰기 (글자로 바꾸기)'),
                  ),
                const PopupMenuItem(value: 'delete', child: Text('삭제')),
              ],
            ),
          ),
          if (active)
            LinearProgressIndicator(value: progress, minHeight: 2),
        ],
      ),
    );
  }
}

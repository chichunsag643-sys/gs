import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import '../app_scope.dart';

/// A finished recording, not yet attached to a note.
class RecordedAudio {
  const RecordedAudio(this.path, this.duration);
  final String path;
  final Duration duration;
}

/// AAC-LC, mono, 64 kbps: about 0.5 MB per minute, plays everywhere
/// (Android, iPhone, Mac).
const voiceMemoConfig = RecordConfig(
  encoder: AudioEncoder.aacLc,
  bitRate: 64000,
  sampleRate: 44100,
  numChannels: 1,
);

/// Opens the recorder. Returns null if cancelled or the microphone is not
/// allowed.
Future<RecordedAudio?> showVoiceRecorder(BuildContext context) async {
  final recorder = AudioRecorder();
  try {
    if (!await recorder.hasPermission()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('음성 메모를 녹음하려면 마이크 권한을 허용해 주세요.'),
        ));
      }
      return null;
    }
    if (!context.mounted) return null;
    return await showModalBottomSheet<RecordedAudio>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _RecorderSheet(recorder: recorder),
    );
  } finally {
    await recorder.dispose();
  }
}

String formatDuration(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

class _RecorderSheet extends StatefulWidget {
  const _RecorderSheet({required this.recorder});
  final AudioRecorder recorder;

  @override
  State<_RecorderSheet> createState() => _RecorderSheetState();
}

class _RecorderSheetState extends State<_RecorderSheet> {
  final _clock = Stopwatch();
  Timer? _tick;
  StreamSubscription<Amplitude>? _amp;
  double _level = 0;
  bool _started = false;
  bool _paused = false;
  bool _done = false;
  String? _error;
  String? _path;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final scope = AppScope.of(context);
    final dir = scope.attachments.dir;
    _path = p.join(
        dir.path, 'recording-${DateTime.now().millisecondsSinceEpoch}.m4a');
    try {
      await scope.voice.recordingStarted();
      await widget.recorder.start(voiceMemoConfig, path: _path!);
    } catch (e) {
      await scope.voice.recordingStopped();
      if (mounted) setState(() => _error = '녹음을 시작할 수 없습니다.');
      return;
    }
    _clock.start();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    _amp = widget.recorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((a) {
      // dBFS: about -45 (quiet room) .. 0 (loud).
      final v = ((a.current + 45) / 45).clamp(0.0, 1.0);
      if (mounted) setState(() => _level = v);
    });
    if (mounted) setState(() => _started = true);
  }

  Future<void> _togglePause() async {
    if (_paused) {
      await widget.recorder.resume();
      _clock.start();
    } else {
      await widget.recorder.pause();
      _clock.stop();
    }
    setState(() {
      _paused = !_paused;
      _level = 0;
    });
  }

  Future<void> _finish({required bool keep}) async {
    if (_done) return;
    _done = true;
    final voice = AppScope.of(context).voice;
    _clock.stop();
    _tick?.cancel();
    await _amp?.cancel();
    String? path;
    if (_started) {
      if (keep) {
        path = await widget.recorder.stop();
      } else {
        await widget.recorder.cancel();
      }
    }
    await voice.recordingStopped();
    if (!mounted) return;
    if (keep && path != null && _clock.elapsed >= const Duration(seconds: 1)) {
      Navigator.of(context).pop(RecordedAudio(path, _clock.elapsed));
    } else {
      if (path != null) {
        try {
          await File(path).delete();
        } on FileSystemException {
          // Already gone.
        }
      }
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _amp?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(keep: true);
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error ??
                    (!_started
                        ? '준비 중…'
                        : _paused
                            ? '일시정지됨'
                            : '녹음 중'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(formatDuration(_clock.elapsed),
                  style: theme.textTheme.displaySmall
                      ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _level,
                  minHeight: 8,
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text('녹음은 이 기기에만 저장됩니다. 화면이 꺼져도 계속 녹음됩니다.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.outlined(
                    tooltip: '취소',
                    iconSize: 28,
                    icon: const Icon(Icons.close),
                    onPressed: () => _finish(keep: false),
                  ),
                  IconButton.filled(
                    tooltip: '녹음 마치기',
                    iconSize: 40,
                    style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError),
                    icon: const Icon(Icons.stop),
                    onPressed: _started ? () => _finish(keep: true) : null,
                  ),
                  IconButton.outlined(
                    tooltip: _paused ? '이어서 녹음' : '일시정지',
                    iconSize: 28,
                    icon: Icon(_paused ? Icons.mic : Icons.pause),
                    onPressed: _started ? _togglePause : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

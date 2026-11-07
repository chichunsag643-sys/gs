/// Sync-ready records.
///
/// Every record has:
/// * a globally unique [id] (UUID v4), so devices can create records offline
///   without colliding;
/// * an [hlc] stamp of the last change (see `hlc.dart`) and the [deviceId]
///   that made it, so later sync can merge with last-writer-wins;
/// * a [deleted] tombstone instead of a hard delete, so a delete on one
///   device can propagate to the others.
library;

class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    required this.deviceId,
    this.deleted = false,
  });

  final String id;
  final String name;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String hlc;
  final String deviceId;
  final bool deleted;

  Folder copyWith({
    String? name,
    int? sortOrder,
    DateTime? updatedAt,
    String? hlc,
    String? deviceId,
    bool? deleted,
  }) =>
      Folder(
        id: id,
        name: name ?? this.name,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        hlc: hlc ?? this.hlc,
        deviceId: deviceId ?? this.deviceId,
        deleted: deleted ?? this.deleted,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'sort_order': sortOrder,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'hlc': hlc,
        'device_id': deviceId,
        'deleted': deleted ? 1 : 0,
      };

  factory Folder.fromRow(Map<String, Object?> row) => Folder(
        id: row['id'] as String,
        name: row['name'] as String,
        sortOrder: row['sort_order'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
        hlc: row['hlc'] as String,
        deviceId: row['device_id'] as String,
        deleted: (row['deleted'] as int) == 1,
      );
}

class Note {
  const Note({
    required this.id,
    required this.folderId,
    required this.title,
    required this.content,
    required this.plainText,
    this.ink = '',
    required this.pinned,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    required this.deviceId,
    this.deleted = false,
  });

  final String id;

  /// Folder in the library ("서재"). Null means not filed in any folder.
  final String? folderId;
  final String title;

  /// Rich text as a Quill Delta JSON string. Empty string means empty note.
  final String content;

  /// Plain-text copy of [content], used for previews and search.
  final String plainText;

  /// S Pen handwriting as JSON strokes (see `ink.dart`). Empty if none.
  final String ink;
  final bool pinned;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String hlc;
  final String deviceId;
  final bool deleted;

  bool get isEmpty =>
      title.trim().isEmpty && plainText.trim().isEmpty && ink.isEmpty;

  Note copyWith({
    Object? folderId = _keep,
    String? title,
    String? content,
    String? plainText,
    String? ink,
    bool? pinned,
    DateTime? updatedAt,
    String? hlc,
    String? deviceId,
    bool? deleted,
  }) =>
      Note(
        id: id,
        folderId:
            identical(folderId, _keep) ? this.folderId : folderId as String?,
        title: title ?? this.title,
        content: content ?? this.content,
        plainText: plainText ?? this.plainText,
        ink: ink ?? this.ink,
        pinned: pinned ?? this.pinned,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        hlc: hlc ?? this.hlc,
        deviceId: deviceId ?? this.deviceId,
        deleted: deleted ?? this.deleted,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'folder_id': folderId,
        'title': title,
        'content': content,
        'plain_text': plainText,
        'ink': ink,
        'pinned': pinned ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'hlc': hlc,
        'device_id': deviceId,
        'deleted': deleted ? 1 : 0,
      };

  factory Note.fromRow(Map<String, Object?> row) => Note(
        id: row['id'] as String,
        folderId: row['folder_id'] as String?,
        title: row['title'] as String,
        content: row['content'] as String,
        plainText: row['plain_text'] as String,
        ink: (row['ink'] as String?) ?? '',
        pinned: (row['pinned'] as int) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
        hlc: row['hlc'] as String,
        deviceId: row['device_id'] as String,
        deleted: (row['deleted'] as int) == 1,
      );
}

const Object _keep = Object();

/// A voice recording attached to a note. The audio is stored as a file
/// outside the database (see `attachment_repository.dart`); this record is
/// the synced metadata.
class Attachment {
  const Attachment({
    required this.id,
    required this.noteId,
    this.kind = kindAudio,
    this.mime = 'audio/mp4',
    required this.durationMs,
    required this.sizeBytes,
    required this.sha256,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    required this.deviceId,
    this.deleted = false,
  });

  static const kindAudio = 'audio';

  final String id;
  final String noteId;
  final String kind;
  final String mime;
  final int durationMs;
  final int sizeBytes;

  /// Hex SHA-256 of the audio file, so a copied file can be verified.
  final String sha256;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String hlc;
  final String deviceId;
  final bool deleted;

  Duration get duration => Duration(milliseconds: durationMs);

  Attachment copyWith({
    DateTime? updatedAt,
    String? hlc,
    String? deviceId,
    bool? deleted,
  }) =>
      Attachment(
        id: id,
        noteId: noteId,
        kind: kind,
        mime: mime,
        durationMs: durationMs,
        sizeBytes: sizeBytes,
        sha256: sha256,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        hlc: hlc ?? this.hlc,
        deviceId: deviceId ?? this.deviceId,
        deleted: deleted ?? this.deleted,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'note_id': noteId,
        'kind': kind,
        'mime': mime,
        'duration_ms': durationMs,
        'size_bytes': sizeBytes,
        'sha256': sha256,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'hlc': hlc,
        'device_id': deviceId,
        'deleted': deleted ? 1 : 0,
      };

  factory Attachment.fromRow(Map<String, Object?> row) => Attachment(
        id: row['id'] as String,
        noteId: row['note_id'] as String,
        kind: row['kind'] as String,
        mime: row['mime'] as String,
        durationMs: row['duration_ms'] as int,
        sizeBytes: row['size_bytes'] as int,
        sha256: row['sha256'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
        hlc: row['hlc'] as String,
        deviceId: row['device_id'] as String,
        deleted: (row['deleted'] as int) == 1,
      );
}

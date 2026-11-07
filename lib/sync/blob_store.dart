import 'dart:io';

/// Files attached to notes (voice memos), which travel separately from the
/// record rows. Their metadata always syncs; the bytes only go to devices
/// whose owner chose to keep them ([wantsBlobs]).
abstract class SyncBlobStore {
  /// Whether this device downloads attachment files from its peers.
  bool get wantsBlobs;

  Future<bool> hasBlob(String id);

  /// The stored file, or null if this device does not have it.
  Future<File?> blobFile(String id);

  /// Stores bytes received from a peer. Implementations must check
  /// [sha256] (hex) before keeping them.
  Future<void> importBlob(String id, List<int> bytes, String sha256);
}

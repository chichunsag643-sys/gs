/// Hybrid Logical Clock.
///
/// Every change to a note or folder is stamped with an HLC value. When sync
/// is added later, two devices compare stamps to decide which edit wins
/// (last-writer-wins per record), even if their wall clocks disagree a bit.
///
/// The string form sorts lexicographically in causal order:
/// `<millis, 15 digits>-<counter, 4 hex>-<nodeId>`.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.nodeId);

  final int millis;
  final int counter;
  final String nodeId;

  static const _maxCounter = 0xFFFF;

  factory Hlc.zero(String nodeId) => Hlc(0, 0, nodeId);

  factory Hlc.parse(String value) {
    final first = value.indexOf('-');
    final second = value.indexOf('-', first + 1);
    if (first < 0 || second < 0) {
      throw FormatException('Invalid HLC', value);
    }
    return Hlc(
      int.parse(value.substring(0, first)),
      int.parse(value.substring(first + 1, second), radix: 16),
      value.substring(second + 1),
    );
  }

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(millis, counter, nodeId);

  @override
  String toString() =>
      '${millis.toString().padLeft(15, '0')}-'
      '${counter.toRadixString(16).padLeft(4, '0')}-$nodeId';
}

/// Issues monotonically increasing [Hlc] stamps for this device.
class HlcClock {
  HlcClock(this.nodeId, {Hlc? last, int Function()? wallClock})
      : _last = last ?? Hlc.zero(nodeId),
        _wallClock = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String nodeId;
  final int Function() _wallClock;
  Hlc _last;

  Hlc get last => _last;

  /// Stamp for a local change.
  Hlc now() {
    final wall = _wallClock();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0, nodeId);
    } else {
      _last = Hlc(_last.millis, _bump(_last.counter), nodeId);
    }
    return _last;
  }

  /// Merge a stamp received from another device so that our next local stamp
  /// is ordered after it.
  Hlc receive(Hlc remote) {
    final wall = _wallClock();
    final maxMillis = [wall, _last.millis, remote.millis].reduce(
      (a, b) => a > b ? a : b,
    );
    int counter;
    if (maxMillis == _last.millis && maxMillis == remote.millis) {
      counter = _bump(
        _last.counter > remote.counter ? _last.counter : remote.counter,
      );
    } else if (maxMillis == _last.millis) {
      counter = _bump(_last.counter);
    } else if (maxMillis == remote.millis) {
      counter = _bump(remote.counter);
    } else {
      counter = 0;
    }
    _last = Hlc(maxMillis, counter, nodeId);
    return _last;
  }

  static int _bump(int counter) {
    if (counter >= Hlc._maxCounter) {
      throw StateError('HLC counter overflow');
    }
    return counter + 1;
  }
}

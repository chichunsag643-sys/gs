import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Which key sealed a frame.
enum FrameKey {
  /// The sync group key shared by all paired devices.
  group(1),

  /// The one-time key shown in a pairing QR code.
  pairing(2);

  const FrameKey(this.code);
  final int code;

  static FrameKey? fromCode(int code) =>
      values.where((k) => k.code == code).firstOrNull;
}

class Frame {
  const Frame(this.key, this.payload);
  final FrameKey key;
  final List<int> payload;
}

/// Frames are `[key: 1 byte][length: 4 bytes big-endian][payload]`.
/// Each TCP connection carries one request frame and one response frame.
const maxFrameBytes = 64 * 1024 * 1024;

Future<void> writeFrame(Socket socket, Frame frame) async {
  final header = ByteData(5)
    ..setUint8(0, frame.key.code)
    ..setUint32(1, frame.payload.length);
  socket.add(header.buffer.asUint8List());
  socket.add(frame.payload);
  await socket.flush();
}

/// Reads exactly one frame from [stream].
Future<Frame> readFrame(Stream<Uint8List> stream, {Duration? timeout}) {
  final completer = Completer<Frame>();
  final buffer = BytesBuilder(copy: false);
  int? need;
  FrameKey? key;
  late StreamSubscription<Uint8List> sub;

  void fail(Object error) {
    if (completer.isCompleted) return;
    completer.completeError(error);
    sub.cancel();
  }

  sub = stream.listen(
    (chunk) {
      if (completer.isCompleted) return;
      buffer.add(chunk);
      if (need == null && buffer.length >= 5) {
        final bytes = buffer.toBytes();
        final header = ByteData.sublistView(bytes, 0, 5);
        key = FrameKey.fromCode(header.getUint8(0));
        final length = header.getUint32(1);
        if (key == null || length > maxFrameBytes) {
          fail(const FormatException('Bad frame header'));
          return;
        }
        need = 5 + length;
        buffer.clear();
        buffer.add(bytes);
      }
      if (need != null && buffer.length >= need!) {
        final bytes = buffer.toBytes();
        completer.complete(Frame(key!, Uint8List.sublistView(bytes, 5, need)));
        sub.cancel();
      }
    },
    onError: fail,
    onDone: () => fail(const SocketException('Connection closed early')),
    cancelOnError: true,
  );
  final future = completer.future;
  return timeout == null ? future : future.timeout(timeout, onTimeout: () {
    sub.cancel();
    throw TimeoutException('No reply', timeout);
  });
}

/// Sends one frame to [host]:[port] and waits for the reply.
Future<Frame> exchange(
  String host,
  int port,
  Frame request, {
  Duration connectTimeout = const Duration(seconds: 3),
  Duration replyTimeout = const Duration(seconds: 30),
}) async {
  final socket = await Socket.connect(host, port, timeout: connectTimeout);
  try {
    await writeFrame(socket, request);
    return await readFrame(socket, timeout: replyTimeout);
  } finally {
    socket.destroy();
  }
}

/// IPv4 addresses of this device that peers might reach, LAN first and
/// Tailscale (100.64.0.0/10) last.
Future<List<String>> localAddresses() async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
  } on SocketException {
    return const [];
  }
  final all = [
    for (final i in interfaces)
      for (final a in i.addresses)
        if (!a.isLoopback && !a.isLinkLocal) a.address,
  ];
  all.sort((a, b) {
    final ta = isTailscaleAddress(a) ? 1 : 0;
    final tb = isTailscaleAddress(b) ? 1 : 0;
    return ta != tb ? ta - tb : a.compareTo(b);
  });
  return all;
}

/// Tailscale gives every device an address in 100.64.0.0/10, and MagicDNS
/// names end in `.ts.net`.
bool isTailscaleAddress(String address) {
  if (address.endsWith('.ts.net')) return true;
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b < 128;
}

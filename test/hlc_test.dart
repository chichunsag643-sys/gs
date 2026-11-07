import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/data/hlc.dart';

void main() {
  test('string form round-trips and sorts like compareTo', () {
    const a = Hlc(1700000000000, 3, 'aaa');
    const b = Hlc(1700000000000, 10, 'aaa');
    const c = Hlc(1700000000001, 0, 'aaa');
    expect(Hlc.parse(a.toString()), a);
    expect(a.toString().compareTo(b.toString()), lessThan(0));
    expect(b.toString().compareTo(c.toString()), lessThan(0));
    expect(Hlc.parse('000001700000000000-000a-node-with-dash').nodeId,
        'node-with-dash');
  });

  test('now() is monotonic even if the wall clock goes backwards', () {
    var wall = 1000;
    final clock = HlcClock('n', wallClock: () => wall);
    final first = clock.now();
    wall = 500;
    final second = clock.now();
    expect(second > first, isTrue);
    expect(second.millis, 1000);
    expect(second.counter, 1);
  });

  test('receive() orders the next local stamp after the remote one', () {
    final clock = HlcClock('local', wallClock: () => 1000);
    clock.now();
    final remote = const Hlc(5000, 7, 'remote');
    clock.receive(remote);
    final next = clock.now();
    expect(next > remote, isTrue);
  });
}

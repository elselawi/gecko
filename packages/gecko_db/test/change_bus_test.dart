import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test('publish emits one coalesced change set per batch', () async {
    final bus = ChangeBus();
    final emissions = <ChangeSet>[];
    final sub = bus.stream.listen(emissions.add);

    bus.publish([
      const Change(table: 'a', key: 1, kind: ChangeKind.put),
      const Change(table: 'a', key: 2, kind: ChangeKind.put),
    ]);
    bus.publish([const Change(table: 'b', key: 1, kind: ChangeKind.delete)]);

    await Future<void>.delayed(Duration.zero);
    expect(emissions, hasLength(2));
    expect(emissions[0].changes, hasLength(2));
    expect(emissions[1].changes, hasLength(1));
    await sub.cancel();
    await bus.close();
  });

  test(
    'changes to the same key within a batch coalesce to final state',
    () async {
      final bus = ChangeBus();
      final emissions = <ChangeSet>[];
      final sub = bus.stream.listen(emissions.add);

      // put then delete the same key in one batch → final state is delete.
      bus.publish([
        const Change(table: 'a', key: 1, kind: ChangeKind.put),
        const Change(table: 'a', key: 1, kind: ChangeKind.delete),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.single.changes, hasLength(1));
      expect(emissions.single.changes.single.kind, ChangeKind.delete);
      await sub.cancel();
      await bus.close();
    },
  );

  test('sequence numbers are monotonically increasing', () async {
    final bus = ChangeBus();
    final seqs = <int>[];
    final sub = bus.stream.listen((set) => seqs.add(set.sequence!));
    bus.publish([const Change(table: 'a', key: 1, kind: ChangeKind.put)]);
    bus.publish([const Change(table: 'a', key: 2, kind: ChangeKind.put)]);
    await Future<void>.delayed(Duration.zero);
    expect(seqs, [1, 2]);
    expect(seqs[0].isFinite, isTrue);
    await sub.cancel();
    await bus.close();
  });

  test('publish after close is a no-op (returns current seq)', () async {
    final bus = ChangeBus();
    await bus.close();
    expect(bus.isClosed, isTrue);
    expect(
      bus.publish([const Change(table: 'a', key: 1, kind: ChangeKind.put)]),
      0,
    );
  });

  test('lastSequence advances with each publish', () async {
    final bus = ChangeBus();
    expect(bus.lastSequence, 0);
    bus.publish([const Change(table: 'a', key: 1, kind: ChangeKind.put)]);
    expect(bus.lastSequence, 1);
    await bus.close();
  });

  test('ChangeBusOverflowError toString includes sequence', () {
    final error = ChangeBusOverflowError(7);
    expect(error.sequence, 7);
    expect(error.toString(), contains('7'));
    expect(error, isA<Error>());
  });

  test('sequences stream emits published sequence numbers', () async {
    final bus = ChangeBus();
    final seqs = <int>[];
    final sub = bus.sequences.listen(seqs.add);
    bus.publish([const Change(table: 'a', key: 1, kind: ChangeKind.put)]);
    bus.notifySequence(bus.lastSequence);
    await Future<void>.delayed(Duration.zero);
    expect(seqs, isNotEmpty);
    expect(seqs.last, 1);
    await sub.cancel();
    await bus.close();
  });

  test('notifySequence after close is a no-op', () async {
    final bus = ChangeBus();
    await bus.close();
    bus.notifySequence(5); // must not throw
    expect(bus.isClosed, isTrue);
  });

  test('a paused subscriber overflows after maxBuffered and drops the window',
      () async {
    final bus = ChangeBus(maxBuffered: 3);
    final events = <Object>[];
    final sub = bus.stream.listen(events.add, onError: (Object e) => events.add(e));
    await Future<void>.delayed(Duration.zero); // let the subscription attach
    sub.pause();
    for (var i = 0; i < 10; i++) {
      bus.publish([Change(table: 'a', key: i, kind: ChangeKind.put)]);
    }
    await Future<void>.delayed(Duration.zero);
    sub.resume();
    await Future<void>.delayed(Duration.zero);
    // Exactly one overflow error; the buffered window is dropped entirely.
    expect(events.whereType<ChangeBusOverflowError>(), hasLength(1));
    expect(
      events.whereType<ChangeBusOverflowError>().single.sequence,
      greaterThanOrEqualTo(4),
    );
    expect(events.whereType<ChangeSet>(), isEmpty);
    await sub.cancel();
    await bus.close();
  });

  test('a paused subscriber under the bound flushes buffered events on resume',
      () async {
    final bus = ChangeBus(maxBuffered: 10);
    final events = <ChangeSet>[];
    final sub = bus.stream.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    sub.pause();
    for (var i = 0; i < 3; i++) {
      bus.publish([Change(table: 'a', key: i, kind: ChangeKind.put)]);
    }
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty, reason: 'paused events are buffered, not delivered');
    sub.resume();
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(3), reason: 'buffered events flush in order');
    expect(
      [for (final set in events) set.sequence],
      [1, 2, 3],
      reason: 'publish order is preserved through the pause',
    );
    await sub.cancel();
    await bus.close();
  });

  test('a subscriber that keeps up receives every event without throttling',
      () async {
    final bus = ChangeBus(maxBuffered: 2);
    final events = <ChangeSet>[];
    final sub = bus.stream.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 5; i++) {
      bus.publish([Change(table: 'a', key: i, kind: ChangeKind.put)]);
    }
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(5));
    await sub.cancel();
    await bus.close();
  });
}

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
}

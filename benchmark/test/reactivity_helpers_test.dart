// Unit tests for the reactivity benchmark's delivery-verification helpers
// (benchmark/reactivity_helpers.dart). These guard the contract that the
// benchmark relies on: exactly one counter increment per delivered event, and
// a hard, descriptive failure when a subscription never emits.
import 'dart:async';

import 'package:test/test.dart';

import '../reactivity_helpers.dart';

void main() {
  test('one stream event increments the counter exactly once', () async {
    final controller = StreamController<int>();
    final counter = EmissionCounter<int>(controller.stream);
    expect(counter.count, 0);

    controller.add(1);
    await Future<void>.delayed(Duration.zero);
    expect(counter.count, 1, reason: 'one delivered event == one increment');

    controller.add(2);
    controller.add(3);
    await Future<void>.delayed(Duration.zero);
    expect(counter.count, 3, reason: 'three delivered events == three increments');

    await controller.close();
    await counter.cancel();
  });

  test('an unlistened stream never increments the counter', () async {
    final controller = StreamController<int>();
    final counter = EmissionCounter<int>(controller.stream);
    await Future<void>.delayed(Duration.zero);
    expect(counter.count, 0);
    await controller.close();
    await counter.cancel();
  });

  test('waitForEmissions returns once every counter reaches the minimum',
      () async {
    final a = StreamController<int>();
    final b = StreamController<int>();
    final counters = [EmissionCounter<int>(a.stream), EmissionCounter<int>(b.stream)];

    a.add(1);
    await Future<void>.delayed(Duration.zero);
    var completed = false;
    final pending =
        waitForEmissions(counters, 1, timeout: const Duration(seconds: 5))
            .then((_) {
      completed = true;
    });
    // Only `a` has emitted: the wait must still be pending for `b`.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(counters.first.count, 1);
    expect(counters.last.count, 0);
    expect(completed, isFalse, reason: 'must still be waiting for b');

    // Once `b` emits, the wait resolves.
    b.add(1);
    await pending;
    expect(completed, isTrue);
    expect(counters.every((c) => c.count >= 1), isTrue);

    for (final c in counters) {
      await c.cancel();
    }
    await a.close();
    await b.close();
  });

  test('a missing initial emission fails the helper with a descriptive error',
      () async {
    // A controller that never emits: waitForInitialEmissions must throw.
    final never = StreamController<int>();
    final counters = [EmissionCounter<int>(never.stream)];
    await expectLater(
      waitForInitialEmissions(counters, timeout: const Duration(milliseconds: 100)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('timed out waiting for emissions'),
        ),
      ),
    );
    await never.close();
    await counters.single.cancel();
  });
}

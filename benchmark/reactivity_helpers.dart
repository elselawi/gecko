// Delivery-verification helpers for the reactivity benchmark
// (benchmark/reactivity.dart).
//
// Kept importable (not private to reactivity.dart) so the contract — one
// counter increment per delivered event, and a hard timeout when a
// subscription never emits — can be unit-tested in benchmark/test/ without
// spinning up a database and native worker.
library;

import 'dart:async';

/// Counts emissions from a live subscription, incrementing exactly once per
/// delivered event. The reactivity benchmark uses these counters to prove a
/// subscription actually delivered before it times an update, instead of
/// measuring a silent timeout.
class EmissionCounter<T> {
  EmissionCounter(Stream<T> stream) {
    _sub = stream.listen((_) {
      count++;
    });
  }

  late final StreamSubscription<T> _sub;
  int count = 0;

  Future<void> cancel() => _sub.cancel();
}

/// Waits until every entry in [counters] has emitted at least [min] events.
///
/// Throws a descriptive [StateError] on timeout rather than silently
/// continuing with an unverified measurement. This is the failure mode the
/// reactivity benchmark relies on: a missing initial emission (or a missing
/// post-write emission) must fail loudly, never quietly skew a latency.
Future<void> waitForEmissions(
  List<EmissionCounter<Object?>> counters,
  int min, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final sw = Stopwatch()..start();
  while (counters.any((c) => c.count < min)) {
    if (sw.elapsed > timeout) {
      final pending = [
        for (final c in counters)
          if (c.count < min) 'count ${c.count} < $min',
      ].join(', ');
      throw StateError('timed out waiting for emissions: $pending');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Waits until every entry in [counters] has delivered its initial emission.
Future<void> waitForInitialEmissions(
  List<EmissionCounter<Object?>> counters, {
  Duration timeout = const Duration(seconds: 10),
}) {
  return waitForEmissions(counters, 1, timeout: timeout);
}

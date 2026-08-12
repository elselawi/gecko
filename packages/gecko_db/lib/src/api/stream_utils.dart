/// Opt-in stream utilities.
library;

import 'dart:async';

/// Wraps [source] in latest-state mode: events produced within a single
/// event-loop turn are collapsed into one emission of the latest event.
///
/// The first event of a burst and the final state are always delivered;
/// intermediate events are dropped, so a slow listener never accumulates a
/// queue of redundant snapshots. This is opt-in — the default stream keeps its
/// current event-delivery semantics.
Stream<T> latestStateOnly<T>(Stream<T> source) {
  late StreamController<T> controller;
  StreamSubscription<T>? sub;
  var scheduled = false;
  var hasPending = false;
  T? pending;

  void deliver() {
    scheduled = false;
    if (!hasPending) return;
    hasPending = false;
    final event = pending;
    pending = null;
    if (event != null) controller.add(event);
  }

  controller = StreamController<T>(
    onListen: () {
      sub = source.listen(
        (event) {
          pending = event;
          hasPending = true;
          if (!scheduled) {
            scheduled = true;
            scheduleMicrotask(deliver);
          }
        },
        onError: (Object e, StackTrace st) => controller.addError(e, st),
        onDone: () {
          if (hasPending && !scheduled) {
            scheduled = true;
            scheduleMicrotask(deliver);
          }
          scheduleMicrotask(() {
            if (!controller.isClosed) controller.close();
          });
        },
      );
    },
    onPause: () => sub?.pause(),
    onResume: () {
      sub?.resume();
      if (hasPending && !scheduled) {
        scheduled = true;
        scheduleMicrotask(deliver);
      }
    },
    onCancel: () => sub?.cancel(),
  );
  return controller.stream;
}

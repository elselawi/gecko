/// change bus.
///
/// A single-writer broadcast hub for change events. The engine publishes one
/// coalesced [`ChangeSet`] per committed batch; the sequence number is assigned
/// monotonically at publish time so `database.watchAll()` consumers can track
/// exactly which changes they have seen (feeds 's sync interface).
library;

import 'dart:async';

import '../api/change.dart';

/// Thrown to a slow subscriber's controller when backpressure is exceeded and
/// the subscriber opted into bounded delivery.
class ChangeBusOverflowError extends Error {
  ChangeBusOverflowError(this.sequence);
  final int sequence;
  @override
  String toString() => 'ChangeBusOverflowError(sequence=$sequence)';
}

class _KeyPair {
  const _KeyPair(this.table, this.key);
  final String table;
  final Object? key;

  @override
  bool operator ==(Object other) =>
      other is _KeyPair && other.table == table && other.key == key;

  @override
  int get hashCode => Object.hash(table, key);
}

/// The change hub for a single database.
class ChangeBus {
  ChangeBus({this.maxBuffered = 1024});

  /// Upper bound on buffered-but-undelivered events per slow subscriber.
  ///
  /// A subscriber that opts into bounded delivery receives a
  /// [`ChangeBusOverflowError`] when it cannot keep up; it can re-subscribe and
  /// replay missed events via the sequence number.
  final int maxBuffered;

  final StreamController<ChangeSet> _controller =
      StreamController<ChangeSet>.broadcast(sync: true);
  final StreamController<int> _sequence = StreamController<int>.broadcast();

  int _nextSeq = 0;
  bool _closed = false;
  int _activeSubscribers = 0;

  /// The last assigned sequence number.
  int get lastSequence => _nextSeq;

  /// Emits one coalesced batch. [keyKind] is `(table, keyBytes) -> ChangeKind`.
  ///
  /// Changes to the **same (table, key)** within one batch are coalesced to the
  /// final state. Returns the sequence number assigned to this batch.
  int publish(List<Change> changes) => publishAt(_nextSeq + 1, changes);

  /// Publishes a batch using the durable LSN assigned by the writer.
  int publishAt(int sequence, List<Change> changes) {
    if (_closed) return _nextSeq;
    if (sequence <= _nextSeq) {
      sequence = _nextSeq + 1;
    }
    _nextSeq = sequence;
    final seq = sequence;
    final coalesced = <Change>[];
    final index = <_KeyPair, int>{};
    for (final change in changes) {
      final idxKey = _KeyPair(change.table, change.key);
      final existing = index[idxKey];
      if (existing != null) {
        coalesced[existing] = change;
      } else {
        index[idxKey] = coalesced.length;
        coalesced.add(change);
      }
    }
    final finalChanges = [
      for (final change in coalesced)
        Change(
          table: change.table,
          key: change.key,
          kind: change.kind,
          sequence: seq,
        ),
    ];
    _controller.add(ChangeSet(finalChanges, sequence: seq));
    return seq;
  }

  /// Broadcast stream of coalesced per-batch [`ChangeSet`]s. Every active
  /// subscription is counted for diagnostics ([activeSubscriberCount]); each
  /// listener receives every batch in publish order.
  Stream<ChangeSet> get stream {
    return Stream<ChangeSet>.multi((controller) {
      _activeSubscribers++;
      late final StreamSubscription<ChangeSet> sub;
      sub = _controller.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
        cancelOnError: true,
      );
      controller.onCancel = () {
        _activeSubscribers--;
        return sub.cancel();
      };
    });
  }

  /// Number of currently-active [`stream`] subscriptions (diagnostics).
  int get activeSubscriberCount => _activeSubscribers;

  /// Broadcast stream of monotonically increasing sequence numbers.
  Stream<int> get sequences => _sequence.stream;

  /// Emits the sequence number for the just-published batch to internal
  /// listeners (item/collection watch creators rely on ordering only; the
  /// per-batch stream is the authoritative feed).
  void notifySequence(int seq) {
    if (_closed) return;
    _sequence.add(seq);
  }

  bool get isClosed => _closed;

  Future<void> close() async {
    _closed = true;
    await _controller.close();
    await _sequence.close();
  }
}

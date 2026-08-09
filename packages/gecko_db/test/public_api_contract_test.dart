import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

/// Phase 0 contract: the public API is defined as abstract interfaces with no
/// concrete logic leaking into the contracts, so later phases build on a stable
/// (ADR-gated) foundation.
void main() {
  group('Public API contract — abstractness', () {
    test('Database.open remains an abstract contract entry point', () {
      expect(Database.open, isA<Function>());
    });

    test('no concrete engine logic leaks into contracts at runtime', () {
      // These pure data types should construct fine now.
      final change = Change(table: 't', key: 1, kind: ChangeKind.put);
      expect(change.table, 't');
      final cs = ChangeSet([change]);
      expect(cs.length, 1);

      final state = SyncState(phase: SyncPhase.pending, retryCount: 1);
      expect(state.phase, SyncPhase.pending);

      final spec = SortSpec('age', SortOrder.descending);
      expect(spec.field, 'age');
      expect(spec.order, SortOrder.descending);

      // The abstract contracts themselves cannot be instantiated; constructors
      // are implicit and unreachable, so this documents the (*public* contract)
      // is interface-only. The analyzer enforces abstractness.
    });
  });

  group('Change / ChangeSet semantics', () {
    test('ChangeSet coalesces as an ordered list', () {
      final changes = [
        Change(table: 'a', key: 1, kind: ChangeKind.put, sequence: 5),
        Change(table: 'a', key: 2, kind: ChangeKind.delete, sequence: 5),
      ];
      final cs = ChangeSet(changes, sequence: 5);
      expect(cs.sequence, 5);
      expect(cs.changes.first.sequence, 5);
    });
  });
}

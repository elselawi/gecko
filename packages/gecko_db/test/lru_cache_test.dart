import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('LruCache', () {
    test('put/get round-trips and marks MRU', () {
      final c = LruCache<String, int>(capacity: 3);
      c.put('a', 1);
      c.put('b', 2);
      c.put('c', 3);
      expect(c.get('a'), 1);
      expect(c.get('b'), 2);
      expect(c.get('c'), 3);
      expect(c.length, 3);
      expect(c.isEmpty, isFalse);
    });

    test('evicts least-recently-used when over capacity', () {
      final c = LruCache<String, int>(capacity: 2);
      c.put('a', 1);
      c.put('b', 2);
      c.get('a'); // a becomes MRU
      c.put('c', 3); // evicts b (LRU)
      expect(c.containsKey('a'), isTrue);
      expect(c.containsKey('b'), isFalse);
      expect(c.containsKey('c'), isTrue);
    });

    test('updating an existing key does not double-count it', () {
      final c = LruCache<String, int>(capacity: 2);
      c.put('a', 1);
      c.put('a', 10); // update, not new entry
      expect(c.length, 1);
      expect(c.get('a'), 10);
    });

    test('remove and clear', () {
      final c = LruCache<String, int>(capacity: 3);
      c.put('a', 1);
      c.put('b', 2);
      expect(c.remove('a'), 1);
      expect(c.containsKey('a'), isFalse);
      expect(c.remove('missing'), isNull);
      c.clear();
      expect(c.isEmpty, isTrue);
    });

    test('onEvict fires exactly for evicted entries in LRU order', () {
      final evicted = <String>[];
      final c = LruCache<String, int>(
        capacity: 2,
        onEvict: (k, v) => evicted.add('$k=$v'),
      );
      c.put('a', 1);
      c.put('b', 2);
      c.put('c', 3); // evicts a
      c.put('d', 4); // evicts b
      expect(evicted, ['a=1', 'b=2']);
    });

    test('invalidate removes a key', () {
      final c = LruCache<String, int>(capacity: 3);
      c.put('a', 1);
      c.invalidate('a');
      expect(c.get('a'), isNull);
    });
  });
}

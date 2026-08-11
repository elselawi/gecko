/// A minimal LRU cache in front of point reads for hot keys, closing the gap
/// against pure-Dart in-memory alternatives on repeated point reads ().
///
/// Durability guarantee (per 's specification applied early): an
/// eviction is never observable as data loss — only as a cache miss, because
/// the cache is always backed by the durable backend.
library;

import 'dart:collection';

/// A thread-confined LRU key→value cache with deterministic eviction.
class LruCache<K, V> {
  LruCache({
    required this.capacity,
    this.onEvict,
    this.weightOf,
    int? maxWeight,
  }) : assert(capacity > 0),
       _maxWeight = maxWeight,
       _weight = 0 {
    _map = LinkedHashMap<K, V>();
  }

  /// Maximum entry count. All entries above this are evicted (LRU order).
  final int capacity;

  /// Optional per-value weight (e.g. encoded byte length) for a bounded-memory
  /// guarantee. When provided, [maxWeight] caps total resident weight.
  final int Function(V value)? weightOf;
  final int? _maxWeight;

  int _weight;

  /// Total resident weight of all cached values (0 when [weightOf] is null).
  int get weight => _weight;

  final void Function(K key, V value)? onEvict;

  late final LinkedHashMap<K, V> _map;

  int get length => _map.length;

  bool get isEmpty => _map.isEmpty;

  bool containsKey(K key) => _map.containsKey(key);

  /// Returns the cached value, marking it most-recently-used.
  V? get(K key) {
    if (!_map.containsKey(key)) return null;
    final v = _map.remove(key);
    if (v == null) return null;
    _map[key] = v; // move to end (MRU)
    return v;
  }

  /// Inserts [value] under [key], evicting the LRU entry if over capacity.
  void put(K key, V value) {
    final w = weightOf?.call(value) ?? 0;
    if (_map.containsKey(key)) {
      final removed = _map.remove(key);
      if (removed != null && weightOf != null) {
        _weight -= weightOf!(removed);
      }
    }
    _map[key] = value;
    _weight += w;
    _trim();
  }

  /// Removes and returns the value at [key], if present.
  V? remove(K key) {
    if (!_map.containsKey(key)) return null;
    final v = _map.remove(key);
    if (v != null && weightOf != null) _weight -= weightOf!(v);
    return v;
  }

  /// Invalidates [key] (e.g. after a write that changed it).
  void invalidate(K key) => remove(key);

  void clear() {
    _map.clear();
    _weight = 0;
  }

  void _trim() {
    // Hard byte cap: resident weight never exceeds [maxWeight] (evict at the
    // boundary), while entry count uses a strict > for the classic LRU rule.
    while (_map.length > capacity ||
        (_maxWeight != null && _weight >= _maxWeight)) {
      final oldest = _map.keys.first;
      final v = _map.remove(oldest);
      if (v != null) {
        if (weightOf != null) _weight -= weightOf!(v);
        if (onEvict != null) onEvict!(oldest, v);
      }
    }
  }
}

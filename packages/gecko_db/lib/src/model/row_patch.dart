/// Row-level operations for Phase 3: applying partial updates (`patch`) while
/// preserving the missing/null distinction, and resolving defaults.
library;

import '../errors/errors.dart';
import 'row_schema.dart';

/// Result of applying a patch to an existing row.
class PatchResult {
  const PatchResult({required this.row, required this.changedFields});

  /// The merged row after the patch.
  final Map<Object?, Object?> row;

  /// The names of the fields that actually changed.
  final List<String> changedFields;
}

/// Applies [patches] to an existing [row], preserving field presence.
///
/// * A `set` with a non-null value → the field is present with that value.
/// * A `set` with `null` → the field is explicitly present (`null`).
/// * A `remove` → the field becomes *missing* (absent from the row).
///
/// Returns a [`PatchResult`]. Throws a typed `schemaValidation` error if a
/// patch references an unknown field when [validateFields] is true.
PatchResult applyPatch(
  Object? existingRow,
  List<FieldPatch> patches, {
  RowSchema? schema,
  bool validateFields = true,
}) {
  final base = existingRow is Map
      ? Map<Object?, Object?>.from(existingRow)
      : <Object?, Object?>{};
  final changed = <String>[];
  for (final patch in patches) {
    if (schema != null && validateFields) {
      if (schema.specFor(patch.field) == null) {
        throw GeckoError(
          GeckoErrorType.schemaValidation,
          'Patch references unknown field "${patch.field}"',
          details: <String, Object?>{'field': patch.field},
        );
      }
    }
    if (patch.isRemove) {
      if (base.containsKey(patch.field)) {
        base.remove(patch.field);
        changed.add(patch.field);
      }
    } else {
      final isNullSet = patch.value == null;
      if (schema != null && isNullSet) {
        final spec = schema.specFor(patch.field);
        if (spec != null && spec.required && !spec.hasDefault) {
          throw GeckoError(
            GeckoErrorType.schemaValidation,
            'Field "${patch.field}" must not be null',
            details: <String, Object?>{'field': patch.field},
          );
        }
      }
      final existed = base.containsKey(patch.field);
      final prior = base[patch.field];
      base[patch.field] = patch.value;
      // Only count as changed if the value actually differs.
      if (!existed || !_same(prior, patch.value)) {
        changed.add(patch.field);
      }
    }
  }
  return PatchResult(row: base, changedFields: changed);
}

/// Resolves declared defaults for any missing fields in [row].
///
/// Only declared fields with a [FieldSpec.hasDefault] are filled; unknown
/// fields are preserved untouched.
Object? applyDefaults(Object? row, RowSchema schema) {
  if (row is! Map) return row;
  final out = Map<Object?, Object?>.from(row);
  for (final spec in schema.fields) {
    if (spec.hasDefault && !out.containsKey(spec.name)) {
      out[spec.name] = spec.defaultValue;
    }
  }
  return out;
}

bool _same(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_same(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

/// Codegen-free typed modeling (Phase 3).
///
/// Provides the missing/null/default distinction, optional-field awareness for
/// `patch`, and schema validation — all against the plain row maps that the
/// wire codec already serializes. No annotations, no codegen: models stay plain
/// Dart classes and `toRow`/`fromRow` stay plain functions.
library;

import '../errors/errors.dart';

/// The three distinct states a field can be in (never collapsed into one):
///
/// * **missing** — the field was never provided/defined for this record;
/// * **null** — the field is explicitly present with a null value;
/// * **value** — the field holds an actual (possibly defaulted) value.
enum FieldPresence { missing, null_, value }

/// Describes a single field's shape for schema validation and patch behavior.
class FieldSpec {
  const FieldSpec({
    required this.name,
    this.required = false,
    this.defaultValue,
    this.hasDefault = false,
  }) : assert(
         !hasDefault || defaultValue != null,
         'A declared default value must be non-null',
       );

  /// Field name (map key in the row).
  final String name;

  /// Whether this field must always be present (not missing) on insert.
  final bool required;

  /// The value used when the field is missing and [hasDefault] is true.
  final Object? defaultValue;

  /// Whether [defaultValue] is declared (false → no default).
  final bool hasDefault;
}

/// An ordered collection of [`FieldSpec`]s describing a row shape.
///
/// This is the schema used at collection-open for validation, and it drives
/// `patch` semantics (which fields may be absent).
class RowSchema {
  RowSchema(this.fields);

  /// Validates the schema definition itself at collection-open time.
  void validateDefinition() {
    final seen = <String>{};
    for (final field in fields) {
      if (field.name.isEmpty) {
        throw GeckoError(
          GeckoErrorType.schemaValidation,
          'Schema field name must not be empty',
          details: <String, Object?>{'field': field.name},
        );
      }
      if (!seen.add(field.name)) {
        throw GeckoError(
          GeckoErrorType.schemaValidation,
          'Duplicate schema field "${field.name}"',
          details: <String, Object?>{'field': field.name},
        );
      }
    }
  }

  /// Field specs in declaration order.
  final List<FieldSpec> fields;

  factory RowSchema.of(Map<String, FieldSpec> specs) =>
      RowSchema(specs.values.toList());

  /// Looks up a field spec by name, or null.
  FieldSpec? specFor(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// Validates a plain row map against this schema.
  ///
  /// Throws a typed `schemaValidation` [`GeckoError`] naming the offending
  /// field on the first failure. Unknown (undeclared) fields are left alone so
  /// forward compatibility holds. Returns the row unchanged on success.
  Object? validate(Object? row) {
    if (row is! Map) {
      throw GeckoError(
        GeckoErrorType.schemaValidation,
        'Row must be a map, got ${row?.runtimeType}',
      );
    }
    final map = Map<Object?, Object?>.from(row);
    for (final spec in fields) {
      final present = map.containsKey(spec.name);
      if (!present) {
        if (spec.required && !spec.hasDefault) {
          throw GeckoError(
            GeckoErrorType.schemaValidation,
            'Missing required field "${spec.name}"',
            details: <String, Object?>{'field': spec.name},
          );
        }
      } else if (map[spec.name] == null) {
        if (spec.required && !spec.hasDefault) {
          throw GeckoError(
            GeckoErrorType.schemaValidation,
            'Field "${spec.name}" must not be null',
            details: <String, Object?>{'field': spec.name},
          );
        }
      }
    }
    return map;
  }

  /// Classifies each declared field's presence in [row].
  ///
  /// Only declared fields are reported; unknown fields (forward-compat) are
  /// left untracked so they survive round-trips untouched.
  Map<String, FieldPresence> presenceOf(Object? row) {
    final out = <String, FieldPresence>{};
    if (row is! Map) {
      for (final f in fields) {
        out[f.name] = FieldPresence.missing;
      }
      return out;
    }
    for (final spec in fields) {
      if (!row.containsKey(spec.name)) {
        out[spec.name] = FieldPresence.missing;
      } else if (row[spec.name] == null) {
        out[spec.name] = FieldPresence.null_;
      } else {
        out[spec.name] = FieldPresence.value;
      }
    }
    return out;
  }
}

/// A pure description of a single field change used by `patch`.
///
/// A `set` makes the field explicitly present (with [value], including an
/// explicit `null`); a `remove` makes the field **missing** (absent from the
/// stored row). This is how `patch` preserves the missing/null distinction.
class FieldPatch {
  const FieldPatch._(this.field, this.value, this.isRemove);

  /// Sets [field] to [value] (may be `null` — an explicit null).
  const FieldPatch.set(String field, Object? value)
    : this._(field, value, false);

  /// Removes [field] from the row (making it *missing*, distinct from null).
  const FieldPatch.remove(String field) : this._(field, null, true);

  /// The field being changed.
  final String field;

  /// The new value (for `set`), or null.
  final Object? value;

  /// Whether this is a `remove` (→ missing) rather than a `set`.
  final bool isRemove;

  bool get isSet => !isRemove;
}

// Workstream 6: the 12-criterion traceability table is checked by a script.
//
// The checker (`tool/traceability_check.dart`) maps every local-first
// acceptance criterion to named tests; this test verifies the table is
// complete, that every referenced test currently exists in the repository,
// and that the checker itself rejects a deliberately-broken fixture.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'traceability_check.dart';

void main() {
  test('the traceability table covers all 12 acceptance criteria', () {
    expect(kTraceability.length, 12);
    final numbers = kTraceability.map((e) => e.criterion).toList();
    expect(numbers, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    // Every criterion names at least one test.
    for (final entry in kTraceability) {
      expect(entry.tests, isNotEmpty, reason: 'criterion ${entry.criterion}');
    }
  });

  test('every referenced test exists and is named in its file', () {
    final missing = verifyExistence();
    expect(
      missing,
      isEmpty,
      reason:
          'traceability references must point at real, named tests: '
          '$missing',
    );
  });

  test('the checker rejects a deliberately-broken fixture', () {
    final broken = [
      const TraceEntry(99, 'broken', [
        ('tool/__does_not_exist__.dart', 'nope'),
        // A real file whose content does NOT contain this name (the name only
        // exists in this test fixture).
        (
          'tool/traceability_check.dart',
          'this name is absent from the checker 9f8e7d2',
        ),
      ]),
    ];
    final missing = verifyExistence(entries: broken);
    expect(missing, hasLength(2));
    expect(missing[0].$1, 'tool/__does_not_exist__.dart');
  });

  test('the checker emits machine-readable JSON', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/traceability_check.dart',
      '--json',
    ]);
    expect(result.exitCode, 0);
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(decoded['criteria'], 12);
    expect(decoded['missing'], isEmpty);
  });
}

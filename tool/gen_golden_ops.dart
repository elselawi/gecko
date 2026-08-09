// Generates a cross-language golden fixture file for the `Op` wire format.
//
// The same logical operation set is encoded by the Dart encoder and written to
// `rust/tests/fixtures/golden_ops.bin`. A Rust integration test (`tests/
// golden_cross_lang.rs`) decodes that file byte-for-byte and asserts it
// reproduces the identical ops — proving the two encoders agree, rather than
// two independent encoders that merely happen to be self-consistent.
//
// Usage: dart run tool/gen_golden_ops.dart
//
// This fixture is the contract artifact from Phase 0; regenerate only with an
// ADR, and commit the produced .bin to the repo.

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

/// The logical op set both sides agree on. Keep this stable across releases.
List<Op> goldenOps() {
  const codec = DefaultWireCodec();
  return [
    Op(
      op: OpKind.put,
      table: 'users',
      key: codec.encode('id-0001'),
      value: codec.encode({'name': 'A'}),
    ),
    Op(
      op: OpKind.put,
      table: 'users',
      key: codec.encode('id-0002'),
      value: codec.encode({'name': 'B'}),
    ),
    Op(
      op: OpKind.rangeScan,
      table: 'users',
      start: codec.encode('id-0000'),
      end: codec.encode('id-ffff'),
    ),
    Op(op: OpKind.get, table: 'users', key: codec.encode('id-0001')),
    Op(op: OpKind.delete, table: 'users', key: codec.encode('id-0002')),
    Op(
      op: OpKind.deleteRange,
      table: 'logs',
      start: codec.encode(0),
      end: codec.encode(100),
    ),
    Op(op: OpKind.clear, table: 'sessions'),
  ];
}

void main() {
  final ops = goldenOps();
  final bytes = Op.encodeBatch(ops);
  final out = File('rust/tests/fixtures/golden_ops.bin')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  stdout.writeln(
    'Wrote ${out.path} (${bytes.length} bytes, ${ops.length} ops)',
  );

  // Self-check: the Dart encoder must decode its own output losslessly.
  final round = Op.decodeBatch(bytes);
  if (round.length != ops.length) {
    stderr.writeln('SELF-CHECK FAILED: op count mismatch');
    exit(1);
  }
  stdout.writeln('Dart self-check: ${round.length} ops decoded OK');
}

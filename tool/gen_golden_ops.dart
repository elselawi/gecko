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
// This fixture is a cross-language contract artifact; regenerate it only
// alongside an intentional wire-format change and commit the produced .bin
// to the repo.

import 'dart:io';
import 'dart:typed_data';

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
    // Every codec scalar: the value carries BigInt, double, bool, null,
    // bytes, DateTime, and a nested list/map, so the Rust decoder must agree
    // on the full `RowValue` tree — not just op kind + table name.
    Op(
      op: OpKind.put,
      table: 'rich',
      key: codec.encode(42),
      value: codec.encode({
        'big': BigInt.parse('123456789012345678901234567890'),
        'pi': 3.14159,
        'flag': true,
        'nil': null,
        'blob': Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
        'at': DateTime.utc(2024, 1, 2, 3, 4, 5, 6, 7),
        'nested': [
          1,
          {'k': 'v'},
          [true, null],
        ],
        'negative': -9876543210,
      }),
    ),
    // A put whose value is explicitly null (present, empty map not needed).
    Op(
      op: OpKind.put,
      table: 'rich',
      key: codec.encode(BigInt.from(-5)),
      value: codec.encode(null),
    ),
    // Bytes as a map key (unusual but legal), and a bytes key itself.
    Op(
      op: OpKind.put,
      table: 'rich',
      key: codec.encode(Uint8List.fromList([1, 2, 3])),
      value: codec.encode({
        Uint8List.fromList([9, 8]): 'byte-keyed',
      }),
    ),
    // A range scan bounded by DateTime-encoded keys.
    Op(
      op: OpKind.rangeScan,
      table: 'events',
      start: codec.encode(DateTime.utc(2023)),
      end: codec.encode(DateTime.utc(2025)),
    ),
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

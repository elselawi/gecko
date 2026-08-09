import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test('native backend and FRB bridge are public integration surfaces', () {
    expect(NativeRawBackend, isA<Type>());
    expect(NativeWorker, isA<Type>());
    expect(RustLib, isA<Type>());
  });

  test('native worker uses the same Op contract version', () {
    expect(Op.wireVersion, 1);
    expect(FormatHeader(packageVersion: '0.0.1').wireVersion, geckoWireVersion);
  });
}

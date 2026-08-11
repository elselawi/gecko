import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _User {
  _User(this.id, this.name, this.age);
  final String id;
  final String name;
  final int age;
}

Object? _toRow(_User user) => {
  'id': user.id,
  'name': user.name,
  'age': user.age,
};
_User _fromRow(Object? row) {
  final map = Map<Object?, Object?>.from(row as Map);
  return _User(map['id'] as String, map['name'] as String, map['age'] as int);
}

Object? _id(_User user) => user.id;

void main() {
  test('quickstart example compiles and runs', () async {
    final db = await openNativeTestDatabase('examples-quick');
    final users = db.collection<_User>(
      'users',
      toRow: _toRow,
      fromRow: _fromRow,
      id: _id,
      indexFields: ['age'],
    );
    await users.put(_User('u1', 'Alice', 30));
    await users.patch('u1', {'name': 'Alicia'});
    final adults = await users.where().range(ageField, min: 18).findAll();
    expect(adults.single.name, 'Alicia');
    await db.close();
  });

  test('advanced example compiles and runs', () async {
    final db = await openNativeTestDatabase('examples-advanced');
    db.diagnostics.enable();
    final bulk = await db.bulkWrite([
      const BulkMutation.put(
        table: 'settings',
        key: 'theme',
        value: {'value': 'dark'},
      ),
      const BulkMutation.put(
        table: 'settings',
        key: 'sync',
        value: {'value': 'enabled'},
      ),
    ]);
    expect(bulk.mutationCount, 2);
    expect(db.diagnostics.snapshot().totalWrites, greaterThan(0));
    await db.schema.stamp(1);
    await db.schema.migrateStep(
      const MigrationStep(
        name: 'add-settings-version',
        fromVersion: 1,
        toVersion: 2,
      ),
    );
    expect(await db.schema.readVersion(), 2);
    await db.close();
  });
}

const ageField = 'age';

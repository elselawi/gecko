import 'package:gecko_db/gecko_db.dart';

class User {
  User(this.id, this.name, this.age);
  final String id;
  final String name;
  final int age;
}

Object? userToRow(User user) => {
  'id': user.id,
  'name': user.name,
  'age': user.age,
};

User userFromRow(Object? row) {
  final map = Map<Object?, Object?>.from(row as Map);
  return User(map['id'] as String, map['name'] as String, map['age'] as int);
}

Object? userId(User user) => user.id;

Future<void> main() async {
  final db = await DatabaseImpl.open(
    'mem://phase13-example',
    useInMemory: true,
  );
  final users = db.collection<User>(
    'users',
    toRow: userToRow,
    fromRow: userFromRow,
    id: userId,
    indexFields: ['age'],
  );

  await users.put(User('u1', 'Alice', 30));
  await users.patch('u1', {'name': 'Alicia'});

  final adults = await users.where().range('age', min: 18).findAll();
  // The example intentionally computes a typed query result without requiring
  // a logging dependency in the consumer application.
  if (adults.isEmpty) throw StateError('Expected at least one adult');

  await db.close();
}

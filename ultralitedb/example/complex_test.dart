import 'package:ultralitedb/ultralitedb.dart';

class Address {
  final String street;
  final String city;

  Address({required this.street, required this.city});

  Map<String, dynamic> toJson() => {'street': street, 'city': city};

  static Address fromJson(Map<String, dynamic> json) => Address(street: json['street'] as String, city: json['city'] as String);

  @override
  String toString() => '$street, $city';
}

class User {
  final int id;
  final String name;
  final int age;
  final List<String> tags;
  final Address address;
  final DateTime createdAt;

  User({
    required this.id,
    required this.name,
    required this.age,
    required this.tags,
    required this.address,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    '_id': id,
    'name': name,
    'age': age,
    'tags': tags,
    'address': address.toJson(),
    'createdAt': createdAt,
  };

  static User fromJson(Map<String, dynamic> json) => User(
    id: json['_id'] as int,
    name: json['name'] as String,
    age: json['age'] as int,
    tags: (json['tags'] as List).cast<String>(),
    address: Address.fromJson(json['address'] as Map<String, dynamic>),
    createdAt: json['createdAt'] as DateTime,
  );

  @override
  String toString() => 'User(id: $id, name: $name, age: $age, tags: $tags, address: $address, createdAt: $createdAt)';
}

void main() {
  // 1. Setup BsonMapper for User and Address
  BsonMapper.global.registerType<User>(
    (user) => BsonMapper.global.toDocument(user.toJson()),
    (bson) => User.fromJson(BsonMapper.global.fromDocument(bson.asDocument!)),
  );

  // 2. Open DB (in-memory for testing)
  final db = UltraLiteDatabase.memory();

  try {
    final users = db.getTypedCollection<User>('users');

    // 3. Insert initial data
    print('Inserting users...');
    users.insertAll([
      User(
        id: 1,
        name: 'Alice',
        age: 25,
        tags: ['developer', 'dart'],
        address: Address(street: '123 Dart St', city: 'London'),
        createdAt: DateTime(2023, 1, 1),
      ),
      User(
        id: 2,
        name: 'Bob',
        age: 30,
        tags: ['designer', 'flutter'],
        address: Address(street: '456 Flutter Ave', city: 'London'),
        createdAt: DateTime(2023, 2, 1),
      ),
      User(
        id: 3,
        name: 'Charlie',
        age: 22,
        tags: ['developer', 'c#'],
        address: Address(street: '789 Mono Rd', city: 'New York'),
        createdAt: DateTime(2023, 3, 1),
      ),
      User(
        id: 4,
        name: 'Diana',
        age: 28,
        tags: ['manager', 'agile'],
        address: Address(street: '101 Agile Way', city: 'New York'),
        createdAt: DateTime(2023, 4, 1),
      ),
    ]);

    // 4. Ensure Indexes
    users.ensureIndex('age');
    users.ensureIndex('address.city');

    // 5. Complex Queries
    print('\n--- Queries ---');

    // Find users by city (Nested field)
    print('Users in London:');
    final londoners = users.find(query: Query.eq('address.city', BsonValue.fromString('London')));
    londoners.forEach(print);

    // Find developers (Array field contains)
    print('\nDevelopers:');
    final developers = users.find(query: Query.contains('tags', 'developer'));
    developers.forEach(print);

    // Filter by Age and City (Logical AND)
    print('\nUsers in New York older than 25:');
    final nySeniors = users.find(
      query: Query.and(Query.eq('address.city', BsonValue.fromString('New York')), Query.gt('age', BsonValue.fromInt(25))),
    );
    nySeniors.forEach(print);

    // Filter by Multiple tags (Logical OR)
    print('\nUsers interested in Flutter or C#:');
    final devInterests = users.find(query: Query.or(Query.contains('tags', 'flutter'), Query.contains('tags', 'c#')));
    devInterests.forEach(print);

    // Range query on dates
    print('\nUsers created before March 2023:');
    final earlyUsers = users.find(query: Query.lt('createdAt', BsonValue.fromDateTime(DateTime(2023, 3, 1))));
    earlyUsers.forEach(print);

    // 6. Updates
    print('\n--- Updates ---');
    final alice = users.findById(BsonValue.fromInt(1));
    if (alice != null) {
      final updatedAlice = User(
        id: alice.id,
        name: 'Alice Smith',
        age: 26, // Happy birthday!
        tags: alice.tags + ['expert'],
        address: alice.address,
        createdAt: alice.createdAt,
      );
      users.update(updatedAlice);
      print('Updated Alice: ${users.findById(BsonValue.fromInt(1))}');
    }

    // 7. Transactions
    print('\n--- Transactions ---');
    db.runInTransaction(() {
      users.deleteById(BsonValue.fromInt(2)); // Bye Bob
      users.insert(
        User(
          id: 5,
          name: 'Eve',
          age: 24,
          tags: ['security'],
          address: Address(street: '000 Secret Ln', city: 'Berlin'),
          createdAt: DateTime.now(),
        ),
      );
      print('Bob deleted and Eve inserted inside transaction.');
    });

    print('Final users list:');
    users.findAll().forEach(print);

    // 8. Error test (Duplicate ID)
    print('\n--- Error Test (Duplicate ID) ---');
    try {
      users.insert(
        User(
          id: 1, // Already exists
          name: 'Clone',
          age: 0,
          tags: [],
          address: Address(street: '', city: ''),
          createdAt: DateTime.now(),
        ),
      );
    } catch (e) {
      print('Caught expected error: $e');
    }
  } finally {
    db.dispose();
  }
}

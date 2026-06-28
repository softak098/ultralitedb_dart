import 'package:ultralitedb/ultralitedb.dart';

void main() {
  final s = Stopwatch()..start();

  print(s.elapsedMilliseconds);
  //t1Bulk();

  //  t2();

  tArrayBulk();

  print(s.elapsedMilliseconds);

  s.stop();
}

void tArrayBulk() {
  // Open database (or create if doesn't exist)
  var db = UltraLiteDatabase.file("products_bulk.db");

  // Get a collection
  var col = db.getCollection("product_colored");

  //   final c = col.count(
  //     Query.between(
  //       "Price",
  //       BsonValue.fromDouble(100),
  //       BsonValue.fromDouble(200),
  //     ),
  //   );

  //   print(c);

  //  return;

  //   col.ensureIndex("Price");
  col.ensureIndex("Color");

  final ps = <BsonDocument>[];

  for (var i = 0; i < 300000; i++) {
    var p = BsonDocument();
    // p["Name"] = "Product $i";
    // p["Price"] = i / 15;
    p["Color"] = ["color-$i", "$i-color"];
    p["_id"] = i;
    p["ProductId"] = i;
    p["BatchId"] = i - 11;

    ps.add(p);

    if (i > 0 && i % 30000 == 0) {
      col.insertAll(ps);
      ps.clear();
    }
    //
  }

  col.insertAll(ps);

  db.dispose();
}

void t1Bulk() {
  // Open database (or create if doesn't exist)
  var db = UltraLiteDatabase.file("products_bulk.db");

  // Get a collection
  var col = db.getCollection("product");

  final c = col.count(Query.between("Price", BsonValue.fromDouble(100), BsonValue.fromDouble(200)));

  print(c);

  return;

  col.ensureIndex("Price");

  final ps = <BsonDocument>[];

  for (var i = 0; i < 10000; i++) {
    var p = BsonDocument();
    p["Name"] = "Product $i";
    p["Price"] = i / 15;

    ps.add(p);
  }

  col.insertAll(ps);

  db.dispose();
}

void t1() {
  var db = UltraLiteDatabase.file("products.db");

  // Get a collection
  var col = db.getCollection("product");
  col.ensureIndex("Price");

  for (var i = 0; i < 10000; i++) {
    var character = BsonDocument();
    character["Name"] = "Product $i";
    character["Price"] = i / 15;

    col.insert(character);
  }

  db.dispose();
}

void t2() {
  // Open database (or create if doesn't exist)
  var db = UltraLiteDatabase.file("MyData.db");

  var names = db.getCollectionNames();
  for (var element in names) {
    print(element);
  }

  // Get a collection
  var col = db.getCollection("score");
  col.ensureIndex("Level");

  // Create a new character document
  var character = BsonDocument();
  character["Name"] = "John Doe";
  character["Equipment"] = ["sword", "gnome hat"];
  character["Level"] = 1;
  character["IsActive"] = true;

  // Insert new customer document (Id will be auto generated)
  BsonValue id = col.insert(character);
  // new Id has also been added to the document at character["_id"]

  // Update a document inside a collection
  character["Name"] = "Joana Doe";
  col.update(character);

  // Insert a document with a manually chosen Id
  var character2 = BsonDocument();
  //character2["_id"] = 10;
  character2["Name"] = "Test Bob";
  character2["Level"] = 10;
  character2["IsActive"] = true;
  col.insert(character2);

  // // Load all documents
  // List<BsonDocument> allCharacters = characters.FindAll();

  // // Delete something
  // col.Delete(10);

  // // Upsert (Update if present or insert if not)
  // col.Upsert(character);

  // Don't forget to cleanup!
  db.dispose();
}

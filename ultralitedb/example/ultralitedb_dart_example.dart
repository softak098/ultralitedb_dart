import 'package:ultralitedb/ultralitedb.dart';

Future<void> main() async {
  final s = Stopwatch()..start();

  print(s.elapsedMilliseconds);
  //await t1Bulk();

  //  await t2();

  await tArrayBulk();

  print(s.elapsedMilliseconds);

  s.stop();
}

Future<void> tArrayBulk() async {
  // Open database (or create if doesn't exist)
  var db = await UltraLiteDatabase.file("products_bulk.db");

  // Get a collection
  var col = db.getCollection("product_colored");

  //   final c = await col.count(
  //     Query.between(
  //       "Price",
  //       BsonValue.fromDouble(100),
  //       BsonValue.fromDouble(200),
  //     ),
  //   );

  //   print(c);

  //  return;

  //   await col.ensureIndex("Price");
  await col.ensureIndex("Color");

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
      await col.insertAll(ps);
      ps.clear();
    }
  }

  await col.insertAll(ps);

  await db.dispose();
}

Future<void> t1Bulk() async {
  // Open database (or create if doesn't exist)
  var db = await UltraLiteDatabase.file("products_bulk.db");

  // Get a collection
  var col = db.getCollection("product");

  final c = await col.count(Query.between("Price", BsonValue.fromInt(100), BsonValue.fromInt(200)));

  print(c);

  return;

  await col.ensureIndex("Price");

  final ps = <BsonDocument>[];

  for (var i = 0; i < 10000; i++) {
    var p = BsonDocument();
    p["Name"] = "Product $i";
    p["Price"] = i / 15;

    ps.add(p);
  }

  await col.insertAll(ps);

  await db.dispose();
}

Future<void> t1() async {
  var db = await UltraLiteDatabase.file("products.db");

  // Get a collection
  var col = db.getCollection("product");
  await col.ensureIndex("Price");

  for (var i = 0; i < 10000; i++) {
    var character = BsonDocument();
    character["Name"] = "Product $character";
    character["Price"] = i / 15;

    await col.insert(character);
  }

  await db.dispose();
}

/*
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
*/

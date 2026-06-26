import 'package:ultralitedb/ultralitedb.dart';

//part 'product.bson.g.dart';

@BsonSerializable()
class Product {
  @BsonField()
  String name;

  @BsonField()
  List<String>? barcodes;

  Product(this.name);
}

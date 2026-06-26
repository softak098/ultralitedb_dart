import 'package:ultralitedb/ultralitedb.dart';

@BsonSerializable()
class Product2 {
  @BsonField()
  String name;

  @BsonField()
  List<String>? barcodes;

  Product2(this.name);
}

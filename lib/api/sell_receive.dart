/// Autogenerated from flutter_deriv_api|lib/api/sell_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'sell_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SellResponse extends Response {
  ///
  SellResponse({this.echoReq, this.msgType, this.reqId, this.sell});

  ///
  factory SellResponse.fromJson(Map<String, dynamic> json) =>
      _$SellResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$SellResponseToJson(this);

  // Properties
  /// Echo of the request made.
  Map<String, dynamic> echoReq;

  /// Action name of the request made.
  String msgType;

  /// Optional field sent in request to map to response, present only when request contains `req_id`.
  int reqId;

  /// Receipt for the transaction
  Map<String, dynamic> sell;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

/// Autogenerated from flutter_deriv_api|lib/api/sell_expired_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'sell_expired_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SellExpiredResponse extends Response {
  ///
  SellExpiredResponse(
      {Map<String, dynamic> echoReq,
      String msgType,
      int reqId,
      this.sellExpired})
      : super(echoReq: echoReq, msgType: msgType, reqId: reqId);

  ///
  factory SellExpiredResponse.fromJson(Map<String, dynamic> json) =>
      _$SellExpiredResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$SellExpiredResponseToJson(this);

  // Properties

  /// Sell expired contract object containing count of contracts sold
  Map<String, dynamic> sellExpired;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

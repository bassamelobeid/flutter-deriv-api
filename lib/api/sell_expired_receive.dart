/// Autogenerated from flutter_deriv_api|lib/api/sell_expired_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'sell_expired_receive.g.dart';

/// JSON conversion for 'sell_expired_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SellExpiredResponse extends Response {
  /// Initialize SellExpiredResponse
  SellExpiredResponse(
      {this.sellExpired,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory SellExpiredResponse.fromJson(Map<String, dynamic> json) =>
      _$SellExpiredResponseFromJson(json);

  // Properties
  /// Sell expired contract object containing count of contracts sold
  Map<String, dynamic> sellExpired;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$SellExpiredResponseToJson(this);
}

/// Autogenerated from flutter_deriv_api|lib/api/balance_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'balance_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class BalanceResponse extends Response {
  ///
  BalanceResponse(
      {this.balance,
      this.echoReq,
      this.msgType,
      this.reqId,
      this.subscription});

  ///
  factory BalanceResponse.fromJson(Map<String, dynamic> json) =>
      _$BalanceResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$BalanceResponseToJson(this);

  // Properties
  /// Realtime stream of user balance changes.
  Map<String, dynamic> balance;

  /// Echo of the request made.
  Map<String, dynamic> echoReq;

  /// Action name of the request made.
  String msgType;

  /// Optional field sent in request to map to response, present only when request contains `req_id`.
  int reqId;

  /// For subscription requests only
  Map<String, dynamic> subscription;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

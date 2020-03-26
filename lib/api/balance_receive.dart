/// Autogenerated from flutter_deriv_api|lib/api/balance_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'balance_receive.g.dart';

/// JSON conversion for 'balance_receive'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class BalanceResponse extends Response {
  /// Initialize BalanceResponse
  BalanceResponse(
      {this.balance,
      this.subscription,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory BalanceResponse.fromJson(Map<String, dynamic> json) =>
      _$BalanceResponseFromJson(json);

  // Properties
  /// Realtime stream of user balance changes.
  Map<String, dynamic> balance;

  /// For subscription requests only
  Map<String, dynamic> subscription;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$BalanceResponseToJson(this);
}

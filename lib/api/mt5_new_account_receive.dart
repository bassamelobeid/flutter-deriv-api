/// Autogenerated from flutter_deriv_api|lib/api/mt5_new_account_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'mt5_new_account_receive.g.dart';

/// JSON conversion for 'mt5_new_account_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5NewAccountResponse extends Response {
  /// Initialize Mt5NewAccountResponse
  Mt5NewAccountResponse(
      {this.mt5NewAccount,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory Mt5NewAccountResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5NewAccountResponseFromJson(json);

  // Properties
  /// New MT5 account details
  Map<String, dynamic> mt5NewAccount;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$Mt5NewAccountResponseToJson(this);
}

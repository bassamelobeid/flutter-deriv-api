/// Autogenerated from flutter_deriv_api|lib/api/mt5_new_account_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'mt5_new_account_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5NewAccountResponse extends Response {
  ///
  Mt5NewAccountResponse(
      {this.mt5NewAccount,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory Mt5NewAccountResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5NewAccountResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$Mt5NewAccountResponseToJson(this);

  // Properties

  /// New MT5 account details
  Map<String, dynamic> mt5NewAccount;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

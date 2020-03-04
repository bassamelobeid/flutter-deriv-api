/// Autogenerated from flutter_deriv_api|lib/api/set_account_currency_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'set_account_currency_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SetAccountCurrencyResponse extends Response {
  ///
  SetAccountCurrencyResponse(
      {this.setAccountCurrency,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory SetAccountCurrencyResponse.fromJson(Map<String, dynamic> json) =>
      _$SetAccountCurrencyResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$SetAccountCurrencyResponseToJson(this);

  // Properties

  /// `1`: success, `0`: no change
  int setAccountCurrency;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

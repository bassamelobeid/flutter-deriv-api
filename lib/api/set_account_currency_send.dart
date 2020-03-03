/// Autogenerated from flutter_deriv_api|lib/api/set_account_currency_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'set_account_currency_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SetAccountCurrencyRequest extends Request {
  ///
  SetAccountCurrencyRequest(
      {Map<String, dynamic> passthrough, int reqId, this.setAccountCurrency})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory SetAccountCurrencyRequest.fromJson(Map<String, dynamic> json) =>
      _$SetAccountCurrencyRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$SetAccountCurrencyRequestToJson(this);

  // Properties

  /// Currency of the account. List of supported currencies can be acquired with `payout_currencies` call.
  String setAccountCurrency;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

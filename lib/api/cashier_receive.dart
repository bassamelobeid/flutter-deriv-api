/// Autogenerated from flutter_deriv_api|lib/api/cashier_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'cashier_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class CashierResponse extends Response {
  ///
  CashierResponse({this.cashier, this.echoReq, this.msgType, this.reqId});

  ///
  factory CashierResponse.fromJson(Map<String, dynamic> json) =>
      _$CashierResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$CashierResponseToJson(this);

  // Properties
  /// Cashier URL. Note: possible error codes are: ASK_TNC_APPROVAL (API tnc_approval), ASK_AUTHENTICATE, ASK_UK_FUNDS_PROTECTION (API tnc_approval), ASK_CURRENCY (API set_account_currency), ASK_EMAIL_VERIFY (verify_email), ASK_FIX_DETAILS (API set_settings).
  String cashier;

  /// Echo of the request made.
  Map<String, dynamic> echoReq;

  /// Action name of the request made.
  String msgType;

  /// Optional field sent in request to map to response, present only when request contains `req_id`.
  int reqId;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

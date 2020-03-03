/// Autogenerated from flutter_deriv_api|lib/api/buy_contract_for_multiple_accounts_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'buy_contract_for_multiple_accounts_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class BuyContractForMultipleAccountsResponse extends Response {
  ///
  BuyContractForMultipleAccountsResponse(
      {this.buyContractForMultipleAccounts,
      this.echoReq,
      this.msgType,
      this.reqId});

  ///
  factory BuyContractForMultipleAccountsResponse.fromJson(
          Map<String, dynamic> json) =>
      _$BuyContractForMultipleAccountsResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() =>
      _$BuyContractForMultipleAccountsResponseToJson(this);

  // Properties
  /// Receipt confirmation for the purchase
  Map<String, dynamic> buyContractForMultipleAccounts;

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

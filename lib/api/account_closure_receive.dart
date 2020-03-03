/// Autogenerated from flutter_deriv_api|lib/api/account_closure_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'account_closure_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AccountClosureResponse extends Response {
  ///
  AccountClosureResponse(
      {this.accountClosure, this.echoReq, this.msgType, this.reqId});

  ///
  factory AccountClosureResponse.fromJson(Map<String, dynamic> json) =>
      _$AccountClosureResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$AccountClosureResponseToJson(this);

  // Properties
  /// If set to `1`, all accounts are closed.
  int accountClosure;

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

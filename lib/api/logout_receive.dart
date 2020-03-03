/// Autogenerated from flutter_deriv_api|lib/api/logout_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'logout_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class LogoutResponse extends Response {
  ///
  LogoutResponse({this.echoReq, this.logout, this.msgType, this.reqId});

  ///
  factory LogoutResponse.fromJson(Map<String, dynamic> json) =>
      _$LogoutResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$LogoutResponseToJson(this);

  // Properties
  /// Echo of the request made.
  Map<String, dynamic> echoReq;

  /// The result of logout request which is 1
  int logout;

  /// Action name of the request made.
  String msgType;

  /// Optional field sent in request to map to response, present only when request contains `req_id`.
  int reqId;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

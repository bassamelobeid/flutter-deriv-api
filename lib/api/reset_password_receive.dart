/// Autogenerated from flutter_deriv_api|lib/api/reset_password_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'reset_password_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ResetPasswordResponse extends Response {
  ///
  ResetPasswordResponse(
      {this.echoReq, this.msgType, this.reqId, this.resetPassword});

  ///
  factory ResetPasswordResponse.fromJson(Map<String, dynamic> json) =>
      _$ResetPasswordResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ResetPasswordResponseToJson(this);

  // Properties
  /// Echo of the request made.
  Map<String, dynamic> echoReq;

  /// Action name of the request made.
  String msgType;

  /// Optional field sent in request to map to response, present only when request contains `req_id`.
  int reqId;

  /// `1`: password reset success, `0`: password reset failure
  int resetPassword;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

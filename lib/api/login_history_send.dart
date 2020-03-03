/// Autogenerated from flutter_deriv_api|lib/api/login_history_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'login_history_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class LoginHistoryRequest extends Request {
  ///
  LoginHistoryRequest(
      {this.limit,
      this.loginHistory,
      Map<String, dynamic> passthrough,
      int reqId})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory LoginHistoryRequest.fromJson(Map<String, dynamic> json) =>
      _$LoginHistoryRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$LoginHistoryRequestToJson(this);

  // Properties
  /// [Optional] Apply limit to count of login history records.
  int limit;

  /// Must be `1`
  int loginHistory;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

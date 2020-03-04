/// Autogenerated from flutter_deriv_api|lib/api/mt5_password_check_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'mt5_password_check_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5PasswordCheckRequest extends Request {
  ///
  Mt5PasswordCheckRequest(
      {this.login,
      this.mt5PasswordCheck,
      this.password,
      this.passwordType,
      int reqId,
      Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  ///
  factory Mt5PasswordCheckRequest.fromJson(Map<String, dynamic> json) =>
      _$Mt5PasswordCheckRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$Mt5PasswordCheckRequestToJson(this);

  // Properties
  /// MT5 user login
  String login;

  /// Must be `1`
  int mt5PasswordCheck;

  /// The password of the account.
  String password;

  /// [Optional] Type of the password to check.
  String passwordType;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

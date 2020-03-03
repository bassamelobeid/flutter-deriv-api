/// Autogenerated from flutter_deriv_api|lib/api/reset_password_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'reset_password_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ResetPasswordRequest extends Request {
  ///
  ResetPasswordRequest(
      {this.dateOfBirth,
      this.newPassword,
      this.passthrough,
      this.reqId,
      this.resetPassword,
      this.verificationCode});

  ///
  factory ResetPasswordRequest.fromJson(Map<String, dynamic> json) =>
      _$ResetPasswordRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ResetPasswordRequestToJson(this);

  // Properties
  /// [Optional] Date of birth format: `yyyy-mm-dd`. Only required for clients with real-money accounts.
  String dateOfBirth;

  /// New password for validation (length within 6-25 chars, accepts any printable ASCII characters, need to include capital and lowercase letters with numbers). Password strength is evaluated with: http://archive.geekwisdom.com/js/passwordmeter.js
  String newPassword;

  /// [Optional] Used to pass data through the websocket, which may be retrieved via the `echo_req` output field.
  Map<String, dynamic> passthrough;

  /// [Optional] Used to map request to response.
  int reqId;

  /// Must be `1`
  int resetPassword;

  /// Email verification code (received from a `verify_email` call, which must be done first)
  String verificationCode;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

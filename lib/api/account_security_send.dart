/// Autogenerated from flutter_deriv_api|lib/api/account_security_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'account_security_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AccountSecurityRequest extends Request {
  ///
  AccountSecurityRequest(
      {this.accountSecurity,
      this.otp,
      this.passthrough,
      this.reqId,
      this.totpAction});

  ///
  factory AccountSecurityRequest.fromJson(Map<String, dynamic> json) =>
      _$AccountSecurityRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$AccountSecurityRequestToJson(this);

  // Properties
  /// Must be `1`
  int accountSecurity;

  /// [Optional] OTP (one-time passcode) generated by a 2FA application like Authy, Google Authenticator or Yubikey.
  String otp;

  /// [Optional] Used to pass data through the websocket, which may be retrieved via the `echo_req` output field.
  Map<String, dynamic> passthrough;

  /// [Optional] Used to map request to response.
  int reqId;

  /// [Optional] Action to be taken for managing TOTP (time-based one-time password, RFC6238). Generate will create a secret key which is then returned in the secret_key response field, you can then enable by using that code in a 2FA application.
  String totpAction;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

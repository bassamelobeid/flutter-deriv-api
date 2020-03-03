/// Autogenerated from flutter_deriv_api|lib/api/mt5_password_check_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'mt5_password_check_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5PasswordCheckResponse extends Response {
  ///
  Mt5PasswordCheckResponse(
      {Map<String, dynamic> echoReq,
      String msgType,
      this.mt5PasswordCheck,
      int reqId})
      : super(echoReq: echoReq, msgType: msgType, reqId: reqId);

  ///
  factory Mt5PasswordCheckResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5PasswordCheckResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$Mt5PasswordCheckResponseToJson(this);

  // Properties

  /// `1` on success
  int mt5PasswordCheck;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

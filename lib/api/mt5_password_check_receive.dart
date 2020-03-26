/// Autogenerated from flutter_deriv_api|lib/api/mt5_password_check_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'mt5_password_check_receive.g.dart';

/// JSON conversion for 'mt5_password_check_receive'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class Mt5PasswordCheckResponse extends Response {
  /// Initialize Mt5PasswordCheckResponse
  Mt5PasswordCheckResponse(
      {this.mt5PasswordCheck,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory Mt5PasswordCheckResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5PasswordCheckResponseFromJson(json);

  // Properties
  /// `1` on success
  int mt5PasswordCheck;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$Mt5PasswordCheckResponseToJson(this);
}

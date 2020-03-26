/// Autogenerated from flutter_deriv_api|lib/api/app_register_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'app_register_receive.g.dart';

/// JSON conversion for 'app_register_receive'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class AppRegisterResponse extends Response {
  /// Initialize AppRegisterResponse
  AppRegisterResponse(
      {this.appRegister,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory AppRegisterResponse.fromJson(Map<String, dynamic> json) =>
      _$AppRegisterResponseFromJson(json);

  // Properties
  /// The information of the created application.
  Map<String, dynamic> appRegister;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$AppRegisterResponseToJson(this);
}

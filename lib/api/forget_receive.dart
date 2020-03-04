/// Autogenerated from flutter_deriv_api|lib/api/forget_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'forget_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ForgetResponse extends Response {
  ///
  ForgetResponse(
      {this.forget,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory ForgetResponse.fromJson(Map<String, dynamic> json) =>
      _$ForgetResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ForgetResponseToJson(this);

  // Properties

  /// If set to 1, stream exited and stopped. If set to 0, stream did not exist.
  int forget;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

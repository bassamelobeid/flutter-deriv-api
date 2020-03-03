/// Autogenerated from flutter_deriv_api|lib/api/mt5_get_settings_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'mt5_get_settings_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5GetSettingsResponse extends Response {
  ///
  Mt5GetSettingsResponse(
      {Map<String, dynamic> echoReq,
      String msgType,
      this.mt5GetSettings,
      int reqId})
      : super(echoReq: echoReq, msgType: msgType, reqId: reqId);

  ///
  factory Mt5GetSettingsResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5GetSettingsResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$Mt5GetSettingsResponseToJson(this);

  // Properties

  /// MT5 user account details
  Map<String, dynamic> mt5GetSettings;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

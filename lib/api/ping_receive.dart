/// Autogenerated from flutter_deriv_api|lib/api/ping_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'ping_receive.g.dart';

/// JSON conversion for 'ping_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PingResponse extends Response {
  /// Initialize PingResponse
  PingResponse(
      {this.ping,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory PingResponse.fromJson(Map<String, dynamic> json) =>
      _$PingResponseFromJson(json);

  // Properties
  /// Will return 'pong'
  String ping;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$PingResponseToJson(this);
}

/// Autogenerated from flutter_deriv_api|lib/api/service_token_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'service_token_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ServiceTokenResponse extends Response {
  ///
  ServiceTokenResponse(
      {this.echoReq, this.msgType, this.reqId, this.serviceToken});

  ///
  factory ServiceTokenResponse.fromJson(Map<String, dynamic> json) =>
      _$ServiceTokenResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ServiceTokenResponseToJson(this);

  // Properties
  /// Echo of the request made.
  Map<String, dynamic> echoReq;

  /// Action name of the request made.
  String msgType;

  /// Optional field sent in request to map to response, present only when request contains `req_id`.
  int reqId;

  /// The object containing the retrieved token
  Map<String, dynamic> serviceToken;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}

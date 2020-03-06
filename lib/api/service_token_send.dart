/// Autogenerated from flutter_deriv_api|lib/api/service_token_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'service_token_send.g.dart';

/// JSON conversion for 'service_token_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ServiceTokenRequest extends Request {
  /// Initialize ServiceTokenRequest
  ServiceTokenRequest(
      {this.referrer,
      this.service,
      this.serviceToken,
      int reqId,
      Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  /// Factory constructor to initialize from JSON
  factory ServiceTokenRequest.fromJson(Map<String, dynamic> json) =>
      _$ServiceTokenRequestFromJson(json);

  // Properties
  /// [Optional] The URL of the web page where the Web SDK will be used.
  String referrer;

  /// The service name to retrieve the token for.
  String service;

  /// Must be `1`
  int serviceToken;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$ServiceTokenRequestToJson(this);
}

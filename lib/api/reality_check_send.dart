/// Autogenerated from flutter_deriv_api|lib/api/reality_check_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'reality_check_send.g.dart';

/// JSON conversion for 'reality_check_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class RealityCheckRequest extends Request {
  /// Initialize RealityCheckRequest
  RealityCheckRequest(
      {this.realityCheck, int reqId, Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  /// Factory constructor to initialize from JSON
  factory RealityCheckRequest.fromJson(Map<String, dynamic> json) =>
      _$RealityCheckRequestFromJson(json);

  // Properties
  /// Must be `1`
  int realityCheck;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$RealityCheckRequestToJson(this);
}

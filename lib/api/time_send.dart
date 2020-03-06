/// Autogenerated from flutter_deriv_api|lib/api/time_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'time_send.g.dart';

/// JSON conversion for 'time_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class TimeRequest extends Request {
  /// Initialize TimeRequest
  TimeRequest({this.time, int reqId, Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  /// Factory constructor to initialize from JSON
  factory TimeRequest.fromJson(Map<String, dynamic> json) =>
      _$TimeRequestFromJson(json);

  // Properties
  /// Must be `1`
  int time;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$TimeRequestToJson(this);
}

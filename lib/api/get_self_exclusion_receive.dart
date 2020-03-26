/// Autogenerated from flutter_deriv_api|lib/api/get_self_exclusion_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'get_self_exclusion_receive.g.dart';

/// JSON conversion for 'get_self_exclusion_receive'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class GetSelfExclusionResponse extends Response {
  /// Initialize GetSelfExclusionResponse
  GetSelfExclusionResponse(
      {this.getSelfExclusion,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory GetSelfExclusionResponse.fromJson(Map<String, dynamic> json) =>
      _$GetSelfExclusionResponseFromJson(json);

  // Properties
  /// List of values set for self exclusion.
  Map<String, dynamic> getSelfExclusion;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$GetSelfExclusionResponseToJson(this);
}

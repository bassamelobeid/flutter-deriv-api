/// generated automatically from flutter_deriv_api|lib/api/get_self_exclusion_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'get_self_exclusion_receive.g.dart';

/// JSON conversion for 'get_self_exclusion_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetSelfExclusionResponse extends Response {
  /// Initialize GetSelfExclusionResponse
  GetSelfExclusionResponse({
    this.getSelfExclusion,
    Map<String, dynamic> echoReq,
    Map<String, dynamic> error,
    String msgType,
    int reqId,
  }) : super(
          echoReq: echoReq,
          error: error,
          msgType: msgType,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory GetSelfExclusionResponse.fromJson(Map<String, dynamic> json) =>
      _$GetSelfExclusionResponseFromJson(json);

  // Properties
  /// List of values set for self exclusion.
  final Map<String, dynamic> getSelfExclusion;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$GetSelfExclusionResponseToJson(this);
}

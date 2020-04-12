/// generated automatically from flutter_deriv_api|lib/api/get_self_exclusion_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'get_self_exclusion_send.g.dart';

/// JSON conversion for 'get_self_exclusion_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetSelfExclusionRequest extends Request {
  /// Initialize GetSelfExclusionRequest
  GetSelfExclusionRequest({
    this.getSelfExclusion = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory GetSelfExclusionRequest.fromJson(Map<String, dynamic> json) =>
      _$GetSelfExclusionRequestFromJson(json);

  // Properties
  /// Must be `1`
  final int getSelfExclusion;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$GetSelfExclusionRequestToJson(this);
}

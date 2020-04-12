/// generated automatically from flutter_deriv_api|lib/api/copy_stop_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'copy_stop_send.g.dart';

/// JSON conversion for 'copy_stop_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class CopyStopRequest extends Request {
  /// Initialize CopyStopRequest
  CopyStopRequest({
    this.copyStop,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory CopyStopRequest.fromJson(Map<String, dynamic> json) =>
      _$CopyStopRequestFromJson(json);

  // Properties
  /// API tokens identifying the accounts which needs not to be copied
  final String copyStop;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$CopyStopRequestToJson(this);
}

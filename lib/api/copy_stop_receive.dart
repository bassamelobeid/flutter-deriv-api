/// generated automatically from flutter_deriv_api|lib/api/copy_stop_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'copy_stop_receive.g.dart';

/// JSON conversion for 'copy_stop_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class CopyStopResponse extends Response {
  /// Initialize CopyStopResponse
  CopyStopResponse({
    this.copyStop,
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
  factory CopyStopResponse.fromJson(Map<String, dynamic> json) =>
      _$CopyStopResponseFromJson(json);

  // Properties
  /// Copy stopping confirmation. Returns 1 is success.
  final int copyStop;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$CopyStopResponseToJson(this);
}

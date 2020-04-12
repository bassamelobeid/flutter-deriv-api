/// generated automatically from flutter_deriv_api|lib/api/copy_start_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'copy_start_receive.g.dart';

/// JSON conversion for 'copy_start_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class CopyStartResponse extends Response {
  /// Initialize CopyStartResponse
  CopyStartResponse({
    this.copyStart,
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
  factory CopyStartResponse.fromJson(Map<String, dynamic> json) =>
      _$CopyStartResponseFromJson(json);

  // Properties
  /// Copy start confirmation. Returns 1 is success.
  final int copyStart;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$CopyStartResponseToJson(this);
}

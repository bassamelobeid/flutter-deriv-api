/// generated automatically from flutter_deriv_api|lib/api/time_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'time_receive.g.dart';

/// JSON conversion for 'time_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class TimeResponse extends Response {
  /// Initialize TimeResponse
  TimeResponse({
    this.time,
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
  factory TimeResponse.fromJson(Map<String, dynamic> json) =>
      _$TimeResponseFromJson(json);

  // Properties
  /// Epoch of server time.
  final int time;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$TimeResponseToJson(this);
}

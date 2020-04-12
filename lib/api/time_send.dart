/// generated automatically from flutter_deriv_api|lib/api/time_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'time_send.g.dart';

/// JSON conversion for 'time_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class TimeRequest extends Request {
  /// Initialize TimeRequest
  TimeRequest({
    this.time = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory TimeRequest.fromJson(Map<String, dynamic> json) =>
      _$TimeRequestFromJson(json);

  // Properties
  /// Must be `1`
  final int time;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$TimeRequestToJson(this);
}

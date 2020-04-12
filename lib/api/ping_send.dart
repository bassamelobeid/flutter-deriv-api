/// generated automatically from flutter_deriv_api|lib/api/ping_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'ping_send.g.dart';

/// JSON conversion for 'ping_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PingRequest extends Request {
  /// Initialize PingRequest
  const PingRequest({
    this.ping = 1,
    int reqId,
    Map<String, dynamic> passthrough,
  }) : super(
          reqId: reqId,
          passthrough: passthrough,
        );

  /// Creates instance from JSON
  factory PingRequest.fromJson(Map<String, dynamic> json) =>
      _$PingRequestFromJson(json);

  // Properties
  /// Must be `1`
  final int ping;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$PingRequestToJson(this);

  /// Creates copy of instance with given parameters
  @override
  PingRequest copyWith({
    int ping,
    int reqId,
    Map<String, dynamic> passthrough,
  }) =>
      PingRequest(
        ping: ping ?? this.ping,
        reqId: reqId ?? this.reqId,
        passthrough: passthrough ?? this.passthrough,
      );

  /// Override equatable class
  @override
  List<Object> get props => null;
}
